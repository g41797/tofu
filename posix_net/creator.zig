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

/// Create a connecting TCP socket. bsd_create_connect_socket handles DNS resolution internally.
pub fn createConnectSocket(host: [*:0]const u8, port: u16, options: i32) PnError!Fd {
    const fd = ffi.bsd_create_connect_socket(host, @intCast(port), null, @intCast(options));
    if (fd == ffi.INVALID_FD) return PnError.CommunicationFailed;
    return fd;
}

/// Create a connecting Unix Domain Socket. Supports abstract namespace (path[0] == 0).
pub fn createConnectSocketUnix(path: [*]const u8, pathlen: usize, options: i32) PnError!Fd {
    const fd = ffi.pn_create_connect_socket_unix(path, pathlen, @intCast(options));
    if (fd == ffi.INVALID_FD) return PnError.CommunicationFailed;
    return fd;
}

/// Find a free TCP port by binding to port 0.
pub fn findFreeTcpPort() PnError!u16 {
    const fd = try createListenSocket("0.0.0.0", 0, 0);
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
        // bsd_create_connect_socket handles connection; use host+port directly.
        const fd = try createConnectSocket(host.ptr, port, 0);
        // Non-blocking connect may be in-progress (EINPROGRESS on macOS).
        // Wait up to 5 s for the connect to complete before returning.
        if (ffi.pn_wait_writable(fd, 5000) != 0) {
            ffi.bsd_close_socket(fd);
            return PnError.CommunicationFailed;
        }
        return fd;
    }
    return PnError.CommunicationFailed;
}
