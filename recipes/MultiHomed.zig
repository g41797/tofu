// SPDX-FileCopyrightText: Copyright (c) 2025 <TBD>
// SPDX-License-Identifier: <TBD>

//! Server with multiple listeners (TCP/UDS) on one thread.
//!
//! Flow: Single `waitReceive()` loop handles all listeners and client connections.
//! Messages dispatched by channel_number to Services implementation.
//!
//! Single-threaded: no locks, sequential processing, simpler state management.

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
ackMbox: MSGMailBox = .{},

/// Call stop() to cleanup.
pub fn run(ampe: Ampe, adrs: []Configurator, srvcs: Services) !*MultiHomed {
    if (adrs.len == 0) {
        return error.EmptyConfiguration;
    }

    const gpa: Allocator = ampe.getAllocator();

    const mh: *MultiHomed = try gpa.create(MultiHomed);
    errdefer mh.*.stop();

    mh.* = .{ // 2DO check default values
        .ampe = ampe,
        .allocator = gpa,
        .chnls = try ampe.create(),
        .srvcs = srvcs,
        .lstnChnls = .init(gpa),
    };

    try mh.*.lstnChnls.?.ensureTotalCapacity(adrs.len);

    return mh.*.init(adrs);
}

pub fn stop(mh: *MultiHomed) void {
    if (mh.*.allocator == null) {
        return;
    }

    const allocator: Allocator = mh.*.allocator.?;

    defer allocator.destroy(mh);

    if (mh.*.thread != null) {
        // Interrupt waitReceive on the thread
        var nullMsg: ?*message.Message = null;
        mh.*.chnls.?.updateReceiver(&nullMsg) catch unreachable;

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

        var next: ?*Message = mh.*.msgq.dequeue();
        while (next != null) {
            mh.*.ampe.?.put(&next);
            next = mh.*.msgq.dequeue();
        }
    }
    return;
}

pub fn init(mh: *MultiHomed, adrs: []Configurator) !*MultiHomed {
    for (adrs) |cnfg| {
        _ = try mh.*.startListener(cnfg);
    }

    mh.*.thread = try std.Thread.spawn(.{}, onThread, .{mh});

    _ = mh.*.ackMbox.receive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| switch (err) {
        error.Timeout => {}, // for compiler
        error.Closed => return error.StartServicesFailure,
        error.Interrupted => {}, // OK
    };

    return mh;
}

pub fn startListener(mh: *MultiHomed, cnfg: Configurator) !void {
    var welcomeRequest: ?*Message = mh.*.ampe.?.get(tofu.AllocationStrategy.always) catch unreachable;
    defer mh.*.ampe.?.put(&welcomeRequest);

    cnfg.configure(welcomeRequest.?) catch unreachable;

    welcomeRequest.?.*.copyBh2Body();
    const wlcbh: BinaryHeader = try mh.*.chnls.?.enqueueToPeer(&welcomeRequest);

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

                try mh.*.lstnChnls.?.put(receivedMsg.?.*.bhdr.channel_number, cnfg);
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

pub fn onThread(mh: *MultiHomed) void {
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

// Main message processing loop for all channels.
pub fn mainLoop(mh: *MultiHomed) void {
    while (true) {
        // One waitReceive() for all channels (listeners + clients)
        var receivedMsg: ?*Message = mh.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
            log.info("server - waitReceive error {s}", .{@errorName(err)});
            return;
        };
        defer mh.*.ampe.?.put(&receivedMsg);

        const sts: status.AmpeStatus = status.raw_to_status((receivedMsg.?.*.bhdr.status));

        // Stop signal from another thread
        if (sts == .receiver_update) {
            log.info("Stop command from the another thread", .{});
            return;
        }

        // Dispatch by channel_number
        if (mh.*.lstnChnls.?.contains(receivedMsg.?.*.bhdr.channel_number)) {
            log.info("listener failed with status {s}", .{@tagName(sts)});
            return;
        }

        // Pass to Services for processing
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

pub fn closeChannels(mh: *MultiHomed) void {
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
//     closeMsg.?.*.bhdr.proto.mtype = .bye;
//     closeMsg.?.*.bhdr.proto.role = .signal;
//     closeMsg.?.*.bhdr.proto.oob = .on;
//
//     // Set channel number to close this channel.
//     closeMsg.?.*.bhdr.channel_number = lstChannel;
//
//     _ = try mh.*.chnls.?.enqueueToPeer(&closeMsg);
//
//     var closeListenerResp: ?*Message = try mh.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
//     defer mh.*.ampe.?.put(&closeListenerResp);
//
//     closeListenerResp.?.*.bhdr.dumpMeta("closeListener");
//
//     assert(closeListenerResp.?.*.bhdr.status == status.status_to_raw(status.AmpeStatus.channel_closed));
//
//     return;
// }
