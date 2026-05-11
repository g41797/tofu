// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

// Contract tests for the posix_net module.
// All operations use bsd_* wrappers — no std.posix calls.

test {
    std.testing.log_level = .debug;
    std.log.debug("posix_net_tests\r\n", .{});
}

test "platform init" {
    try tofu.initPlatform();
}

// ---------------------------------------------------------------------------
// Retry helpers
// ---------------------------------------------------------------------------

const MAX_RETRIES = 10_000;
const SLEEP_NS = 1 * std.time.ns_per_ms;

// AF constants (Linux/macOS standard values)
const AF_INET: u16 = 2;
const AF_UNIX: u16 = 1;

fn acceptFd(listen_fd: pn.Fd, addr: *pn.Addr) !pn.Fd {
    for (0..MAX_RETRIES) |_| {
        if (pn.acceptSocket(listen_fd, addr)) |fd| {
            return fd;
        } else |e| {
            if (e != pn.PnError.WouldBlock) return e;
        }
        std.Thread.sleep(SLEEP_NS);
    }
    return error.TimeoutAccept;
}

fn recvAll(fd: pn.Fd, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        if (try pn.recvToBuf(fd, buf[got..])) |n| {
            if (n == 0) return error.PeerDisconnected;
            got += n;
        } else {
            std.Thread.sleep(SLEEP_NS);
        }
    }
}

fn sendAll(fd: pn.Fd, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        if (try pn.sendBuf(fd, data[sent..])) |n| sent += n else std.Thread.sleep(SLEEP_NS);
    }
}

// ---------------------------------------------------------------------------
// Group 1 — Socket Creation
// ---------------------------------------------------------------------------

test "bsd TCP listen socket on 127.0.0.1 creates valid fd" {
    const port: u16 = try pn.findFreeTcpPort();
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(fd);
    try testing.expect(fd != pn.INVALID_FD);
}

test "bsd UDS listen socket on temp path creates valid fd" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(testing.allocator);
    defer _ = pn.deleteUnixPath(@ptrCast(path.ptr));
    const fd: pn.Fd = try pn.createListenSocketUnix(path.ptr, path.len, 0);
    defer pn.closeSocket(fd);
    try testing.expect(fd != pn.INVALID_FD);
}

test "bsd TCP resolveConnect to listening server creates valid fd" {
    const port: u16 = try pn.findFreeTcpPort();
    const listen_fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(listen_fd);
    const client_fd: pn.Fd = try pn.resolveConnect("127.0.0.1", port);
    defer pn.closeSocket(client_fd);
    try testing.expect(client_fd != pn.INVALID_FD);
}

test "bsd UDS connect socket to listener creates valid fd" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(testing.allocator);
    defer _ = pn.deleteUnixPath(@ptrCast(path.ptr));
    const listen_fd: pn.Fd = try pn.createListenSocketUnix(path.ptr, path.len, 0);
    defer pn.closeSocket(listen_fd);
    const client_fd: pn.Fd = try pn.createConnectSocketUnix(path.ptr, path.len, 0);
    defer pn.closeSocket(client_fd);
    try testing.expect(client_fd != pn.INVALID_FD);
}

test "bsd UDS connect to nonexistent path returns error" {
    const path = "/tmp/pn_no_such_socket_xyz.sock";
    const result = pn.createConnectSocketUnix(path.ptr, path.len, 0);
    try testing.expectError(pn.PnError.CommunicationFailed, result);
}

test "bsd findFreeTcpPort returns bindable port" {
    const port: u16 = try pn.findFreeTcpPort();
    try testing.expect(port > 0);
    // Verify the port can actually be bound.
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    pn.closeSocket(fd);
}

// ---------------------------------------------------------------------------
// Group 2 — Single-socket state
// ---------------------------------------------------------------------------

test "bsd_close_socket on valid fd is safe" {
    const port: u16 = try pn.findFreeTcpPort();
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    pn.closeSocket(fd);
}

test "bsd_accept_socket before client returns WouldBlock" {
    const port: u16 = try pn.findFreeTcpPort();
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(fd);
    var addr: pn.Addr = undefined;
    const result = pn.acceptSocket(fd, &addr);
    try testing.expectError(pn.PnError.WouldBlock, result);
}

test "bsd_would_block is true after WouldBlock accept" {
    const port: u16 = try pn.findFreeTcpPort();
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(fd);
    var addr: pn.Addr = undefined;
    _ = pn.acceptSocket(fd, &addr) catch {};
    try testing.expect(pn.wouldBlock());
}

// ---------------------------------------------------------------------------
// Group 3 — Data transfer (two threads)
// ---------------------------------------------------------------------------

const TcpCtx = struct {
    listen_fd: pn.Fd = pn.INVALID_FD,
    received: [1000]u8 = undefined,
    recv_len: usize = 0,
    accepted_set: bool = false,
    err: ?anyerror = null,
};

fn tcpServerRecv(ctx: *TcpCtx) void {
    var addr: pn.Addr = undefined;
    const conn_fd: pn.Fd = acceptFd(ctx.listen_fd, &addr) catch |e| {
        ctx.err = e;
        return;
    };
    defer pn.closeSocket(conn_fd);
    recvAll(conn_fd, ctx.received[0..]) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.recv_len = ctx.received.len;
}

fn tcpServerImmediateRecv(ctx: *TcpCtx) void {
    var addr: pn.Addr = undefined;
    const conn_fd: pn.Fd = acceptFd(ctx.listen_fd, &addr) catch |e| {
        ctx.err = e;
        return;
    };
    defer pn.closeSocket(conn_fd);
    // Recv before client sends — must return null (WouldBlock).
    const result = pn.recvToBuf(conn_fd, ctx.received[0..]) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.recv_len = if (result == null) 0 else result.?;
    ctx.accepted_set = true;
}

test "bsd TCP send+recv roundtrip" {
    const port: u16 = try pn.findFreeTcpPort();
    var ctx: TcpCtx = .{};
    ctx.listen_fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(ctx.listen_fd);
    const t = try std.Thread.spawn(.{}, tcpServerRecv, .{&ctx});
    const client_fd: pn.Fd = try pn.resolveConnect("127.0.0.1", port);
    defer pn.closeSocket(client_fd);
    var payload: [1000]u8 = undefined;
    @memset(&payload, 0xAB);
    try sendAll(client_fd, &payload);
    t.join();
    try testing.expect(ctx.err == null);
    try testing.expectEqual(@as(usize, 1000), ctx.recv_len);
    try testing.expectEqualSlices(u8, &payload, &ctx.received);
}

const UdsCtx = struct {
    path: [108]u8 = undefined,
    path_len: usize = 0,
    received: [1000]u8 = undefined,
    recv_len: usize = 0,
    err: ?anyerror = null,

    fn pathSlice(ctx: *const UdsCtx) []const u8 {
        return ctx.path[0..ctx.path_len];
    }
};

fn udsServerRecv(ctx: *UdsCtx) void {
    const listen_fd: pn.Fd = pn.createListenSocketUnix(ctx.pathSlice().ptr, ctx.pathSlice().len, 0) catch |e| {
        ctx.err = e;
        return;
    };
    defer pn.closeSocket(listen_fd);
    var addr: pn.Addr = undefined;
    const conn_fd: pn.Fd = acceptFd(listen_fd, &addr) catch |e| {
        ctx.err = e;
        return;
    };
    defer pn.closeSocket(conn_fd);
    recvAll(conn_fd, ctx.received[0..]) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.recv_len = ctx.received.len;
}

test "bsd UDS send+recv roundtrip" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(testing.allocator);
    defer _ = pn.deleteUnixPath(@ptrCast(path.ptr));
    var ctx: UdsCtx = .{};
    ctx.path_len = path.len;
    @memcpy(ctx.path[0..path.len], path);
    const t = try std.Thread.spawn(.{}, udsServerRecv, .{&ctx});
    std.Thread.sleep(5 * std.time.ns_per_ms);
    const client_fd: pn.Fd = try pn.createConnectSocketUnix(ctx.pathSlice().ptr, ctx.pathSlice().len, 0);
    defer pn.closeSocket(client_fd);
    var payload: [1000]u8 = undefined;
    @memset(&payload, 0xCD);
    try sendAll(client_fd, &payload);
    t.join();
    try testing.expect(ctx.err == null);
    try testing.expectEqual(@as(usize, 1000), ctx.recv_len);
    try testing.expectEqualSlices(u8, &payload, &ctx.received);
}

test "bsd_recv returns null (WouldBlock) when no data ready" {
    const port: u16 = try pn.findFreeTcpPort();
    var ctx: TcpCtx = .{};
    ctx.listen_fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(ctx.listen_fd);
    const t = try std.Thread.spawn(.{}, tcpServerImmediateRecv, .{&ctx});
    const client_fd: pn.Fd = try pn.resolveConnect("127.0.0.1", port);
    defer pn.closeSocket(client_fd);
    for (0..MAX_RETRIES) |_| {
        if (ctx.accepted_set or ctx.err != null) break;
        std.Thread.sleep(SLEEP_NS);
    }
    t.join();
    try testing.expect(ctx.err == null);
    try testing.expectEqual(@as(usize, 0), ctx.recv_len);
}

test "bsd_send returns null (WouldBlock) when send buffer full" {
    const port: u16 = try pn.findFreeTcpPort();
    const listen_fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(listen_fd);
    const client_fd: pn.Fd = try pn.resolveConnect("127.0.0.1", port);
    defer pn.closeSocket(client_fd);
    // Fill the send buffer until WouldBlock.
    var buf: [65536]u8 = undefined;
    @memset(&buf, 0xFF);
    var got_would_block = false;
    for (0..1000) |_| {
        if (try pn.sendBuf(client_fd, &buf)) |_| {} else {
            got_would_block = true;
            break;
        }
    }
    try testing.expect(got_would_block);
}

// ---------------------------------------------------------------------------
// Group 4 — Socket options
// ---------------------------------------------------------------------------

test "bsd_socket_nodelay on TCP fd succeeds" {
    const port: u16 = try pn.findFreeTcpPort();
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(fd);
    pn.nodelay(fd, true);
}

test "bsd_socket_keepalive on TCP fd succeeds" {
    const port: u16 = try pn.findFreeTcpPort();
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(fd);
    pn.keepalive(fd, true, 60);
}

// ---------------------------------------------------------------------------
// Group 5 — Address info
// ---------------------------------------------------------------------------

test "bsd_local_addr + bsd_addr_get_port return port matching listener" {
    const port: u16 = try pn.findFreeTcpPort();
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(fd);
    var addr: pn.Addr = undefined;
    try pn.localAddr(fd, &addr);
    const got_port = pn.addrPort(&addr);
    try testing.expectEqual(port, got_port.?);
}

test "bsd_remote_addr returns peer address after TCP connect" {
    const port: u16 = try pn.findFreeTcpPort();
    const listen_fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(listen_fd);
    const client_fd: pn.Fd = try pn.resolveConnect("127.0.0.1", port);
    defer pn.closeSocket(client_fd);
    var addr: pn.Addr = undefined;
    try pn.remoteAddr(client_fd, &addr);
    const remote_port = pn.addrPort(&addr);
    try testing.expectEqual(port, remote_port.?);
}

// ---------------------------------------------------------------------------
// Group 6 — Linux abstract UDS namespace
// ---------------------------------------------------------------------------

test "abstract UDS listen + connect + send roundtrip" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    // Abstract namespace: path starts with \x00, no filesystem entry.
    var srv_buf: [17]u8 = undefined;
    srv_buf[0] = 0;
    @memcpy(srv_buf[1..], "pn_abstract_test");
    const listen_fd: pn.Fd = try pn.createListenSocketUnix(&srv_buf, srv_buf.len, 0);
    defer pn.closeSocket(listen_fd);
    const client_fd: pn.Fd = try pn.createConnectSocketUnix(&srv_buf, srv_buf.len, 0);
    defer pn.closeSocket(client_fd);
    var addr: pn.Addr = undefined;
    const conn_fd: pn.Fd = try acceptFd(listen_fd, &addr);
    defer pn.closeSocket(conn_fd);
    const msg = "hello";
    _ = try pn.sendBuf(client_fd, msg);
    var buf: [5]u8 = undefined;
    _ = try pn.recvToBuf(conn_fd, &buf);
    try testing.expectEqualSlices(u8, msg, &buf);
}

// ---------------------------------------------------------------------------
// Group 7 — Poll layer
// ---------------------------------------------------------------------------

test "us_create_loop returns non-null loop" {
    const loop = pn.poll.createLoop();
    try testing.expect(loop != null);
    pn.poll.freeLoop(loop.?);
}

test "us_create_poll allocates poll handle and us_poll_ext returns non-null" {
    const loop = pn.poll.createLoop() orelse return error.LoopCreateFailed;
    defer pn.poll.freeLoop(loop);
    const p = pn.poll.createPoll(loop, 8);
    try testing.expect(p != null);
    const ext = pn.poll.pollExt(p.?);
    try testing.expect(@intFromPtr(ext) != 0);
    pn.poll.freePoll(p.?, loop);
}

test "us_loop_run_tick with zero timeout returns without blocking" {
    const loop = pn.poll.createLoop() orelse return error.LoopCreateFailed;
    defer pn.poll.freeLoop(loop);
    pn.poll.tick(loop, 0);
}

test "poll register + tick smoke: no crash with readable fd" {
    const loop = pn.poll.createLoop() orelse return error.LoopCreateFailed;
    defer pn.poll.freeLoop(loop);
    const port: u16 = try pn.findFreeTcpPort();
    const listen_fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(listen_fd);
    const p = pn.poll.createPoll(loop, 8) orelse return error.PollCreateFailed;
    pn.poll.initPoll(p, listen_fd, pn.POLL_TYPE_SOCKET);
    pn.poll.startPoll(p, loop, pn.LIBUS_SOCKET_READABLE);
    pn.poll.tick(loop, 0);
    pn.poll.stopPoll(p, loop);
    pn.poll.freePoll(p, loop);
}

// ---------------------------------------------------------------------------
// §11.6 — New accessor tests
// ---------------------------------------------------------------------------

test "addrFamily returns AF_INET for TCP listener" {
    const port: u16 = try pn.findFreeTcpPort();
    const fd: pn.Fd = try pn.createListenSocket("127.0.0.1", port, 0);
    defer pn.closeSocket(fd);
    var addr: pn.Addr = undefined;
    try pn.localAddr(fd, &addr);
    try testing.expectEqual(AF_INET, pn.addrFamily(&addr));
}

test "addrFamily returns AF_UNIX for UDS listener" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(testing.allocator);
    defer _ = pn.deleteUnixPath(@ptrCast(path.ptr));
    const fd: pn.Fd = try pn.createListenSocketUnix(path.ptr, path.len, 0);
    defer pn.closeSocket(fd);
    var addr: pn.Addr = undefined;
    try pn.localAddr(fd, &addr);
    try testing.expectEqual(AF_UNIX, pn.addrFamily(&addr));
}

test "addrUnixPath returns path matching what was passed to createListenSocketUnix" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(testing.allocator);
    defer _ = pn.deleteUnixPath(@ptrCast(path.ptr));
    const fd: pn.Fd = try pn.createListenSocketUnix(path.ptr, path.len, 0);
    defer pn.closeSocket(fd);
    var addr: pn.Addr = undefined;
    try pn.localAddr(fd, &addr);
    const got = pn.addrUnixPath(&addr);
    try testing.expectEqualStrings(path, got);
}

test "deleteUnixPath removes the socket file" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(testing.allocator);
    const fd: pn.Fd = try pn.createListenSocketUnix(path.ptr, path.len, 0);
    pn.closeSocket(fd);
    try std.fs.accessAbsolute(path, .{});
    _ = pn.deleteUnixPath(@ptrCast(path.ptr));
    const result = std.fs.accessAbsolute(path, .{});
    try testing.expectError(error.FileNotFound, result);
}

test "addrPort returns null for Unix socket addr" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(testing.allocator);
    defer _ = pn.deleteUnixPath(@ptrCast(path.ptr));
    const fd: pn.Fd = try pn.createListenSocketUnix(path.ptr, path.len, 0);
    defer pn.closeSocket(fd);
    var addr: pn.Addr = undefined;
    try pn.localAddr(fd, &addr);
    try testing.expect(pn.addrPort(&addr) == null);
}

test "platform deinit" {
    tofu.deinitPlatform();
}

// ---------------------------------------------------------------------------
// Imports (at bottom per RULES.md §0)
// ---------------------------------------------------------------------------

const pn = @import("posix_net");
const tofu = @import("tofu");
const std = @import("std");
const testing = std.testing;
