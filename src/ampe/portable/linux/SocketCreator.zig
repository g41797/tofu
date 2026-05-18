const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const tofu = @import("../../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
const Skt = @import("Skt.zig").Skt;
const message = tofu.message;
const Message = message.Message;
const pn = @import("posix_net");
const address = tofu.address;
const Address = address.Address;
const TCPServerAddress = address.TCPServerAddress;
const TCPClientAddress = address.TCPClientAddress;
const TempUdsPath = tofu.TempUdsPath;

pub const SocketCreator = @This();

allocator: Allocator = undefined,
addrs: Address = .wrong,

pub fn init(allocator: Allocator) SocketCreator {
    return .{ .allocator = allocator };
}

pub fn parse(sc: *SocketCreator, msg: *Message) AmpeError!Skt {
    const addrs = Address.parse(msg);
    return sc.fromAddress(addrs);
}

pub fn fromAddress(sc: *SocketCreator, addrs: Address) AmpeError!Skt {
    sc.addrs = addrs;
    return switch (sc.addrs) {
        .wrong => AmpeError.InvalidAddress,
        .tcp_server_addr => sc.createTcpServer(),
        .tcp_client_addr => sc.createTcpClient(),
        .uds_server_addr => sc.createUdsServer(),
        .uds_client_addr => sc.createUdsClient(),
    };
}

pub fn createTcpServer(sc: *SocketCreator) AmpeError!Skt {
    const cnf = &sc.addrs.tcp_server_addr;
    const addr = resolveAddr(cnf.addrToSlice(), cnf.port orelse 0) catch |e| {
        log.warn("createTcpServer resolveAddr failed: {s}", .{@errorName(e)});
        return AmpeError.InvalidAddress;
    };
    return createListenerSocket(&addr) catch AmpeError.ListenFailed;
}

pub fn createTcpClient(sc: *SocketCreator) AmpeError!Skt {
    _ = sc.allocator;
    const cnf = &sc.addrs.tcp_client_addr;
    const addr = resolveAddr(cnf.addrToSlice(), cnf.port orelse 0) catch {
        return AmpeError.InvalidAddress;
    };
    return createConnectSocket(&addr) catch AmpeError.InvalidAddress;
}

pub fn createUdsServer(sc: *SocketCreator) AmpeError!Skt {
    return createUdsListener(sc.allocator, sc.addrs.uds_server_addr.addrToSlice());
}

pub fn createUdsListener(allocator: Allocator, path: []const u8) AmpeError!Skt {
    var udsPath = path;
    var tup: ?TempUdsPath = null;
    if (udsPath.len == 0) {
        tup = TempUdsPath{};
        udsPath = tup.?.buildPath(allocator) catch return AmpeError.UnknownError;
    }
    const fd = pn.createListenSocketUnix(udsPath.ptr, udsPath.len, 0) catch |e| {
        log.warn("createUdsListener failed: {s}", .{@errorName(e)});
        return AmpeError.ListenFailed;
    };
    const addr = pn.initAddrUnix(udsPath) catch return AmpeError.InvalidAddress;
    return Skt{ .fd = fd, .address = addr, .server = true };
}

pub fn createUdsClient(sc: *SocketCreator) AmpeError!Skt {
    return createUdsSocket(sc.addrs.uds_client_addr.addrToSlice());
}

pub fn createUdsSocket(path: []const u8) AmpeError!Skt {
    const addr = pn.initAddrUnix(path) catch return AmpeError.InvalidAddress;
    return createConnectSocket(&addr) catch AmpeError.InvalidAddress;
}

/// Create a TCP/IP listening socket from a pn.Addr (IPv4 or IPv6).
pub fn createListenerSocket(addr: *const pn.Addr) !Skt {
    const fd = pn.createListenSocketFromSockaddr(@ptrCast(&addr.mem[0]), @as(usize, addr.len)) catch return AmpeError.ListenFailed;
    return Skt{ .fd = fd, .address = addr.*, .server = true };
}

/// Create a non-blocking client socket (no connect). Caller calls Skt.connect() next.
pub fn createConnectSocket(addr: *const pn.Addr) !Skt {
    const fd = pn.createClientSocket(@intCast(pn.addrFamily(addr))) catch return AmpeError.ConnectFailed;
    pn.setLingerAbort(fd);
    return Skt{ .fd = fd, .address = addr.* };
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
