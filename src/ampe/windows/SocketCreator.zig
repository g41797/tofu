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

    const addr = resolveAddr(cnf.addrToSlice(), cnf.port.?) catch |er| {
        log.info("createTcpServer resolveAddr failed with error {s}", .{@errorName(er)});
        return AmpeError.InvalidAddress;
    };

    const skt: Skt = createListenerSocket(&addr) catch |er| {
        log.info("<{d}> createListenerSocket failed with error {s}", .{ getCurrentTid(), @errorName(er) });

        return AmpeError.ListenFailed;
    };

    return skt;
}

pub fn createTcpClient(sc: *SocketCreator) AmpeError!Skt {
    const cnf: *TCPClientAddress = &sc.addrs.tcp_client_addr;

    const addr = resolveAddr(cnf.addrToSlice(), cnf.port.?) catch {
        return AmpeError.InvalidAddress;
    };

    return createConnectSocket(&addr) catch AmpeError.InvalidAddress;
}

pub fn createUdsServer(sc: *SocketCreator) AmpeError!Skt {
    return createUdsListener(sc.addrs.uds_server_addr.addrToSlice());
}

pub fn createUdsListener(path: []const u8) AmpeError!Skt {
    var udsPath: []const u8 = path;

    if (udsPath.len == 0) {
        var tup: TempUdsPath = .{};

        udsPath = tup.buildPath() catch {
            return AmpeError.UnknownError;
        };
    }

    const addr = pn.initAddrUnix(udsPath) catch {
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
    const addr = pn.initAddrUnix(path) catch {
        return AmpeError.InvalidAddress;
    };

    const skt = createConnectSocket(&addr) catch {
        return AmpeError.InvalidAddress;
    };

    return skt;
}

pub fn createListenerSocket(addr: *const pn.Addr) !Skt {
    var ret: Skt = .{
        .address = addr.*,
        .socket = null,
    };

    ret.socket = try posix.socket(@intCast(pn.addrFamily(&ret.address)), posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer ret.close();

    if (builtin.os.tag == .windows) {
        var mode: u32 = 1;
        _ = std.os.windows.ws2_32.ioctlsocket(ret.socket.?, std.os.windows.ws2_32.FIONBIO, &mode);
        try ret.setLingerAbort();
    }

    try ret.listen();

    return ret;
}

pub fn createConnectSocket(addr: *const pn.Addr) !Skt {
    var ret: Skt = .{
        .address = addr.*,
        .socket = null,
    };

    ret.socket = try posix.socket(@intCast(pn.addrFamily(&ret.address)), posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer ret.close();

    if (builtin.os.tag == .windows) {
        var mode: u32 = 1;
        _ = std.os.windows.ws2_32.ioctlsocket(ret.socket.?, std.os.windows.ws2_32.FIONBIO, &mode);
    }
    try ret.setLingerAbort();
    return ret;
}

/// Resolve a host string and port to a pn.Addr using getaddrinfo (libc).
/// Supports IPv4/IPv6 literals, DNS hostnames, and empty string (wildcard).
fn resolveAddr(host: []const u8, port: u16) error{InvalidAddress}!pn.Addr {
    if (host.len == 0) {
        return pn.initAddrIp4(.{ 0, 0, 0, 0 }, port);
    }
    var host_buf: [256]u8 = undefined;
    if (host.len >= host_buf.len) return error.InvalidAddress;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return error.InvalidAddress;
    var hints: pn.addrinfo = std.mem.zeroes(pn.addrinfo);
    hints.ai_socktype = pn.SOCK_STREAM;
    var res: ?*pn.addrinfo = null;
    if (pn.getaddrinfo(@ptrCast(&host_buf), port_str.ptr, &hints, &res) != 0) return error.InvalidAddress;
    defer if (res) |r| pn.freeaddrinfo(r);
    const ai = res orelse return error.InvalidAddress;
    const raw_addr = ai.ai_addr orelse return error.InvalidAddress;
    const addrlen: usize = @intCast(ai.ai_addrlen);
    if (addrlen == 0 or addrlen > 128) return error.InvalidAddress;
    var addr: pn.Addr = std.mem.zeroes(pn.Addr);
    @memcpy(addr.mem[0..addrlen], @as([*]const u8, @ptrCast(raw_addr))[0..addrlen]);
    addr.len = @intCast(addrlen);
    return addr;
}

const tofu = @import("../../tofu.zig");

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

const internal = @import("../internal.zig");
const Notifier = internal.Notifier;
const Skt = internal.Skt;

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Socket = internal.Socket;
const Thread = std.Thread;
const getCurrentTid = Thread.getCurrentId;
const log = std.log;
const builtin = @import("builtin");

const pn = @import("posix_net");
