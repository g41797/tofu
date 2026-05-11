const std = @import("std");
const tofu = @import("../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
const pn = @import("posix_net");

pub const Skt = @This();

/// Socket descriptor.
fd: pn.Fd = -1,

/// Path to Unix Domain Socket file. Used for unlinking servers and delayed connect for clients.
uds_server_path: ?[pn.UDS_PATH_SIZE]u8 = null,

/// Flag to distinguish server sockets for UDS unlinking.
server: bool = false,

/// Returns true if the socket descriptor is valid.
pub fn isSet(skt: *const Skt) bool {
    return skt.fd >= 0;
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

/// Returns the local port of the socket.
pub fn getPort(skt: *const Skt) ?u16 {
    var addr: pn.Addr = undefined;
    pn.localAddr(skt.fd, &addr) catch return null;
    return pn.addrPort(&addr);
}

/// No-op: Socket creation in SocketCreator already performs listen.
pub fn listen(skt: *Skt) !void {
    _ = skt;
}

/// Accept a new connection.
pub fn accept(askt: *Skt) AmpeError!?Skt {
    var addr: pn.Addr = undefined;
    const client_fd = pn.acceptSocket(askt.fd, &addr) catch |e| {
        if (e == pn.PnError.WouldBlock) return null;
        return toAmpe(e);
    };
    return Skt{ .fd = client_fd };
}

/// Connect a socket. For UDS, performs delayed connect if path is stored.
/// Returns false when connect is in progress (EINPROGRESS/EALREADY); caller waits for WRITABLE.
pub fn connect(skt: *Skt) AmpeError!bool {
    if (skt.uds_server_path) |path| {
        if (!skt.server) {
            const len = std.mem.indexOfScalar(u8, &path, 0) orelse pn.UDS_PATH_SIZE;
            pn.connectSocketUnix(skt.fd, path[0..len]) catch |e| {
                if (e == pn.PnError.WouldBlock) return false;
                return toAmpe(e);
            };
        }
    }
    return true;
}

/// No-op: Already handled by pn.createListenSocket.
pub fn setREUSE(skt: *Skt) !void {
    _ = skt;
}

/// No-op: Already handled by pn.closeSocket in bun-usockets.
pub fn setLingerAbort(skt: *Skt) AmpeError!void {
    _ = skt;
}

/// Enable or disable TCP_NODELAY.
pub fn disableNagle(skt: *Skt) !void {
    pn.nodelay(skt.fd, true);
}

/// Find a free TCP port by binding to port 0.
pub fn findFreeTcpPort() !u16 {
    return pn.findFreeTcpPort() catch |e| toAmpe(e);
}

/// Send data from a buffer using raw descriptor.
pub fn sendBufFd(socket: pn.Fd, buf: []const u8) AmpeError!?usize {
    return pn.sendBuf(socket, buf) catch |e| toAmpe(e);
}

/// Receive data into a buffer using raw descriptor.
pub fn recvToBufFd(socket: pn.Fd, buf: []u8) AmpeError!?usize {
    return pn.recvToBuf(socket, buf) catch |e| toAmpe(e);
}

/// Send data from a buffer.
pub fn sendBuf(skt: *Skt, buf: []const u8) AmpeError!?usize {
    return sendBufFd(skt.fd, buf);
}

/// Receive data into a buffer.
pub fn recvToBuf(skt: *Skt, buf: []u8) AmpeError!?usize {
    return recvToBufFd(skt.fd, buf);
}

/// Close socket and cleanup UDS path if necessary.
pub fn deinit(skt: *Skt) void {
    skt.close();
}

/// Close the socket and reset descriptor.
pub fn close(skt: *Skt) void {
    if (skt.fd >= 0) {
        if (skt.server and skt.uds_server_path != null) {
            const path = skt.uds_server_path.?;
            var path_buf: [pn.UDS_PATH_SIZE + 1:0]u8 = undefined;
            @memcpy(path_buf[0..pn.UDS_PATH_SIZE], &path);
            path_buf[pn.UDS_PATH_SIZE] = 0;
            const len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse pn.UDS_PATH_SIZE;
            if (len > 0 and path_buf[0] != 0) {
                pn.deleteUnixPath(@ptrCast(&path_buf));
            }
        }
        pn.closeSocket(skt.fd);
        skt.fd = -1;
    }
}

/// Translate PnError to AmpeError.
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
