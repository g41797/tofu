// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

// Contract tests for the poller backend interface.
// Tests the backend directly via Poller.backend — no PollerCore reconciliation loop.
// Zero std.posix in test code. Single-threaded throughout.
// Runs unchanged on any backend (epoll/kqueue/wepoll/portable), all platforms.
// tofu.initPlatform/deinitPlatform handle platform environment setup (WSA on Windows, no-op elsewhere).

test {
    std.testing.log_level = .debug;
    std.log.debug("poller_tests\r\n", .{});
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const TIMEOUT_MS: i32 = 100;
const SLEEP_NS: u64 = 1 * std.time.ns_per_ms;
const MAX_RETRIES = 10_000;

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

// Create a connected TCP pair: returns listener (to deinit), accepted, client.
// Caller owns all three and must deinit them.
fn makeTCPPair(sc: *SocketCreator) !struct { listener: Skt, accepted: Skt, client: Skt } {
    var listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    errdefer listener.deinit();
    const port = listener.getPort().?;
    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    errdefer client.deinit();
    try connectWithRetry(&client);
    const accepted = try acceptWithRetry(&listener);
    return .{ .listener = listener, .accepted = accepted, .client = client };
}

// Minimal TriggeredChannel for backend tests.
// The backend only reads .exp and writes .act — all other fields are left undefined.
fn makeTC(exp: Triggers) *TriggeredChannel {
    const tc = gpa.create(TriggeredChannel) catch unreachable;
    tc.*.exp = exp;
    tc.*.act = Triggers{};
    return tc;
}

// ---------------------------------------------------------------------------
// Group 1 — Lifecycle
// ---------------------------------------------------------------------------

test "backend init and deinit" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var p = try Poller.init(gpa);
    p.deleteAll();
}

// ---------------------------------------------------------------------------
// Group 2 — Timeout
// ---------------------------------------------------------------------------

test "timeout when no data" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);
    const pair = try makeTCPPair(&sc);
    var listener = pair.listener;
    defer listener.deinit();
    var accepted = pair.accepted;
    defer accepted.deinit();
    var client = pair.client;
    defer client.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();
    const seq: SeqN = 1;
    const tc = makeTC(.{ .recv = .on });
    defer gpa.destroy(tc);

    try map.put(seq, tc);
    try p.backend.register(toFd(accepted.socketHandle().?), seq, tc.exp);
    defer p.backend.unregister(toFd(accepted.socketHandle().?));

    // No data written — expect timeout
    const result = try p.backend.wait(50, &map);
    try testing.expect(result.timeout == .on);
    try testing.expect(tc.act.recv != .on);
}

// ---------------------------------------------------------------------------
// Group 3 — Readable
// ---------------------------------------------------------------------------

test "readable after write" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);
    const pair = try makeTCPPair(&sc);
    var listener = pair.listener;
    defer listener.deinit();
    var accepted = pair.accepted;
    defer accepted.deinit();
    var client = pair.client;
    defer client.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();
    const seq: SeqN = 1;
    const tc = makeTC(.{ .recv = .on });
    defer gpa.destroy(tc);

    try map.put(seq, tc);
    try p.backend.register(toFd(accepted.socketHandle().?), seq, tc.exp);
    defer p.backend.unregister(toFd(accepted.socketHandle().?));

    // Write before wait — kernel buffers it
    _ = try client.sendBuf(&[_]u8{'x'});
    std.Thread.sleep(SLEEP_NS);

    const result = try p.backend.wait(TIMEOUT_MS, &map);
    try testing.expect(result.recv == .on);
    try testing.expect(tc.act.recv == .on);
}

// ---------------------------------------------------------------------------
// Group 4 — Writable
// ---------------------------------------------------------------------------

test "writable immediately" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);
    const pair = try makeTCPPair(&sc);
    var listener = pair.listener;
    defer listener.deinit();
    var accepted = pair.accepted;
    defer accepted.deinit();
    var client = pair.client;
    defer client.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();
    const seq: SeqN = 1;
    // Register client (sender side) for send — send buffer is empty, writable immediately
    const tc = makeTC(.{ .send = .on });
    defer gpa.destroy(tc);

    try map.put(seq, tc);
    try p.backend.register(toFd(client.socketHandle().?), seq, tc.exp);
    defer p.backend.unregister(toFd(client.socketHandle().?));

    const result = try p.backend.wait(0, &map);
    try testing.expect(result.send == .on);
    try testing.expect(tc.act.send == .on);
}

// ---------------------------------------------------------------------------
// Group 5 — Unregister
// ---------------------------------------------------------------------------

test "unregister prevents event" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);
    const pair = try makeTCPPair(&sc);
    var listener = pair.listener;
    defer listener.deinit();
    var accepted = pair.accepted;
    defer accepted.deinit();
    var client = pair.client;
    defer client.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();
    const seq: SeqN = 1;
    const tc = makeTC(.{ .recv = .on });
    defer gpa.destroy(tc);

    try map.put(seq, tc);
    try p.backend.register(toFd(accepted.socketHandle().?), seq, tc.exp);

    // Unregister before any write
    p.backend.unregister(toFd(accepted.socketHandle().?));

    _ = try client.sendBuf(&[_]u8{'x'});
    std.Thread.sleep(SLEEP_NS);

    const result = try p.backend.wait(50, &map);
    try testing.expect(result.timeout == .on);
    try testing.expect(tc.act.recv != .on);
}

// ---------------------------------------------------------------------------
// Group 6 — Modify
// ---------------------------------------------------------------------------

test "modify recv to send" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);
    const pair = try makeTCPPair(&sc);
    var listener = pair.listener;
    defer listener.deinit();
    var accepted = pair.accepted;
    defer accepted.deinit();
    var client = pair.client;
    defer client.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();
    const seq: SeqN = 1;
    var tc = makeTC(.{ .recv = .on });
    defer gpa.destroy(tc);

    try map.put(seq, tc);
    try p.backend.register(toFd(accepted.socketHandle().?), seq, tc.exp);
    defer p.backend.unregister(toFd(accepted.socketHandle().?));

    // Modify to send interest
    tc.exp = .{ .send = .on };
    try p.backend.modify(toFd(accepted.socketHandle().?), seq, tc.exp);

    const result = try p.backend.wait(0, &map);
    try testing.expect(result.send == .on);
    try testing.expect(tc.act.send == .on);
    try testing.expect(tc.act.recv != .on);
}

// ---------------------------------------------------------------------------
// Group 7 — Multiple FDs
// ---------------------------------------------------------------------------

test "two fds both readable" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);
    const pair1 = try makeTCPPair(&sc);
    var listener1 = pair1.listener;
    defer listener1.deinit();
    var accepted1 = pair1.accepted;
    defer accepted1.deinit();
    var client1 = pair1.client;
    defer client1.deinit();

    const pair2 = try makeTCPPair(&sc);
    var listener2 = pair2.listener;
    defer listener2.deinit();
    var accepted2 = pair2.accepted;
    defer accepted2.deinit();
    var client2 = pair2.client;
    defer client2.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();

    const tc1 = makeTC(.{ .recv = .on });
    defer gpa.destroy(tc1);

    const tc2 = makeTC(.{ .recv = .on });
    defer gpa.destroy(tc2);

    try map.put(1, tc1);
    try map.put(2, tc2);

    try p.backend.register(toFd(accepted1.socketHandle().?), 1, tc1.exp);
    try p.backend.register(toFd(accepted2.socketHandle().?), 2, tc2.exp);
    defer p.backend.unregister(toFd(accepted1.socketHandle().?));
    defer p.backend.unregister(toFd(accepted2.socketHandle().?));

    _ = try client1.sendBuf(&[_]u8{'a'});
    _ = try client2.sendBuf(&[_]u8{'b'});
    std.Thread.sleep(SLEEP_NS);

    const result = try p.backend.wait(TIMEOUT_MS, &map);
    try testing.expect(result.recv == .on);
    try testing.expect(tc1.act.recv == .on);
    try testing.expect(tc2.act.recv == .on);
}

// ---------------------------------------------------------------------------
// Group 8 — SeqN isolation (ABA protection)
// ---------------------------------------------------------------------------

test "seqN isolation" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);
    const pair = try makeTCPPair(&sc);
    var listener = pair.listener;
    defer listener.deinit();
    var accepted = pair.accepted;
    defer accepted.deinit();
    var client = pair.client;
    defer client.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();

    // seqN=1 registered with backend AND in map
    const tc1 = makeTC(.{ .recv = .on });
    try map.put(1, tc1);
    defer gpa.destroy(tc1);

    try p.backend.register(toFd(accepted.socketHandle().?), 1, tc1.exp);
    defer p.backend.unregister(toFd(accepted.socketHandle().?));

    // seqN=2 in map only — no FD registered in backend with this seqN
    const tc2 = makeTC(.{ .recv = .on });
    defer gpa.destroy(tc2);

    try map.put(2, tc2);

    _ = try client.sendBuf(&[_]u8{'x'});
    std.Thread.sleep(SLEEP_NS);

    _ = try p.backend.wait(TIMEOUT_MS, &map);

    // seqN=1 should fire because its FD is registered
    try testing.expect(tc1.act.recv == .on);
    // seqN=2 should not fire — no FD registered in backend with seqN=2
    try testing.expect(tc2.act.recv != .on);
}

// ---------------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------------

const tofu = @import("tofu");
const internal_mod = tofu.@"internal usage";
const Poller = internal_mod.Poller;
const poller_mod = internal_mod.poller;
const core = poller_mod.core;
const common = poller_mod.common;
const SeqnTrcMap = core.SeqnTrcMap;
const SeqN = common.SeqN;
const toFd = common.toFd;
const Triggers = internal_mod.triggeredSkts.Triggers;
const TriggeredChannel = tofu.Reactor.TriggeredChannel;
const Skt = tofu.Skt;
const SocketCreator = tofu.SocketCreator;
const TCPServerAddress = tofu.address.TCPServerAddress;
const TCPClientAddress = tofu.address.TCPClientAddress;

const std = @import("std");
const testing = std.testing;
const gpa = std.testing.allocator;
