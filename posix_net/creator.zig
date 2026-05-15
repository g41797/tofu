// Functions for creating and resolving sockets.

const std = @import("std");
const ffi = @import("ffi.zig");
const types = @import("types.zig");
const socket = @import("socket.zig");
const Fd = types.Fd;
const PnError = types.PnError;

/// Create a raw socket descriptor.
pub fn createSocket(domain: i32, socket_type: i32, protocol: i32) PnError!Fd {
    const fd = ffi.bsd_create_socket(@intCast(domain), @intCast(socket_type), @intCast(protocol));
    if (fd == ffi.INVALID_FD) return PnError.CommunicationFailed;
    return fd;
}

/// Create a listening TCP socket.
pub fn createListenSocket(host: [*:0]const u8, port: u16, options: i32) PnError!Fd {
    const fd = ffi.pn_create_listen_socket(host, @intCast(port), @intCast(options), 1024);
    if (fd == ffi.INVALID_FD) return PnError.CommunicationFailed;
    return fd;
}

/// Create a listening Unix Domain Socket. Supports abstract namespace (path[0] == 0).
pub fn createListenSocketUnix(path: [*]const u8, pathlen: usize, options: i32) PnError!Fd {
    const fd = ffi.pn_create_listen_socket_unix(path, pathlen, @intCast(options), 1024);
    if (fd == ffi.INVALID_FD) return PnError.CommunicationFailed;
    return fd;
}

/// Create a non-blocking client socket (TCP or UDS). No connect — caller calls connectSocket/connectSocketUnix.
pub fn createClientSocket(family: i32) PnError!Fd {
    const fd = ffi.bsd_create_socket(@intCast(family), @intCast(types.SOCK_STREAM), 0);
    if (fd == ffi.INVALID_FD) return PnError.CommunicationFailed;
    _ = ffi.bsd_set_nonblocking(fd);
    return fd;
}

/// Create a connecting Unix Domain Socket. Supports abstract namespace (path[0] == 0).
pub fn createConnectSocketUnix(path: [*]const u8, pathlen: usize, options: i32) PnError!Fd {
    const fd = ffi.pn_create_connect_socket_unix(path, pathlen, @intCast(options));
    if (fd == ffi.INVALID_FD) return PnError.CommunicationFailed;
    return fd;
}

/// Create a listening TCP/IP socket from an existing sockaddr. Used by portable backend
/// to avoid reformatting std.net.Address back to a host string.
pub fn createListenSocketFromSockaddr(addr: *const anyopaque, addrlen: usize) PnError!Fd {
    const fd = ffi.pn_create_listen_socket_from_sockaddr(addr, @intCast(addrlen), 1024);
    if (fd == ffi.INVALID_FD) return PnError.CommunicationFailed;
    return fd;
}

/// Find a free TCP port by binding to port 0.
pub fn findFreeTcpPort() PnError!u16 {
    const fd = try createListenSocket("127.0.0.1", 0, 0);
    defer socket.closeSocket(fd);

    var addr: types.Addr = undefined;
    try socket.localAddr(fd, &addr);
    return socket.addrPort(&addr) orelse PnError.CommunicationFailed;
}

/// Resolve a hostname and port to a socket descriptor using getaddrinfo, then connect.
pub fn resolveConnect(host: [:0]const u8, port: u16) PnError!Fd {
    const hints: ffi.addrinfo = .{
        .ai_flags = 0,
        .ai_family = 0,
        .ai_socktype = 1, // SOCK_STREAM
        .ai_protocol = 0,
        .ai_addrlen = 0,
        .ai_addr = null,
        .ai_canonname = null,
        .ai_next = null,
    };

    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return PnError.InvalidAddress;

    var res: ?*ffi.addrinfo = null;
    if (ffi.getaddrinfo(host.ptr, port_str.ptr, &hints, &res) != 0) return PnError.InvalidAddress;
    defer if (res) |r| ffi.freeaddrinfo(r);

    if (res != null) {
        const ai_addr = res.?.ai_addr orelse return PnError.InvalidAddress;
        const fd: Fd = try createClientSocket(@intCast(res.?.ai_family));
        if (ffi.pn_connect_socket(fd, @ptrCast(ai_addr), @intCast(res.?.ai_addrlen)) < 0) {
            ffi.bsd_close_socket(fd);
            return PnError.CommunicationFailed;
        }
        // Wait for non-blocking connect to complete (EINPROGRESS on macOS is common).
        if (ffi.pn_wait_writable(fd, 5000) != 0) {
            ffi.bsd_close_socket(fd);
            return PnError.CommunicationFailed;
        }
        return fd;
    }
    return PnError.CommunicationFailed;
}
