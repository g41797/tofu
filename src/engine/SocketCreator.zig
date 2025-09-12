// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const SocketCreator = @This();

allocator: Allocator = undefined,
cnfgr: Configurator = undefined,

pub fn init(allocator: Allocator) SocketCreator {
    return .{
        .allocator = allocator,
        .cnfgr = .wrong,
    };
}

pub fn fromMessage(sc: *SocketCreator, msg: *Message) AmpeError!Skt {
    const cnfgr = Configurator.fromMessage(msg);

    return sc.fromConfigurator(cnfgr);
}

pub fn fromConfigurator(sc: *SocketCreator, cnfgr: Configurator) AmpeError!Skt {
    sc.cnfgr = cnfgr;

    switch (sc.cnfgr) {
        .wrong => return AmpeError.InvalidAddress,
        .tcp_server => return sc.createTcpServer(),
        .tcp_client => return sc.createTcpClient(),
        .uds_server => return sc.createUdsServer(),
        .uds_client => return sc.createUdsClient(),
    }
}

pub fn createTcpServer(sc: *SocketCreator) AmpeError!Skt {
    const cnf: *TCPServerConfigurator = &sc.cnfgr.tcp_server;

    const address = std.net.Address.resolveIp(cnf.addrToSlice(), cnf.port.?) catch |er| {
        log.err("createTcpServer resolveIp failed with error {s}", .{@errorName(er)});
        return AmpeError.InvalidAddress;
    };

    const skt = createListenerSocket(&address) catch |er| {
        log.err("createListenerSocket failed with error {s}", .{@errorName(er)});
        return AmpeError.InvalidAddress;
    };

    return skt;
}

pub fn createTcpClient(sc: *SocketCreator) AmpeError!Skt {
    const cnf: *TCPClientConfigurator = &sc.cnfgr.tcp_client;

    var list = std.net.getAddressList(sc.allocator, cnf.addrToSlice(), cnf.port.?) catch {
        return AmpeError.InvalidAddress;
    };
    defer list.deinit();

    if (list.addrs.len == 0) {
        return AmpeError.InvalidAddress;
    }

    for (list.addrs) |addr| {
        const ret = createConnectSocket(&addr) catch {
            continue;
        };
        return ret;
    }
    return AmpeError.InvalidAddress;
}

pub fn createUdsServer(sc: *SocketCreator) AmpeError!Skt {
    return createUdsListener(sc.allocator, sc.cnfgr.uds_server.addrToSlice());
}

pub fn createUdsListener(allocator: Allocator, path: []const u8) AmpeError!Skt {
    var udsPath = path;

    if (udsPath.len == 0) {
        var tup: Notifier.TempUdsPath = .{};

        udsPath = tup.buildPath(allocator) catch {
            return AmpeError.UnknownError;
        };
    }

    var address = std.net.Address.initUnix(udsPath) catch {
        return AmpeError.InvalidAddress;
    };

    const skt = createListenerSocket(&address) catch {
        log.err("createUDSListenerSocket failed", .{});
        return AmpeError.InvalidAddress;
    };

    return skt;
}

pub fn createUdsClient(sc: *SocketCreator) AmpeError!Skt {
    return createUdsSocket(sc.cnfgr.uds_client.addrToSlice());
}

pub fn createUdsSocket(path: []const u8) AmpeError!Skt {
    var address = std.net.Address.initUnix(path) catch {
        return AmpeError.InvalidAddress;
    };

    const skt = createConnectSocket(&address) catch {
        return AmpeError.InvalidAddress;
    };

    return skt;
}

// from IoUring.zig#L3473 (0.14.1), slightly changed
fn createListenerSocket(address: *const std.net.Address) !Skt {
    var ret: Skt = .{
        .address = address.*,
        .socket = undefined,
    };

    ret.socket = try posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(ret.socket);

    try ret.listen();

    return ret;
}

pub fn createConnectSocket(address: *const std.net.Address) !Skt {
    var ret: Skt = .{
        .address = address.*,
        .socket = undefined,
    };

    ret.socket = try posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(ret.socket);

    return ret;
}

const configurator = @import("../configurator.zig");
const Configurator = configurator.Configurator;
const TCPServerConfigurator = configurator.TCPServerConfigurator;
const TCPClientConfigurator = configurator.TCPClientConfigurator;
const UDSServerConfigurator = configurator.UDSServerConfigurator;
const UDSClientConfigurator = configurator.UDSClientConfigurator;
const WrongConfigurator = configurator.WrongConfigurator;

const message = @import("../message.zig");
const Trigger = message.Trigger;

const BinaryHeader = message.BinaryHeader;
const Message = message.Message;
const MessageQueue = message.MessageQueue;

const MessageID = message.MessageID;

const sockets = @import("sockets.zig");
const Skt = sockets.Skt;

const DBG = @import("../engine.zig").DBG;

const AmpeError = @import("../status.zig").AmpeError;

const Pool = @import("Pool.zig");
const Notifier = @import("Notifier.zig");
const Notification = Notifier.Notification;

const Appendable = @import("nats").Appendable;

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const os = builtin.os.tag;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Socket = std.posix.socket_t;

const log = std.log;
