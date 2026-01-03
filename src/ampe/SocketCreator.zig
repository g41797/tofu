// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const SocketCreator = @This();

allocator: Allocator = undefined,
addrs: Address = undefined,

pub fn init(allocator: Allocator) SocketCreator {
    return .{
        .allocator = allocator,
        .addrs = .wrong,
    };
}

pub fn parse(sc: *SocketCreator, msg: *Message) AmpeError!Skt {
    const addrs = Address.parse(msg);

    return sc.fromAddress(addrs);
}

pub fn fromAddress(sc: *SocketCreator, addrs: Address) AmpeError!Skt {
    sc.addrs = addrs;

    switch (sc.addrs) {
        .wrong => return AmpeError.InvalidAddress,
        .tcp_server_addr => return sc.createTcpServer(),
        .tcp_client_addr => return sc.createTcpClient(),
        .uds_server_addr => return sc.createUdsServer(),
        .uds_client_addr => return sc.createUdsClient(),
    }
}

pub fn createTcpServer(sc: *SocketCreator) AmpeError!Skt {
    const cnf: *TCPServerAddress = &sc.addrs.tcp_server_addr;

    const addr = std.net.Address.resolveIp(cnf.addrToSlice(), cnf.port.?) catch |er| {
        log.info("createTcpServer resolveIp failed with error {s}", .{@errorName(er)});
        return AmpeError.InvalidAddress;
    };

    const skt = createListenerSocket(&addr) catch |er| {
        log.info("<{d}> createListenerSocket failed with error {s}", .{ getCurrentTid(), @errorName(er) });

        switch (er) {
            error.AddressNotAvailable => return AmpeError.InvalidAddress,
            error.AddressInUse, error.FileDescriptorNotASocket, error.OperationNotSupported => return AmpeError.ListenFailed,
            else => return AmpeError.UnknownError,
        }
    };

    return skt;
}

pub fn createTcpClient(sc: *SocketCreator) AmpeError!Skt {
    const cnf: *TCPClientAddress = &sc.addrs.tcp_client_addr;

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
    return createUdsListener(sc.allocator, sc.addrs.uds_server_addr.addrToSlice());
}

pub fn createUdsListener(allocator: Allocator, path: []const u8) AmpeError!Skt {
    var udsPath = path;

    if (udsPath.len == 0) {
        var tup: TempUdsPath = .{};

        udsPath = tup.buildPath(allocator) catch {
            return AmpeError.UnknownError;
        };
    }

    var addr = std.net.Address.initUnix(udsPath) catch {
        return AmpeError.InvalidAddress;
    };

    const skt = createListenerSocket(&addr) catch {
        log.info("createUDSListenerSocket failed", .{});
        return AmpeError.InvalidAddress;
    };

    return skt;
}

pub fn createUdsClient(sc: *SocketCreator) AmpeError!Skt {
    return createUdsSocket(sc.addrs.uds_client_addr.addrToSlice());
}

pub fn createUdsSocket(path: []const u8) AmpeError!Skt {
    var addr = std.net.Address.initUnix(path) catch {
        return AmpeError.InvalidAddress;
    };

    const skt = createConnectSocket(&addr) catch {
        return AmpeError.InvalidAddress;
    };

    return skt;
}

// from IoUring.zig#L3473 (0.14.1), slightly changed
fn createListenerSocket(addr: *const std.net.Address) !Skt {
    var ret: Skt = .{
        .address = addr.*,
        .socket = null,
    };

    ret.socket = try posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer ret.close();

    try ret.listen();

    return ret;
}

pub fn createConnectSocket(addr: *const std.net.Address) !Skt {
    var ret: Skt = .{
        .address = addr.*,
        .socket = null,
    };

    ret.socket = try posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(ret.socket.?);
    try ret.setLingerAbort();
    return ret;
}

const tofu = @import("../tofu.zig");

const address = tofu.address;
const Address = address.Address;
const TCPServerAddress = address.TCPServerAddress;
const TCPClientAddress = address.TCPClientAddress;
const UDSServerAddress = address.UDSServerAddress;
const UDSClientAddress = address.UDSClientAddress;
const WrongAddress = address.WrongAddress;

const message = tofu.message;
const Message = message.Message;

const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;

const TempUdsPath = tofu.TempUdsPath;

const Notifier = @import("Notifier.zig");
const internal = @import("internal.zig");
const Skt = internal.Skt;

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Socket = std.posix.socket_t;
const Thread = std.Thread;
const getCurrentTid = Thread.getCurrentId;
const log = std.log;
