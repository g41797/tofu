const std = @import("std");
const tofu = @import("../../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
const pn = @import("posix_net");

pub const Skt = @This();

fd: pn.Fd = pn.INVALID_FD,
address: pn.Addr = std.mem.zeroes(pn.Addr),
server: bool = false,

pub fn isSet(skt: *const Skt) bool {
    return skt.fd != pn.INVALID_FD;
}

pub fn rawFd(skt: *const Skt) i32 {
    if (@TypeOf(skt.fd) == usize) {
        return @bitCast(@as(u32, @truncate(skt.fd)));
    }
    return skt.fd;
}

pub fn socketHandle(skt: *const Skt) ?pn.Fd {
    if (!skt.isSet()) return null;
    return skt.fd;
}

pub fn getPort(skt: *const Skt) ?u16 {
    var addr: pn.Addr = undefined;
    pn.localAddr(skt.fd, &addr) catch return null;
    return pn.addrPort(&addr);
}

// No-op: bind+listen are done by pn_create_listen_socket in SocketCreator.
pub fn listen(_: *Skt) !void {}

pub fn accept(askt: *Skt) AmpeError!?Skt {
    var addr: pn.Addr = undefined;
    const client_fd = pn.acceptSocket(askt.fd, &addr) catch |e| {
        if (e == pn.PnError.WouldBlock) return null;
        return toAmpe(e);
    };
    pn.setLingerAbort(client_fd);
    return Skt{ .fd = client_fd, .address = addr };
}

/// Connect the socket to the stored address.
/// Returns false when connect is in progress (EINPROGRESS/WSAEWOULDBLOCK); caller waits for WRITABLE.
/// Returns true when immediately connected.
pub fn connect(skt: *Skt) AmpeError!bool {
    if (pn.addrFamily(&skt.address) == @as(u16, @intCast(pn.AF_UNIX))) {
        const path = pn.addrUnixPath(&skt.address);
        pn.connectSocketUnix(skt.fd, path) catch |e| {
            if (e == pn.PnError.WouldBlock) return false;
            return toAmpe(e);
        };
        return true;
    }
    pn.connectSocket(skt.fd, @ptrCast(&skt.address.mem[0]), @intCast(skt.address.len)) catch |e| {
        if (e == pn.PnError.WouldBlock) return false;
        return toAmpe(e);
    };
    return true;
}

// No-op: SO_REUSEADDR is set internally by bsd_create_listen_socket.
pub fn setREUSE(_: *Skt) !void {}

pub fn setLingerAbort(skt: *Skt) AmpeError!void {
    pn.setLingerAbort(skt.fd);
}

pub fn disableNagle(skt: *Skt) !void {
    const family = pn.addrFamily(&skt.address);
    if (family == @as(u16, @intCast(pn.AF_INET)) or family == @as(u16, @intCast(pn.AF_INET6))) {
        pn.nodelay(skt.fd, true);
    }
}

pub fn findFreeTcpPort() !u16 {
    return pn.findFreeTcpPort() catch |e| toAmpe(e);
}

pub fn sendBufFd(socket: pn.Fd, buf: []const u8) AmpeError!?usize {
    return pn.sendBuf(socket, buf) catch |e| toAmpe(e);
}

pub fn recvToBufFd(socket: pn.Fd, buf: []u8) AmpeError!?usize {
    return pn.recvToBuf(socket, buf) catch |e| toAmpe(e);
}

pub fn sendBuf(skt: *Skt, buf: []const u8) AmpeError!?usize {
    return sendBufFd(skt.fd, buf);
}

pub fn recvToBuf(skt: *Skt, buf: []u8) AmpeError!?usize {
    return recvToBufFd(skt.fd, buf);
}

pub fn deinit(skt: *Skt) void {
    skt.close();
}

pub fn close(skt: *Skt) void {
    if (skt.fd != pn.INVALID_FD) {
        deleteUDSPath(skt);
        pn.closeSocket(skt.fd);
        skt.fd = pn.INVALID_FD;
    }
}

fn deleteUDSPath(skt: *Skt) void {
    if (!skt.server) return;
    if (pn.addrFamily(&skt.address) != @as(u16, @intCast(pn.AF_UNIX))) return;
    const path = pn.addrUnixPath(&skt.address);
    if (path.len == 0 or path[0] == 0) return;
    var path_buf: [pn.UDS_PATH_SIZE + 1:0]u8 = .{0} ** (pn.UDS_PATH_SIZE + 1);
    const copy_len = @min(path.len, pn.UDS_PATH_SIZE);
    @memcpy(path_buf[0..copy_len], path[0..copy_len]);
    pn.deleteUnixPath(@ptrCast(&path_buf));
}

fn toAmpe(e: pn.PnError) AmpeError {
    return switch (e) {
        pn.PnError.WouldBlock => AmpeError.UnknownError,
        pn.PnError.PeerDisconnected => AmpeError.PeerDisconnected,
        pn.PnError.InvalidAddress => AmpeError.InvalidAddress,
        pn.PnError.AllocationFailed => AmpeError.AllocationFailed,
        pn.PnError.CommunicationFailed => AmpeError.CommunicationFailed,
        pn.PnError.UDSPathNotFound => AmpeError.UDSPathNotFound,
    };
}
