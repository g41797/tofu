// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

// Contract tests for linux/Skt.zig and linux/SocketCreator.zig.
// Zero std.posix in test code — these tests must pass unchanged after posix removal.

test {
    std.testing.log_level = .debug;
    std.log.debug("sockets_tests\r\n", .{});
}

// ---------------------------------------------------------------------------
// Retry helpers — non-blocking sockets need spin loops in tests
// ---------------------------------------------------------------------------

const MAX_RETRIES = 10_000;
const SLEEP_NS = 1 * std.time.ns_per_ms;

fn acceptWithRetry(server: *Skt) !Skt {
    for (0..MAX_RETRIES) |_| {
        if (try server.accept()) |accepted| return accepted;
        std.Thread.sleep(SLEEP_NS);
    }
    return error.TimeoutAccept;
}

fn connectWithRetry(client: *Skt) !void {
    for (0..MAX_RETRIES) |_| {
        if (try client.connect()) return;
        std.Thread.sleep(SLEEP_NS);
    }
    return error.TimeoutConnect;
}

fn sendAll(skt: *Skt, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        if (try skt.sendBuf(data[sent..])) |n| sent += n else std.Thread.sleep(SLEEP_NS);
    }
}

fn recvAll(skt: *Skt, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        if (try skt.recvToBuf(buf[got..])) |n| got += n else std.Thread.sleep(SLEEP_NS);
    }
}

// ---------------------------------------------------------------------------
// Group 1 — SocketCreator (no connection, single thread)
// ---------------------------------------------------------------------------

test "SocketCreator wrong address returns InvalidAddress" {
    var sc = SocketCreator.init(gpa);
    try testing.expectError(AmpeError.InvalidAddress, sc.fromAddress(.{ .wrong = .{} }));
}

test "SocketCreator parse empty message returns InvalidAddress" {
    var msg = try Message.create(gpa);
    defer msg.destroy();
    var sc = SocketCreator.init(gpa);
    try testing.expectError(AmpeError.InvalidAddress, sc.parse(msg));
}

test "SocketCreator TCP server socket is set and server-flagged" {
    const port = try tofu.FindFreeTcpPort();
    var sc = SocketCreator.init(gpa);
    var skt = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", port) });
    defer skt.deinit();
    try testing.expect(skt.isSet());
    try testing.expect(skt.server == true);
}

test "SocketCreator UDS server socket is set and server-flagged" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(gpa);
    var sc = SocketCreator.init(gpa);
    var skt = try sc.fromAddress(.{ .uds_server_addr = UDSServerAddress.init(path) });
    defer skt.deinit();
    try testing.expect(skt.isSet());
    try testing.expect(skt.server == true);
}

test "SocketCreator TCP client socket is created" {
    const port = try tofu.FindFreeTcpPort();
    var sc = SocketCreator.init(gpa);
    var server = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", port) });
    defer server.deinit();
    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client.deinit();
    try testing.expect(client.isSet());
    try testing.expect(client.server == false);
}

test "SocketCreator UDS client connect to nonexistent path fails" {
    var sc = SocketCreator.init(gpa);
    // fromAddress only creates the socket — connect() is where the path is resolved
    var skt = try sc.fromAddress(.{ .uds_client_addr = UDSClientAddress.init("/tmp/tofu_no_such_socket_xyz.sock") });
    defer skt.deinit();
    try testing.expect(skt.isSet());
    // connect must fail since the path does not exist
    try testing.expectError(AmpeError.UDSPathNotFound, skt.connect());
}

test "SocketCreator findFreeTcpPort returns bindable port" {
    const port = try tofu.FindFreeTcpPort();
    try testing.expect(port > 0);
    var sc = SocketCreator.init(gpa);
    var skt = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", port) });
    defer skt.deinit();
    try testing.expect(skt.isSet());
}

test "SocketCreator createUdsListener with empty path auto-creates" {
    var skt = try SocketCreator.createUdsListener(gpa, "");
    defer skt.deinit();
    try testing.expect(skt.isSet());
    try testing.expect(skt.server == true);
}

// ---------------------------------------------------------------------------
// Group 2 — Skt state (single thread)
// ---------------------------------------------------------------------------

test "Skt zero-initialized deinit is safe" {
    var skt: Skt = .{};
    skt.deinit();
}

test "Skt accept on listener before client returns null" {
    const port = try tofu.FindFreeTcpPort();
    var sc = SocketCreator.init(gpa);
    var listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", port) });
    defer listener.deinit();
    const result = try listener.accept();
    try testing.expect(result == null);
}

test "Skt connect does not error (non-blocking pending or immediate)" {
    const port = try tofu.FindFreeTcpPort();
    var sc = SocketCreator.init(gpa);
    var server = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", port) });
    defer server.deinit();
    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client.deinit();
    _ = try client.connect();
}

// ---------------------------------------------------------------------------
// Group 3 — TCP integration (two threads)
//
// The listener is created in the main thread before spawning the server thread.
// This guarantees the server is listening before the client attempts to connect,
// eliminating the ECONNREFUSED race that occurs when the server thread races to
// bind its own socket.
//
// For tcpServerImmediateRecv the accepted conn is stored in ctx.conn and closed
// by the main thread AFTER connectWithRetry returns. This prevents the server's
// RST (SO_LINGER=0) from interrupting the client's second connect() call.
// ---------------------------------------------------------------------------

const TcpCtx = struct {
    listener: Skt = .{},
    conn: Skt = .{},
    received: [1000]u8 = undefined,
    recv_len: usize = 0,
    accepted_set: bool = false,
    err: ?anyerror = null,
};

fn tcpServerRecv(ctx: *TcpCtx) void {
    var conn = acceptWithRetry(&ctx.listener) catch |e| {
        ctx.err = e;
        return;
    };
    defer conn.deinit();
    recvAll(&conn, ctx.received[0..]) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.recv_len = ctx.received.len;
}

fn tcpServerImmediateRecv(ctx: *TcpCtx) void {
    ctx.conn = acceptWithRetry(&ctx.listener) catch |e| {
        ctx.err = e;
        return;
    };
    // Immediately recv before client sends — must return null (WouldBlock).
    // conn is NOT closed here; main thread closes it after connectWithRetry
    // returns to prevent RST from racing with the client's connect() retries.
    const result = ctx.conn.recvToBuf(ctx.received[0..]) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.recv_len = if (result == null) 0 else result.?;
    ctx.accepted_set = true;
}

test "TCP connect and accept" {
    const port = try tofu.FindFreeTcpPort();
    var sc = SocketCreator.init(gpa);
    var listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", port) });
    defer listener.deinit();
    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client.deinit();
    var accepted: ?Skt = null;
    defer if (accepted) |*a| a.deinit();
    var client_connected = false;
    for (0..MAX_RETRIES) |_| {
        if (!client_connected) client_connected = try client.connect();
        if (accepted == null) accepted = try listener.accept();
        if (client_connected and accepted != null) break;
        std.Thread.sleep(SLEEP_NS);
    }
    try testing.expect(client_connected);
    try testing.expect(accepted != null);
    try testing.expect(accepted.?.isSet());
    try testing.expect(client.isSet());
}

test "TCP sendBuf recvToBuf round-trip" {
    const port = try tofu.FindFreeTcpPort();
    var sc = SocketCreator.init(gpa);
    var ctx: TcpCtx = .{};
    ctx.listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", port) });
    defer ctx.listener.deinit();
    const t = try std.Thread.spawn(.{}, tcpServerRecv, .{&ctx});
    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client.deinit();
    try connectWithRetry(&client);
    var payload: [1000]u8 = undefined;
    @memset(&payload, 0xAB);
    try sendAll(&client, &payload);
    t.join();
    try testing.expect(ctx.err == null);
    try testing.expectEqual(@as(usize, 1000), ctx.recv_len);
    try testing.expectEqualSlices(u8, &payload, &ctx.received);
}

test "TCP recvToBuf returns null when no data" {
    const port = try tofu.FindFreeTcpPort();
    var sc = SocketCreator.init(gpa);
    var ctx: TcpCtx = .{};
    ctx.listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", port) });
    defer ctx.listener.deinit();
    defer ctx.conn.deinit();
    const t = try std.Thread.spawn(.{}, tcpServerImmediateRecv, .{&ctx});
    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client.deinit();
    try connectWithRetry(&client);
    // Wait for server to complete its recv before we allow it to deinit (via ctx.conn.deinit below).
    for (0..MAX_RETRIES) |_| {
        if (ctx.accepted_set or ctx.err != null) break;
        std.Thread.sleep(SLEEP_NS);
    }
    t.join();
    try testing.expect(ctx.err == null);
    try testing.expectEqual(@as(usize, 0), ctx.recv_len);
}

// ---------------------------------------------------------------------------
// Group 4 — UDS integration (two threads)
// ---------------------------------------------------------------------------

const UdsCtx = struct {
    path: [108:0]u8 = [_:0]u8{0} ** 108,
    path_len: usize = 0,
    received: [1000]u8 = undefined,
    recv_len: usize = 0,
    accepted_set: bool = false,
    err: ?anyerror = null,

    fn pathSlice(ctx: *const UdsCtx) []const u8 {
        return ctx.path[0..ctx.path_len];
    }
};

fn udsServerAcceptOnly(ctx: *UdsCtx) void {
    var sc = SocketCreator.init(gpa);
    var listener = sc.fromAddress(.{ .uds_server_addr = UDSServerAddress.init(ctx.pathSlice()) }) catch |e| {
        ctx.err = e;
        return;
    };
    defer listener.deinit();
    var conn = acceptWithRetry(&listener) catch |e| {
        ctx.err = e;
        return;
    };
    defer conn.deinit();
    ctx.accepted_set = conn.isSet();
}

fn udsServerRecv(ctx: *UdsCtx) void {
    var sc = SocketCreator.init(gpa);
    var listener = sc.fromAddress(.{ .uds_server_addr = UDSServerAddress.init(ctx.pathSlice()) }) catch |e| {
        ctx.err = e;
        return;
    };
    defer listener.deinit();
    var conn = acceptWithRetry(&listener) catch |e| {
        ctx.err = e;
        return;
    };
    defer conn.deinit();
    recvAll(&conn, ctx.received[0..]) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.recv_len = ctx.received.len;
}

fn udsServerDeinit(ctx: *UdsCtx) void {
    var sc = SocketCreator.init(gpa);
    var listener = sc.fromAddress(.{ .uds_server_addr = UDSServerAddress.init(ctx.pathSlice()) }) catch |e| {
        ctx.err = e;
        return;
    };
    listener.deinit();
    ctx.accepted_set = true;
}

test "UDS connect and accept" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(gpa);
    var ctx: UdsCtx = .{};
    ctx.path_len = path.len;
    @memcpy(ctx.path[0..path.len], path);
    const t = try std.Thread.spawn(.{}, udsServerAcceptOnly, .{&ctx});
    std.Thread.sleep(5 * std.time.ns_per_ms);
    var sc = SocketCreator.init(gpa);
    var client = try sc.fromAddress(.{ .uds_client_addr = UDSClientAddress.init(ctx.pathSlice()) });
    defer client.deinit();
    _ = try client.connect();
    t.join();
    try testing.expect(ctx.err == null);
    try testing.expect(ctx.accepted_set);
}

test "UDS sendBuf recvToBuf round-trip" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(gpa);
    var ctx: UdsCtx = .{};
    ctx.path_len = path.len;
    @memcpy(ctx.path[0..path.len], path);
    const t = try std.Thread.spawn(.{}, udsServerRecv, .{&ctx});
    std.Thread.sleep(5 * std.time.ns_per_ms);
    var sc = SocketCreator.init(gpa);
    var client = try sc.fromAddress(.{ .uds_client_addr = UDSClientAddress.init(ctx.pathSlice()) });
    defer client.deinit();
    _ = try client.connect();
    var payload: [1000]u8 = undefined;
    @memset(&payload, 0xCD);
    try sendAll(&client, &payload);
    t.join();
    try testing.expect(ctx.err == null);
    try testing.expectEqual(@as(usize, 1000), ctx.recv_len);
    try testing.expectEqualSlices(u8, &payload, &ctx.received);
}

test "UDS server socket file removed after deinit" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(gpa);
    var ctx: UdsCtx = .{};
    ctx.path_len = path.len;
    @memcpy(ctx.path[0..path.len], path);
    const t = try std.Thread.spawn(.{}, udsServerDeinit, .{&ctx});
    t.join();
    try testing.expect(ctx.err == null);
    std.fs.accessAbsolute(ctx.pathSlice(), .{}) catch |e| {
        try testing.expect(e == error.FileNotFound);
        return;
    };
    try testing.expect(false); // file still exists
}

// ---------------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------------

const tofu = @import("tofu");
const Skt = tofu.Skt;
const SocketCreator = tofu.SocketCreator;
const TCPServerAddress = tofu.address.TCPServerAddress;
const TCPClientAddress = tofu.address.TCPClientAddress;
const UDSServerAddress = tofu.address.UDSServerAddress;
const UDSClientAddress = tofu.address.UDSClientAddress;
const AmpeError = tofu.AmpeError;
const Message = tofu.Message;

const std = @import("std");
const testing = std.testing;
const gpa = std.testing.allocator;
