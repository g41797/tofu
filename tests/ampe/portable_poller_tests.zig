// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

// Lower-level contract tests for the PosixNetBackend (uSockets).
// These tests bypass PollerCore and talk directly to the backend.
// Designed to verify registration robustness and event dispatch.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const gpa = std.testing.allocator;

const tofu = @import("tofu");
const status = tofu.status;
const AmpeError = status.AmpeError;
const AmpeStatus = status.AmpeStatus;
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;
const Skt = tofu.Skt;
const SocketCreator = tofu.SocketCreator;
const TCPServerAddress = tofu.address.TCPServerAddress;
const TCPClientAddress = tofu.address.TCPClientAddress;
const UDSServerAddress = tofu.address.UDSServerAddress;
const UDSClientAddress = tofu.address.UDSClientAddress;
const TempUdsPath = tofu.TempUdsPath;

const internal_mod = tofu.@"internal usage";
const Poller = internal_mod.Poller;
const poller_mod = internal_mod.poller;
const core = poller_mod.core;
const common = poller_mod.common;
const SeqnTrcMap = core.SeqnTrcMap;
const SeqN = common.SeqN;
const toFd = common.toFd;
const Triggers = internal_mod.triggeredSkts.Triggers;
const Pool = internal_mod.Pool;
const Notifier = internal_mod.Notifier;
const SpecialMaxChannelNumber = tofu.message.SpecialMaxChannelNumber;

const pn = @import("posix_net");

test "portable backend: robust registration" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var p = try Poller.init(gpa);
    defer p.deleteAll(); // Calls backend.deinit which frees loop

    var sc = SocketCreator.init(gpa);
    var listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer listener.deinit();
    const fd = toFd(@intCast(listener.rawFd()));

    const seq: SeqN = 100;
    const exp = Triggers{ .accept = .on };

    // 1. Initial register
    try p.backend.register(fd, seq, exp);

    // 2. Register again (should be handled as modify internally)
    try p.backend.register(fd, seq, exp);

    // 3. Modify (should be fine)
    try p.backend.modify(fd, seq, exp);

    // 4. Modify something not registered (should be handled as register internally)
    var listener2 = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer listener2.deinit();
    const fd2 = toFd(@intCast(listener2.rawFd()));
    try p.backend.modify(fd2, seq + 1, exp);

    // 5. Unregister
    p.backend.unregister(fd);
    p.backend.unregister(fd2);
}

test "portable backend: wait with data" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);

    // Create a TCP pair
    var listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer listener.deinit();
    const port = listener.getPort().?;

    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client.deinit();

    // Client connect typically EINPROGRESS on TCP, but uSockets handles it.
    _ = try client.connect();

    var accepted: Skt = undefined;
    while (true) {
        if (try listener.accept()) |s| {
            accepted = s;
            break;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    defer accepted.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();

    // Heap-allocate TriggeredChannel to ensure stable pointer
    const tc_ptr = try gpa.create(TriggeredChannel);
    defer gpa.destroy(tc_ptr);
    tc_ptr.* = TriggeredChannel{
        .engine = undefined,
        .acn = undefined,
        .tskt = undefined,
        .exp = .{ .recv = .on },
        .act = .{},
        .mrk4del = false,
        .resp2ac = false,
        .st = null,
        .firstRecvFinished = false,
    };
    const seq: SeqN = 1;
    try map.put(seq, tc_ptr);

    const accepted_fd = toFd(@intCast(accepted.rawFd()));
    try p.backend.register(accepted_fd, seq, tc_ptr.exp);

    // Write data from client
    _ = try client.sendBuf("ping");

    // Wait for event
    const total_act = try p.backend.wait(100, &map);

    try testing.expect(total_act.recv == .on);
    try testing.expect(tc_ptr.act.recv == .on);
}

test "portable backend: timeout" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();

    const total_act = try p.backend.wait(10, &map);
    try testing.expect(total_act.timeout == .on);
}

test "portable backend: accept flow" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);

    var listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer listener.deinit();
    const port = listener.getPort().?;

    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();

    // Heap-allocate TriggeredChannel to ensure stable pointer
    const listener_tc_ptr = try gpa.create(TriggeredChannel);
    defer gpa.destroy(listener_tc_ptr);
    listener_tc_ptr.* = TriggeredChannel{
        .engine = undefined,
        .acn = undefined,
        .tskt = undefined,
        .exp = .{ .accept = .on },
        .act = .{},
        .mrk4del = false,
        .resp2ac = false,
        .st = null,
        .firstRecvFinished = false,
    };
    const seq: SeqN = 1;
    try map.put(seq, listener_tc_ptr);

    // Initiate non-blocking connect; listener fires accept shortly after.
    _ = try client.connect();

    const listener_fd = toFd(@intCast(listener.rawFd()));
    try p.backend.register(listener_fd, seq, listener_tc_ptr.exp);

    const total_act = try p.backend.wait(200, &map);

    try testing.expect(total_act.accept == .on);
    try testing.expect(listener_tc_ptr.act.accept == .on);

    // Accept must succeed
    const accepted = try listener.accept();
    try testing.expect(accepted != null);
    var conn = accepted.?;
    defer conn.deinit();
}

test "portable backend: full echo" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var sc = SocketCreator.init(gpa);

    var listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer listener.deinit();
    const port = listener.getPort().?;

    var client = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client.deinit();

    _ = try client.connect();

    // Spin until accept succeeds
    var accepted: Skt = undefined;
    for (0..200) |_| {
        if (try listener.accept()) |s| {
            accepted = s;
            break;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    defer accepted.deinit();
    try testing.expect(accepted.isSet());

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();

    // Heap-allocate TriggeredChannel to ensure stable pointer
    const server_tc_ptr = try gpa.create(TriggeredChannel);
    const client_tc_ptr = try gpa.create(TriggeredChannel);
    defer gpa.destroy(server_tc_ptr);
    defer gpa.destroy(client_tc_ptr);

    server_tc_ptr.* = TriggeredChannel{
        .engine = undefined,
        .acn = undefined,
        .tskt = undefined,
        .exp = .{ .recv = .on },
        .act = .{},
        .mrk4del = false,
        .resp2ac = false,
        .st = null,
        .firstRecvFinished = false,
    };
    client_tc_ptr.* = TriggeredChannel{
        .engine = undefined,
        .acn = undefined,
        .tskt = undefined,
        .exp = .{ .recv = .on },
        .act = .{},
        .mrk4del = false,
        .resp2ac = false,
        .st = null,
        .firstRecvFinished = false,
    };

    const server_seq: SeqN = 1;
    const client_seq: SeqN = 2;
    try map.put(server_seq, server_tc_ptr);
    try map.put(client_seq, client_tc_ptr);

    const accepted_fd = toFd(@intCast(accepted.rawFd()));
    const client_fd = toFd(@intCast(client.rawFd()));
    try p.backend.register(accepted_fd, server_seq, server_tc_ptr.exp);
    try p.backend.register(client_fd, client_seq, client_tc_ptr.exp);

    // Client sends ping
    _ = try client.sendBuf("ping");

    // Wait until server recv fires
    var got_server_recv = false;
    for (0..50) |_| {
        server_tc_ptr.act = .{};
        client_tc_ptr.act = .{};
        _ = try p.backend.wait(50, &map);
        if (server_tc_ptr.act.recv == .on) {
            got_server_recv = true;
            break;
        }
    }
    try testing.expect(got_server_recv);

    // Read ping at server
    var buf: [64]u8 = undefined;
    const n = (try accepted.recvToBuf(&buf)) orelse 0;
    try testing.expectEqualSlices(u8, "ping", buf[0..n]);

    // Server sends pong
    _ = try accepted.sendBuf("pong");

    // Wait until client recv fires
    var got_client_recv = false;
    for (0..50) |_| {
        server_tc_ptr.act = .{};
        client_tc_ptr.act = .{};
        _ = try p.backend.wait(50, &map);
        if (client_tc_ptr.act.recv == .on) {
            got_client_recv = true;
            break;
        }
    }
    try testing.expect(got_client_recv);

    // Read pong at client
    const m = (try client.recvToBuf(&buf)) orelse 0;
    try testing.expectEqualSlices(u8, "pong", buf[0..m]);
}

test "portable backend: UDS echo" {
    if (builtin.os.tag == .windows) return;

    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var p = try Poller.init(gpa);
    defer p.deleteAll();

    var tup = TempUdsPath{};
    const uds_path = try tup.buildPath(gpa);

    var sc = SocketCreator.init(gpa);

    var listener = try sc.fromAddress(.{ .uds_server_addr = UDSServerAddress.init(uds_path) });
    defer listener.deinit();

    // UDS client uses delayed connect via Skt.connect()
    var client = try sc.fromAddress(.{ .uds_client_addr = UDSClientAddress.init(uds_path) });
    defer client.deinit();
    _ = try client.connect();

    // Spin until accept succeeds
    var accepted: Skt = undefined;
    for (0..200) |_| {
        if (try listener.accept()) |s| {
            accepted = s;
            break;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    defer accepted.deinit();
    try testing.expect(accepted.isSet());

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();

    // Heap-allocate TriggeredChannel to ensure stable pointer
    const server_tc_ptr = try gpa.create(TriggeredChannel);
    const client_tc_ptr = try gpa.create(TriggeredChannel);
    defer gpa.destroy(server_tc_ptr);
    defer gpa.destroy(client_tc_ptr);

    server_tc_ptr.* = TriggeredChannel{
        .engine = undefined,
        .acn = undefined,
        .tskt = undefined,
        .exp = .{ .recv = .on },
        .act = .{},
        .mrk4del = false,
        .resp2ac = false,
        .st = null,
        .firstRecvFinished = false,
    };
    client_tc_ptr.* = TriggeredChannel{
        .engine = undefined,
        .acn = undefined,
        .tskt = undefined,
        .exp = .{ .recv = .on },
        .act = .{},
        .mrk4del = false,
        .resp2ac = false,
        .st = null,
        .firstRecvFinished = false,
    };

    const server_seq: SeqN = 1;
    const client_seq: SeqN = 2;
    try map.put(server_seq, server_tc_ptr);
    try map.put(client_seq, client_tc_ptr);

    const accepted_fd = toFd(@intCast(accepted.rawFd()));
    const client_fd = toFd(@intCast(client.rawFd()));
    try p.backend.register(accepted_fd, server_seq, server_tc_ptr.exp);
    try p.backend.register(client_fd, client_seq, client_tc_ptr.exp);

    _ = try client.sendBuf("ping");

    var got_server_recv = false;
    for (0..50) |_| {
        server_tc_ptr.act = .{};
        client_tc_ptr.act = .{};
        _ = try p.backend.wait(50, &map);
        if (server_tc_ptr.act.recv == .on) {
            got_server_recv = true;
            break;
        }
    }
    try testing.expect(got_server_recv);

    var buf: [64]u8 = undefined;
    const n = (try accepted.recvToBuf(&buf)) orelse 0;
    try testing.expectEqualSlices(u8, "ping", buf[0..n]);

    _ = try accepted.sendBuf("pong");

    var got_client_recv = false;
    for (0..50) |_| {
        server_tc_ptr.act = .{};
        client_tc_ptr.act = .{};
        _ = try p.backend.wait(50, &map);
        if (client_tc_ptr.act.recv == .on) {
            got_client_recv = true;
            break;
        }
    }
    try testing.expect(got_client_recv);

    const m = (try client.recvToBuf(&buf)) orelse 0;
    try testing.expectEqualSlices(u8, "pong", buf[0..m]);
}

// assertNotifierFires sends one notification and verifies the Notifier TC receives it.
// Drains the notification byte afterward so it does not accumulate.
fn assertNotifierFires(
    p: *Poller,
    map: *SeqnTrcMap,
    ntfr: *Notifier,
    ntfr_tc: *TriggeredChannel,
) !void {
    const notif: Notifier.Notification = .{ .kind = .message, .oob = .off, .alert = .freedMemory };
    try ntfr.sendNotification(notif);

    var fired = false;
    for (0..20) |_| {
        ntfr_tc.act = .{};
        _ = try p.backend.wait(50, map);
        if (ntfr_tc.act.notify == .on) {
            fired = true;
            break;
        }
    }
    if (!fired) {
        std.debug.print("\nNotifier failed to fire. ntfr_tc.act.notify: {any}\n", .{ntfr_tc.act.notify});
    }
    try testing.expect(fired);
    _ = try ntfr.recvNotification();
}

test "portable backend: map stability with notifier" {
    var pool: Pool = try Pool.init(testing.allocator, 10, 1024, null);
    defer pool.close();

    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var p = try Poller.init(gpa);
    defer p.deleteAll();

    // Notifier uses TCP (Notifier.init temporarily hardcoded to initTCP).
    var ntfr = try Notifier.init(gpa);
    defer ntfr.deinit();

    var map = SeqnTrcMap.init(gpa);
    defer map.deinit();

    // Notifier TC registered first — mirrors reactor's createNotificationChannel order.
    const ntfr_seq: SeqN = SpecialMaxChannelNumber;
    // Heap-allocate TriggeredChannel to ensure stable pointer
    const ntfr_tc_ptr = try gpa.create(TriggeredChannel);
    defer gpa.destroy(ntfr_tc_ptr);

    ntfr_tc_ptr.* = TriggeredChannel{
        .engine = undefined,
        .acn = undefined,
        .tskt = undefined,
        .exp = .{ .notify = .on },
        .act = .{},
        .mrk4del = false,
        .resp2ac = false,
        .st = null,
        .firstRecvFinished = false,
    };
    try map.put(ntfr_seq, ntfr_tc_ptr);
    const ntfr_fd = toFd(@intCast(ntfr.receiver.rawFd()));
    try p.backend.register(ntfr_fd, ntfr_seq, ntfr_tc_ptr.exp);

    // 3 TCP listeners.
    var sc = SocketCreator.init(gpa);
    var l1 = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer l1.deinit();
    var l2 = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer l2.deinit();
    var l3 = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer l3.deinit();

    const exp_accept = Triggers{ .accept = .on };
    // Heap-allocate TriggeredChannel instances for listeners
    const tc1_ptr = try gpa.create(TriggeredChannel);
    const tc2_ptr = try gpa.create(TriggeredChannel);
    const tc3_ptr = try gpa.create(TriggeredChannel);
    defer gpa.destroy(tc1_ptr);
    defer gpa.destroy(tc2_ptr);
    defer gpa.destroy(tc3_ptr);

    tc1_ptr.* = TriggeredChannel{ .engine = undefined, .acn = undefined, .tskt = undefined,
        .exp = exp_accept, .act = .{}, .mrk4del = false, .resp2ac = false, .st = null, .firstRecvFinished = false };
    tc2_ptr.* = TriggeredChannel{ .engine = undefined, .acn = undefined, .tskt = undefined,
        .exp = exp_accept, .act = .{}, .mrk4del = false, .resp2ac = false, .st = null, .firstRecvFinished = false };
    tc3_ptr.* = TriggeredChannel{ .engine = undefined, .acn = undefined, .tskt = undefined,
        .exp = exp_accept, .act = .{}, .mrk4del = false, .resp2ac = false, .st = null, .firstRecvFinished = false };

    const seq1: SeqN = 1;
    const seq2: SeqN = 2;
    const seq3: SeqN = 3;
    try map.put(seq1, tc1_ptr);
    try map.put(seq2, tc2_ptr);
    try map.put(seq3, tc3_ptr);
    try p.backend.register(toFd(@intCast(l1.rawFd())), seq1, exp_accept);
    try p.backend.register(toFd(@intCast(l2.rawFd())), seq2, exp_accept);
    try p.backend.register(toFd(@intCast(l3.rawFd())), seq3, exp_accept);

    // Baseline: Notifier fires before any structural change.
    try assertNotifierFires(&p, &map, &ntfr, ntfr_tc_ptr);

    // Connect to l2 — triggers accept on TC2.
    const port2 = l2.getPort().?;
    var c2 = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port2) });
    defer c2.deinit();
    _ = try c2.connect();

    var got2 = false;
    for (0..100) |_| {
        tc2_ptr.act = .{};
        _ = try p.backend.wait(50, &map);
        if (tc2_ptr.act.accept == .on) { got2 = true; break; }
    }
    try testing.expect(got2);

    // After accept event: Notifier must still fire.
    try assertNotifierFires(&p, &map, &ntfr, ntfr_tc_ptr);

    // Remove l1 (seq1): swapRemove shifts l3 (last entry) into l1's slot.
    p.backend.unregister(toFd(@intCast(l1.rawFd())));
    _ = map.swapRemove(seq1);

    // After swapRemove: Notifier must still fire.
    try assertNotifierFires(&p, &map, &ntfr, ntfr_tc_ptr);

    // Connect to l3 — TC3 must still dispatch correctly after its position shifted.
    const port3 = l3.getPort().?;
    var c3 = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port3) });
    defer c3.deinit();
    _ = try c3.connect();
    std.Thread.sleep(10 * std.time.ns_per_ms);

    var got3 = false;
    for (0..100) |_| {
        tc3_ptr.act = .{};
        _ = try p.backend.wait(50, &map);
        if (tc3_ptr.act.accept == .on) { got3 = true; break; }
    }
    try testing.expect(got3);

    // Final: Notifier still fires after l3 accepted.
    try assertNotifierFires(&p, &map, &ntfr, ntfr_tc_ptr);
}
