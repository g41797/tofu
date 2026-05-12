// Socket operations and address accessors.

const std = @import("std");
const ffi = @import("ffi.zig");
const types = @import("types.zig");
const Fd = types.Fd;
const Addr = types.Addr;
const PnError = types.PnError;

/// Send data from a buffer.
pub fn sendBuf(fd: Fd, buf: []const u8) PnError!?usize {
    const n = ffi.bsd_send(fd, buf.ptr, @intCast(buf.len), 0);
    if (n < 0) {
        if (ffi.bsd_would_block() != 0) return null;
        return PnError.CommunicationFailed;
    }
    if (n == 0) return null;
    return @as(usize, @intCast(n));
}

/// Receive data into a buffer.
pub fn recvToBuf(fd: Fd, buf: []u8) PnError!?usize {
    const n = ffi.bsd_recv(fd, buf.ptr, @intCast(buf.len), 0);
    if (n < 0) {
        if (ffi.bsd_would_block() != 0) return null;
        return PnError.CommunicationFailed;
    }
    if (n == 0) return PnError.PeerDisconnected;
    return @as(usize, @intCast(n));
}

/// Accept a new connection.
pub fn acceptSocket(fd: Fd, addr: *Addr) PnError!Fd {
    const client_fd = ffi.bsd_accept_socket(fd, addr);
    if (client_fd == ffi.INVALID_FD) {
        if (ffi.bsd_would_block() != 0) return PnError.WouldBlock;
        return PnError.CommunicationFailed;
    }
    return client_fd;
}

/// Close a socket descriptor.
pub fn closeSocket(fd: Fd) void {
    ffi.bsd_close_socket(fd);
}

/// Shutdown socket for both read and write.
pub fn shutdownSocket(fd: Fd) void {
    ffi.bsd_shutdown_socket(fd);
}

/// Shutdown socket for reading.
pub fn shutdownSocketRead(fd: Fd) void {
    ffi.bsd_shutdown_socket_read(fd);
}

/// Connect an existing non-blocking socket to addr.
/// Returns PnError.WouldBlock when in progress (EINPROGRESS / WSAEWOULDBLOCK).
/// Caller returns false and waits for WRITABLE, then calls connect again to confirm.
pub fn connectSocket(fd: Fd, addr: *const anyopaque, addrlen: c_int) PnError!void {
    const rc: c_int = ffi.pn_connect_socket(fd, addr, addrlen);
    if (rc == 0) return;
    if (rc == 1) return PnError.WouldBlock;
    return PnError.CommunicationFailed;
}

/// Connect a Unix Domain Socket to a path.
/// Returns PnError.WouldBlock when connect is in progress (EINPROGRESS/EALREADY on non-blocking socket).
/// Caller should return false (not yet connected) and retry when WRITABLE fires.
pub fn connectSocketUnix(fd: Fd, path: []const u8) PnError!void {
    const rc = ffi.bsd_connect_socket_unix(fd, path.ptr, path.len);
    if (rc == 0) return;
    const builtin = @import("builtin");
    const os = builtin.os.tag;
    const ENOENT: c_int   = if (os == .windows) 3    else 2;
    const EINPROGRESS: c_int = if (os == .windows) 10036 else if (os == .macos) 36 else 115;
    const EALREADY: c_int    = if (os == .windows) 10037 else if (os == .macos) 37 else 114;
    const EISCONN: c_int     = if (os == .windows) 10056 else if (os == .macos) 56 else 106;
    if (rc == ENOENT) return PnError.UDSPathNotFound;
    if (rc == EINPROGRESS or rc == EALREADY) return PnError.WouldBlock;
    // EISCONN: non-blocking connect completed in the background; already connected.
    if (rc == EISCONN) return;
    return PnError.CommunicationFailed;
}

/// Set SO_LINGER with l_linger=0: close sends RST, no TIME_WAIT.
pub fn setLingerAbort(fd: Fd) void {
    ffi.bsd_set_linger_abort(fd);
}

/// Enable or disable TCP_NODELAY.
pub fn nodelay(fd: Fd, enabled: bool) void {
    ffi.bsd_socket_nodelay(fd, if (enabled) 1 else 0);
}

/// Enable or disable TCP keepalive.
pub fn keepalive(fd: Fd, enabled: bool, delay: u32) void {
    _ = ffi.bsd_socket_keepalive(fd, if (enabled) 1 else 0, delay);
}

/// Check if the last operation would have blocked.
pub fn wouldBlock() bool {
    return ffi.bsd_would_block() != 0;
}

/// Get the local address of a socket.
pub fn localAddr(fd: Fd, addr: *Addr) PnError!void {
    if (ffi.bsd_local_addr(fd, addr) != 0) return PnError.CommunicationFailed;
}

/// Get the remote address of a socket.
pub fn remoteAddr(fd: Fd, addr: *Addr) PnError!void {
    if (ffi.bsd_remote_addr(fd, addr) != 0) return PnError.CommunicationFailed;
}

/// Get the address family (AF_INET, AF_INET6, AF_UNIX).
pub fn addrFamily(addr: *const Addr) u16 {
    const builtin = @import("builtin");
    if (comptime (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD())) {
        // macOS/BSD: sa_len (u8) at mem[0], sa_family (u8) at mem[1]
        return addr.mem[1];
    }
    // Linux/Windows: sa_family (u16) at mem[0]
    const family_ptr: *const u16 = @ptrCast(@alignCast(&addr.mem[0]));
    return family_ptr.*;
}

/// Get the port from an address.
pub fn addrPort(addr: *const Addr) ?u16 {
    const port = ffi.bsd_addr_get_port(addr);
    if (port <= 0) return null;
    return @intCast(port);
}

/// Get the Unix Domain Socket path from an address.
pub fn addrUnixPath(addr: *const Addr) []const u8 {
    const AF_UNIX = 1; // Standard value; will be checked in tests
    if (addrFamily(addr) != AF_UNIX) return "";
    // Offset 2 in sockaddr_un for sun_path
    const path_ptr: [*:0]const u8 = @ptrCast(&addr.mem[2]);
    return std.mem.span(path_ptr);
}

/// Delete a file at the given path.
pub fn deleteUnixPath(path: [*:0]const u8) void {
    if (comptime @import("builtin").os.tag == .windows) {
        _ = ffi._unlink(path);
    } else {
        _ = ffi.unlink(path);
    }
}
