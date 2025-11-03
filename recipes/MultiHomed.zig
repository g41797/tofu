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
pub const Engine = tofu.Engine;
pub const Ampe = tofu.Ampe;
pub const Channels = tofu.Channels;
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
chnls: ?Channels = null,
srvcs: Services = undefined,
lstnChnls: ?std.AutoArrayHashMap(message.ChannelNumber, Configurator) = null,
thread: ?std.Thread = null,

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
///
/// Simplifications of example:
///  during init stage any client connection will be rejected.
pub fn run(ampe: Ampe, adrs: []Configurator, srvcs: Services) !*MultiHomed {
    if (adrs.len == 0) {
        return error.EmptyConfiguration;
    }

    const gpa: Allocator = ampe.getAllocator();

    var mh: *MultiHomed = try gpa.create(MultiHomed);
    errdefer mh.*.stop();

    mh.* = .{ // 2DO check default values
        .ampe = ampe,
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
    _ = mh;
}

fn init(mh: *MultiHomed, adrs: []Configurator) !*MultiHomed {
    for (adrs) |cnfg| {
        try mh.*.lstnChnls.?.put(try mh.*.startListener(cnfg), cnfg);
    }

    // usage of Mailbox (https://github.com/g41797/mailbox) for acknowledge
    var ackMbox: MSGMailBox = .{};

    mh.*.thread = try std.Thread.spawn(.{}, onThread, .{ mh, &ackMbox });

    _ = ackMbox.receive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| switch (err) {
        .Timeout => {}, // for compiler
        .Closed => return error.StartServicesFailure,
        .Interrupted => {}, // OK
    };

    return mh;
}

fn startListener(mh: *MultiHomed, cnfg: Configurator) !message.ChannelNumber {
    _ = mh;
    _ = cnfg;
    return error.NotImplementedYet;
}

fn onThread(mh: *MultiHomed, ackMbox: *MSGMailBox) void {
    mh.*.srvcs.start(mh.*.?.ampe, mh.*.?.sendTo) catch |err| {
        log.warn("start services error {s}", .{@errorName(err)});
        ackMbox.*.close(); // Inform about start failure
        return;
    };
    defer mh.*.srvcs.stop();

    try ackMbox.*.interrupt(); // Inform about successful start

    mh.*.mainLoop();

    return;
}

fn mainLoop(mh: *MultiHomed) void {
    _ = mh;
    return;
}
