// SPDX-FileCopyrightText: Copyright (c) 2025 <TBD>
// SPDX-License-Identifier: <TBD>

///////////////////////////////////////////////////////////////////////////////////////////////
//                 AI Overview
//
// A multihomed TCP/IP server is a server with multiple network connections
// (network interface cards) and IP addresses, allowing it to connect to
// and provide services on multiple networks simultaneously.
//
// This configuration enhances reliability and performance by providing redundancy
// and allowing direct access to different subnets for services like file sharing or databases.
//
// Key characteristics
//
//     Multiple network interfaces:
//         The server has more than one physical network adapter or is configured
//         with multiple IP addresses on a single adapter.
//
//     Connection to multiple networks:
//         It can be attached to several physical networks or subnets at the same time.
//
//     Host, not a router:
//         By default, a multihomed machine is not a router.
//         It does not forward packets between its interfaces.
//
//     Service accessibility:
//         It can provide services to clients on different networks directly,
//         without the need for a router to forward traffic to it.
//
// Use cases
//
//     High-performance servers:
//         Servers like those for NFS or databases can have multiple network cards
//         to improve file sharing or data access for a large pool of users across different networks.
//
//     Redundancy:
//         Having multiple network connections can provide redundancy.
//         If one connection fails, the other can still provide access to the server's services.
//
// Configuration
//
//     A server can have multiple IP addresses, either by adding new network cards
//     or by configuring multiple IP addresses on a single network card.
//
//     For some services, you can explicitly configure the service to bind to a specific
//     IP address on a particular network interface.
//
///////////////////////////////////////////////////////////////////////////////////////////////

pub const MultiHomed = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const assert = std.debug.assert;

pub const tofu = @import("tofu");
pub const Reactor = tofu.Reactor;
pub const Ampe = tofu.Ampe;
pub const ChannelGroup = tofu.ChannelGroup;
pub const Options = tofu.Options;
pub const DefaultOptions = tofu.DefaultOptions;
pub const configurator = tofu.configurator;
pub const Configurator = configurator.Configurator;
pub const status = tofu.status;
pub const message = tofu.message;
pub const BinaryHeader = message.BinaryHeader;
pub const Message = message.Message;

pub const services = @import("services.zig");
pub const Services = services.Services;

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

ampe: ?Ampe = null,
allocator: ?Allocator = null,
chnls: ?ChannelGroup = null,
srvcs: Services = undefined,
lstnChnls: ?std.AutoArrayHashMap(message.ChannelNumber, Configurator) = null,
thread: ?std.Thread = null,
msgq: message.MessageQueue = .{},

// Use Mailbox (https://github.com/g41797/mailbox) for
// receiving status from thread (via close() for finish & interrupt() for ack)
// without transfer any Message
ackMbox: MSGMailBox = .{},

/// Initiates multihomed tofu server (mhts)
///   ampe - engine
///   adrs - slice with addresses of TCP and/or UDS servers
///   srvcs - caller supplied message processors
///
/// Upon successful initialisation server are ready for handling of several
/// tofu clients connecting to any of 'adrs' addresses.
/// Server runs on the separated thread.
///
/// If it's impossible from any reason to run, corresponding error is returned.
pub fn run(ampe: Ampe, adrs: []Configurator, srvcs: Services) !*MultiHomed {
    if (adrs.len == 0) {
        return error.EmptyConfiguration;
    }

    const gpa: Allocator = ampe.getAllocator();

    var mh: *MultiHomed = try gpa.create(MultiHomed);
    errdefer mh.*.stop();

    mh.* = .{ // 2DO check default values
        .ampe = ampe,
        .allocator = gpa,
        .chnls = try ampe.create(),
        .srvcs = srvcs,
        .lstnChnls = .init(gpa),
    };

    try mh.*.lstnChnls.?.ensureTotalCapacity(adrs.len);

    return mh.init(adrs);
}

/// Stops the thread, destroys  all channels, releases messages to the pool,
/// releases server object memory
pub fn stop(mh: *MultiHomed) void {
    if (mh.*.allocator == null) {
        return;
    }

    const allocator = mh.*.allocator.?;

    defer allocator.destroy(mh);

    if (mh.*.thread != null) {
        // Interrupt waitReceive on the thread
        var nullMsg: ?*message.Message = null;
        mh.*.chnls.?.updateWaiter(&nullMsg) catch unreachable;

        // Wait finish of the thread
        mh.*.thread.?.join();
    }

    if (mh.*.ampe != null) {
        if (mh.*.chnls != null) {
            // Closes all active channels - clients and listeners
            mh.*.ampe.?.destroy(mh.*.chnls.?) catch unreachable;
        }
        if (mh.*.lstnChnls != null) {
            mh.*.lstnChnls.?.deinit();
        }

        var next = mh.*.msgq.dequeue();
        while (next != null) {
            mh.*.ampe.?.put(&next);
            next = mh.*.msgq.dequeue();
        }
    }
    return;
}

fn init(mh: *MultiHomed, adrs: []Configurator) !*MultiHomed {
    for (adrs) |cnfg| {
        _ = try mh.startListener(cnfg);
    }

    mh.*.thread = try std.Thread.spawn(.{}, onThread, .{mh});

    _ = mh.*.ackMbox.receive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| switch (err) {
        error.Timeout => {}, // for compiler
        error.Closed => return error.StartServicesFailure,
        error.Interrupted => {}, // OK
    };

    return mh;
}

fn startListener(mh: *MultiHomed, cnfg: Configurator) !void {
    var welcomeRequest: ?*Message = mh.*.ampe.?.get(tofu.AllocationStrategy.always) catch unreachable;
    defer mh.*.ampe.?.put(&welcomeRequest);

    cnfg.prepareRequest(welcomeRequest.?) catch unreachable;

    welcomeRequest.?.copyBh2Body();
    const wlcbh: BinaryHeader = try mh.*.chnls.?.sendToPeer(&welcomeRequest);

    const lstChannel: message.ChannelNumber = wlcbh.channel_number;
    log.debug("listener channel {d}", .{lstChannel});

    try mh.*.lstnChnls.?.put(wlcbh.channel_number, cnfg);

    while (true) {
        var receivedMsg: ?*Message = mh.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
            log.info("server - waitReceive error {s}", .{@errorName(err)});
            return err;
        };

        if (!mh.*.lstnChnls.?.contains(receivedMsg.?.*.bhdr.channel_number)) { // listener channel
            mh.*.msgq.enqueue(receivedMsg.?); // Will be processed on the thread later
            continue;
        }

        defer mh.*.ampe.?.put(&receivedMsg);

        const sts: status.AmpeStatus = status.raw_to_status((receivedMsg.?.*.bhdr.status));

        // As a rule you need to handle pool_empty status
        // But welcome does not need any receive
        assert(sts != .pool_empty);

        switch (sts) {
            .success => {
                assert(receivedMsg.?.*.bhdr.proto.mtype == .welcome);
                assert(receivedMsg.?.*.bhdr.proto.role == .response);

                mh.*.lstnChnls.?.put(receivedMsg.?.*.bhdr.channel_number, cnfg) catch unreachable;
                return;
            },

            // .pool_empty => {
            //     // receivedMsg will be returned to the pool via defer
            //     // and used in recv
            //     continue;
            // },

            else => {
                log.info("server -status {s}", .{@tagName(sts)});
                return status.raw_to_error(receivedMsg.?.*.bhdr.status);
            },
        }
    }
}

fn onThread(mh: *MultiHomed) void {
    defer mh.*.thread = null;
    defer mh.*.srvcs.stop();
    defer mh.*.closeChannels();
    defer mh.*.closeMbox(); // Inform server about finish

    mh.*.srvcs.start(mh.*.ampe.?, mh.*.chnls.?) catch |err| {
        log.warn("start services error {s}", .{@errorName(err)});
        return;
    };

    // process accumulated messages
    var next: ?*Message = mh.*.msgq.dequeue();
    while (next != null) {
        const cont: bool = mh.*.srvcs.onMessage(&next);
        mh.*.ampe.?.put(&next);
        if (!cont) {
            log.warn("onMessage returns false -  stop processing", .{});
            return;
        }
        next = mh.*.msgq.dequeue();
    }

    mh.*.ackMbox.interrupt() catch unreachable; // Inform about successful start

    mh.*.mainLoop();

    return;
}

fn mainLoop(mh: *MultiHomed) void {
    while (true) {
        var receivedMsg: ?*Message = mh.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
            log.info("server - waitReceive error {s}", .{@errorName(err)});
            return;
        };
        defer mh.*.ampe.?.put(&receivedMsg);

        const sts: status.AmpeStatus = status.raw_to_status((receivedMsg.?.*.bhdr.status));

        if (sts == .waiter_update) { // Stop command from the another thread
            log.info("Stop command from the another thread", .{});
            return;
        }

        if (mh.*.lstnChnls.?.contains(receivedMsg.?.*.bhdr.channel_number)) {
            // Message from one of the listeners - something wrong
            log.info("listener failed with status {s}", .{@tagName(sts)});
            return;
        }

        const cont: bool = mh.*.srvcs.onMessage(&receivedMsg);
        if (!cont) {
            log.warn("onMessage returns false -  stop processing", .{});
            return;
        }
    }
    return;
}

inline fn closeMbox(mh: *MultiHomed) void {
    _ = mh.*.ackMbox.close(); // Nothing to clean
}

fn closeChannels(mh: *MultiHomed) void {
    if (mh.*.chnls != null) {
        mh.*.ampe.?.destroy(mh.*.chnls.?) catch unreachable;
        mh.*.chnls = null;
    }

    return;
}

// fn closeListeners(mh: *MultiHomed) void {
//     for (mh.*.lstnChnls.?.keys()) |key| {
//         _ = mh.*.closeListener(key) catch |err| {
//             log.info("server - closeListener error {s}", .{@errorName(err)});
//         };
//     }
// }
//
// fn closeListener(mh: *MultiHomed, lstChannel: message.ChannelNumber) !void {
//     var closeMsg: ?*Message = try mh.*.ampe.?.get(tofu.AllocationStrategy.always);
//     defer mh.*.ampe.?.put(&closeMsg);
//
//     // Prepare ByeSignal for the listener channel.
//     closeMsg.?.bhdr.proto.mtype = .bye;
//     closeMsg.?.bhdr.proto.role = .signal;
//     closeMsg.?.bhdr.proto.oob = .on;
//
//     // Set channel number to close this channel.
//     closeMsg.?.bhdr.channel_number = lstChannel;
//
//     _ = try mh.*.chnls.?.sendToPeer(&closeMsg);
//
//     var closeListenerResp: ?*Message = try mh.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
//     defer mh.*.ampe.?.put(&closeListenerResp);
//
//     closeListenerResp.?.bhdr.dumpMeta("closeListener");
//
//     assert(closeListenerResp.?.bhdr.status == status.status_to_raw(status.AmpeStatus.channel_closed));
//
//     return;
// }
