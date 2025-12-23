// SPDX-FileCopyrightText: Copyright (c) 2025 <TBD>
// SPDX-License-Identifier: <TBD>

//! Multihomed server implementation for tofu.
//!
//! **What is Multihomed Server:**
//! Server with multiple listeners (TCP + UDS) running on ONE thread. Can accept
//! connections from different networks simultaneously.
//!
//! **Key Pattern Demonstrated:**
//! - Multiple listeners, one `waitReceive()` loop
//! - Dispatch messages by channel_number
//! - Cooperative services pattern
//! - Single-threaded architecture (simpler than multi-threaded)
//!
//! **Message Flow:**
//! ```
//! Listener1(TCP) ---|
//! Listener2(UDS) ---|---> waitReceive() --> dispatch by channel --> Services
//! Client1 -----------|
//! Client2 -----------|
//! ```
//!
//! **Why Single Thread:**
//! Simpler state management. No locks needed. Messages naturally serialized.
//! Services.onMessage() called sequentially for each message. This works well
//! for I/O bound workloads.
//!
//! **Message-as-Cube:**
//! Each listener creates listener channel. Each client connection creates client channel.
//! Server receives message cubes from all channels through one `waitReceive()`.
//! Cubes dispatched to Services based on channel_number. Services process and send back.

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

/// Async message passing engine interface.
ampe: ?Ampe = null,
/// Memory allocator for server resources.
allocator: ?Allocator = null,
/// Channel group for managing all server connections.
chnls: ?ChannelGroup = null,
/// Services implementation for processing messages.
srvcs: Services = undefined,
/// Map of listener channel numbers to their configurations.
lstnChnls: ?std.AutoArrayHashMap(message.ChannelNumber, Configurator) = null,
/// Server thread handle.
thread: ?std.Thread = null,
/// Queue for accumulating messages before thread starts.
msgq: message.MessageQueue = .{},
/// Mailbox for thread synchronization and status reporting.
ackMbox: MSGMailBox = .{},

/// Creates and starts multihomed server with multiple listeners on separate thread.
///
/// **Parameters:**
/// - `ampe` - Engine interface (for pool operations and channel creation)
/// - `adrs` - Array of listener configurations (TCP and/or UDS addresses)
/// - `srvcs` - Services implementation for processing client messages
///
/// **What This Does:**
/// 1. Creates listener for each address in `adrs`
/// 2. Starts dedicated thread running message loop
/// 3. Thread calls `waitReceive()` for all channels (listeners + clients)
/// 4. Dispatches received messages to Services
/// 5. Returns server handle immediately (non-blocking)
///
/// **Pattern:**
/// ```zig
/// var listeners: [2]Configurator = .{
///     .{ .tcp_server = TCPServerConfigurator.init("0.0.0.0", 8080) },
///     .{ .uds_server = UDSServerConfigurator.init("/tmp/app.sock") },
/// };
/// var echoSvc: EchoService = .{};
/// var server: *MultiHomed = try MultiHomed.run(ampe, &listeners, echoSvc.services());
/// defer server.stop(); // Stops thread and cleans up
/// ```
///
/// **Important:**
/// - Server runs on separate thread
/// - One `waitReceive()` handles all listeners and clients
/// - Call `stop()` to shutdown gracefully
///
/// **Errors:**
/// - `error.EmptyConfiguration` if `adrs` is empty
/// - `error.StartServicesFailure` if Services.start() fails
/// - Network errors if listeners cannot bind
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

/// Stops the thread, destroys  all channels, releases messages to the pool,
/// releases server object memory
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

fn init(mh: *MultiHomed, adrs: []Configurator) !*MultiHomed {
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

fn startListener(mh: *MultiHomed, cnfg: Configurator) !void {
    var welcomeRequest: ?*Message = mh.*.ampe.?.get(tofu.AllocationStrategy.always) catch unreachable;
    defer mh.*.ampe.?.put(&welcomeRequest);

    cnfg.prepareRequest(welcomeRequest.?) catch unreachable;

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

// Main message processing loop. Handles messages from all channels.
// This is the heart of multihomed pattern.
fn mainLoop(mh: *MultiHomed) void {
    while (true) {
        // ONE waitReceive() for ALL channels (listeners + clients)
        // This is key to multihomed pattern: single thread handles everything
        var receivedMsg: ?*Message = mh.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
            log.info("server - waitReceive error {s}", .{@errorName(err)});
            return;
        };
        defer mh.*.ampe.?.put(&receivedMsg);

        const sts: status.AmpeStatus = status.raw_to_status((receivedMsg.?.*.bhdr.status));

        // CHECK 1: Stop signal from another thread
        // Another thread called updateReceiver() to wake us up
        if (sts == .receiver_update) {
            log.info("Stop command from the another thread", .{});
            return;
        }

        // CHECK 2: Dispatch by channel_number
        // Is this message from a listener channel or client channel?
        if (mh.*.lstnChnls.?.contains(receivedMsg.?.*.bhdr.channel_number)) {
            // Listener channel should not send messages to us
            // If we get message from listener, something is wrong
            log.info("listener failed with status {s}", .{@tagName(sts)});
            return;
        }

        // This is a client message. Pass to Services for processing.
        // Services.onMessage() returns:
        //   true  - continue processing
        //   false - stop server
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
