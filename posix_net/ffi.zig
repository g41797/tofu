// Raw C extern declarations for bun-usockets and platform APIs.
// This file is internal to the posix_net module.

const std = @import("std");

pub const LIBUS_SOCKET_DESCRIPTOR = if (@import("builtin").os.tag == .windows) usize else c_int;
pub const INVALID_FD: LIBUS_SOCKET_DESCRIPTOR = if (@import("builtin").os.tag == .windows) std.math.maxInt(usize) else -1;

// pn_utils.c — our wrappers over bsd_create_listen_socket with explicit backlog and SO_LINGER helpers
pub extern fn bsd_set_linger_abort(fd: LIBUS_SOCKET_DESCRIPTOR) void;
pub extern fn pn_create_listen_socket(host: [*:0]const u8, port: c_int, options: c_int, backlog: c_int) LIBUS_SOCKET_DESCRIPTOR;
pub extern fn pn_create_listen_socket_unix(path: [*]const u8, pathlen: usize, options: c_int, backlog: c_int) LIBUS_SOCKET_DESCRIPTOR;
pub extern fn pn_create_connect_socket_unix(path: [*]const u8, pathlen: usize, options: c_int) LIBUS_SOCKET_DESCRIPTOR;
pub extern fn pn_wait_writable(fd: LIBUS_SOCKET_DESCRIPTOR, timeout_ms: c_int) c_int;
pub extern fn pn_connect_socket(fd: LIBUS_SOCKET_DESCRIPTOR, addr: *const anyopaque, addrlen: c_int) c_int;
pub extern fn pn_create_listen_socket_from_sockaddr(addr: *const anyopaque, addrlen: c_int, backlog: c_int) LIBUS_SOCKET_DESCRIPTOR;

// BSD networking wrappers from bun-usockets
pub extern fn bsd_create_listen_socket(host: [*:0]const u8, port: c_int, options: c_int) LIBUS_SOCKET_DESCRIPTOR;
pub extern fn bsd_create_listen_socket_unix(path: [*]const u8, pathlen: usize, options: c_int) LIBUS_SOCKET_DESCRIPTOR;
pub extern fn bsd_create_socket(domain: c_int, type: c_int, protocol: c_int) LIBUS_SOCKET_DESCRIPTOR;
pub extern fn bsd_connect_socket_unix(fd: LIBUS_SOCKET_DESCRIPTOR, path: [*]const u8, pathlen: usize) c_int;
pub extern fn bsd_accept_socket(fd: LIBUS_SOCKET_DESCRIPTOR, addr: *anyopaque) LIBUS_SOCKET_DESCRIPTOR;
pub extern fn bsd_recv(fd: LIBUS_SOCKET_DESCRIPTOR, buf: [*]u8, length: c_int, flags: c_int) c_int;
pub extern fn bsd_send(fd: LIBUS_SOCKET_DESCRIPTOR, buf: [*]const u8, length: c_int, msg_more: c_int) c_int;
pub extern fn bsd_close_socket(fd: LIBUS_SOCKET_DESCRIPTOR) void;
pub extern fn bsd_shutdown_socket(fd: LIBUS_SOCKET_DESCRIPTOR) void;
pub extern fn bsd_shutdown_socket_read(fd: LIBUS_SOCKET_DESCRIPTOR) void;
pub extern fn bsd_set_nonblocking(fd: LIBUS_SOCKET_DESCRIPTOR) LIBUS_SOCKET_DESCRIPTOR;
pub extern fn bsd_socket_nodelay(fd: LIBUS_SOCKET_DESCRIPTOR, enabled: c_int) void;
pub extern fn bsd_socket_keepalive(fd: LIBUS_SOCKET_DESCRIPTOR, on: c_int, delay: c_uint) c_int;
pub extern fn bsd_would_block() c_int;
pub extern fn bsd_addr_get_port(addr: *const anyopaque) c_int;
pub extern fn bsd_local_addr(fd: LIBUS_SOCKET_DESCRIPTOR, addr: *anyopaque) c_int;
pub extern fn bsd_remote_addr(fd: LIBUS_SOCKET_DESCRIPTOR, addr: *anyopaque) c_int;
pub extern fn bsd_addr_get_ip(addr: *const anyopaque) [*]u8;
pub extern fn bsd_addr_get_ip_length(addr: *const anyopaque) c_int;

// Event loop and polling from bun-usockets
pub extern fn us_create_loop(hint: ?*anyopaque, wakeup_cb: ?*anyopaque, pre_cb: ?*anyopaque, post_cb: ?*anyopaque, ext_size: c_uint) ?*anyopaque;
pub extern fn us_loop_free(loop: *anyopaque) void;
pub extern fn us_create_poll(loop: *anyopaque, fallthrough: c_int, ext_size: c_uint) ?*anyopaque;
pub extern fn us_poll_free(p: *anyopaque, loop: *anyopaque) void;
pub extern fn us_poll_init(p: *anyopaque, fd: LIBUS_SOCKET_DESCRIPTOR, poll_type: c_int) void;
pub extern fn us_poll_start(p: *anyopaque, loop: *anyopaque, events: c_int) void;
pub extern fn us_poll_change(p: *anyopaque, loop: *anyopaque, events: c_int) void;
pub extern fn us_poll_stop(p: *anyopaque, loop: *anyopaque) void;
pub extern fn us_poll_ext(p: *anyopaque) *anyopaque;
pub extern fn us_loop_run_tick(loop: *anyopaque, timeout_ms: c_int) void;
pub extern fn us_internal_poll_type(p: *anyopaque) c_int;

// Platform APIs
pub extern fn unlink(path: [*:0]const u8) c_int;   // POSIX (Linux, macOS)
pub extern fn _unlink(path: [*:0]const u8) c_int;  // Windows (gnu + msvc)

// DNS resolution via libc
// Windows ADDRINFOA: ai_addrlen is SIZE_T (8 bytes on x64); ai_canonname before ai_addr.
// POSIX addrinfo: ai_addrlen is socklen_t (4 bytes); ai_addr before ai_canonname.
const addrinfo_win = extern struct {
    ai_flags: c_int,
    ai_family: c_int,
    ai_socktype: c_int,
    ai_protocol: c_int,
    ai_addrlen: usize,
    ai_canonname: ?[*:0]u8,
    ai_addr: ?*std.c.sockaddr,
    ai_next: ?*addrinfo_win,
};
const addrinfo_posix = extern struct {
    ai_flags: c_int,
    ai_family: c_int,
    ai_socktype: c_int,
    ai_protocol: c_int,
    ai_addrlen: std.c.socklen_t,
    ai_addr: ?*std.c.sockaddr,
    ai_canonname: ?[*:0]u8,
    ai_next: ?*addrinfo_posix,
};
pub const addrinfo = if (@import("builtin").os.tag == .windows) addrinfo_win else addrinfo_posix;

pub extern fn getaddrinfo(node: ?[*:0]const u8, service: ?[*:0]const u8, hints: ?*const addrinfo, res: *?*addrinfo) c_int;
pub extern fn freeaddrinfo(res: *addrinfo) void;
