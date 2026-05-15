// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

// PollerCore integration tests — all backends, all platforms.
// Converted from windows_poller_tests.zig by removing OS-specific guards.
// Tests the PollerCore level: attachChannel, waitTriggers, trgChannel.
// tofu.initPlatform/deinitPlatform handle platform environment setup (WSA on Windows, no-op elsewhere).
// Port 0 used for OS-assigned ports — no FindFreeTcpPort needed.

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const MAX_RETRIES: usize = 10_000;
const SLEEP_NS: u64 = 1 * std.time.ns_per_ms;

fn connectWithRetry(client: *Skt) !void {
    for (0..MAX_RETRIES) |_| {
        if (try client.connect()) return;
        std.Thread.sleep(SLEEP_NS);
    }
    return error.TimeoutConnect;
}

// ---------------------------------------------------------------------------
// Test 1 — Notifier wakeup
// ---------------------------------------------------------------------------

test "Notifier wakeup" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var ntfr: Notifier = try Notifier.init(testing.allocator);
    defer ntfr.deinit();

    var pl = try Poller.init(testing.allocator);
    defer pl.deleteAll();

    const ntfr_skt: NotificationSkt = NotificationSkt.init(&ntfr.receiver);
    const tc: *TriggeredChannel = try testing.allocator.create(TriggeredChannel);
    defer testing.allocator.destroy(tc);
    tc.* = TriggeredChannel{
        .tskt = .{ .notification = ntfr_skt },
        .acn = .{ .chn = tofu.message.SpecialMaxChannelNumber },
    };
    tc.tskt.refreshPointers();

    _ = try pl.attachChannel(tc);

    // Initial poll — must timeout
    const trgs1: Triggers = try pl.waitTriggers(100);
    if (trgs1.timeout == .off) {
        std.debug.print("\nUnexpected triggers in trgs1: {any}\n", .{triggered.UnpackedTriggers.fromTriggers(trgs1)});
    }
    try testing.expect(trgs1.timeout == .on);

    // Send notification
    const notif: Notifier.Notification = Notifier.Notification{ .kind = .message, .oob = .on };
    try ntfr.sendNotification(notif);

    // Poll — must trigger notify
    const trgs2: Triggers = try pl.waitTriggers(1000);
    if (trgs2.notify == .off) {
        std.debug.print("\nUnexpected triggers in trgs2: {any}\n", .{triggered.UnpackedTriggers.fromTriggers(trgs2)});
    }
    try testing.expect(trgs2.notify == .on);

    // Verify received notification
    const tc_ptr: *TriggeredChannel = pl.trgChannel(tofu.message.SpecialMaxChannelNumber).?;
    const rcvd: Notifier.Notification = try tc_ptr.*.tskt.tryRecvNotification();
    try testing.expectEqual(notif, rcvd);

    // Poll again — must timeout (drained)
    const trgs3: Triggers = try pl.waitTriggers(100);
    try testing.expect(trgs3.timeout == .on);
}


// ---------------------------------------------------------------------------
// Test 2 — Raw TCP connectivity (diagnostics)
// ---------------------------------------------------------------------------

test "Raw TCP connectivity" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var sc: SocketCreator = SocketCreator.init(testing.allocator);

    // 1. Setup listener
    var list_skt: Skt = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("", 0) });
    defer list_skt.deinit();
    const port: u16 = list_skt.getPort().?;


    // 2. Connect client
    var client_skt: Skt = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client_skt.deinit();

    // Since it's non-blocking, connect might return false (WouldBlock)
    const connected = try client_skt.connect();
    if (!connected) {
        try connectWithRetry(&client_skt);
    }

    // 3. Accept on server
    var server_skt: Skt = undefined;
    while (true) {
        if (try list_skt.accept()) |s| {
            server_skt = s;
            break;
        }
        std.Thread.sleep(SLEEP_NS);
    }
    defer server_skt.deinit();

    // 4. Send/Recv
    const test_data = "Hello diagnostic";
    _ = try client_skt.sendBuf(test_data);

    var buf: [100]u8 = undefined;
    var rcvd_len: usize = 0;
    while (rcvd_len < test_data.len) {
        if (try server_skt.recvToBuf(buf[rcvd_len..])) |n| {
            if (n == 0) return error.UnexpectedEOF;
            rcvd_len += n;
        } else {
            std.Thread.sleep(SLEEP_NS);
        }
    }

    try testing.expectEqualStrings(test_data, buf[0..rcvd_len]);
}


// ---------------------------------------------------------------------------
// Test 3 — TCP accept / recv / send readiness
// ---------------------------------------------------------------------------

test "TCP accept recv send via PollerCore" {

    var pool: Pool = try Pool.init(testing.allocator, 10, 1024, null);
    defer pool.close();

    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    var pl = try Poller.init(testing.allocator);
    defer pl.deleteAll();

    // 1. Setup listener
    var sc: SocketCreator = SocketCreator.init(testing.allocator);
    // 1. Setup listener
    var list_skt: Skt = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("", 0) });
    defer list_skt.deinit();
    const port: u16 = list_skt.getPort().?;

    const tc_list: *TriggeredChannel = try testing.allocator.create(TriggeredChannel);
    errdefer tc_list.tskt.deinit();
    defer testing.allocator.destroy(tc_list);

    tc_list.* = TriggeredChannel{
        .tskt = .{ .accept = .{ .skt = list_skt } },
        .acn = .{ .chn = 1 },
    };
    tc_list.tskt.refreshPointers();
    _ = try pl.attachChannel(tc_list);

    var chnls = try std.ArrayList(tofu.message.ChannelNumber).initCapacity(testing.allocator, 1);
    try chnls.append(testing.allocator, 1);
    defer {
        _ = pl.deleteGroup(chnls) catch {};
        chnls.deinit(testing.allocator);
    }

    // 2. Connect client
    var client_skt: Skt = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", port) });
    defer client_skt.deinit();
    try connectWithRetry(&client_skt);

    // 3. Poll for ACCEPT
    const trgs1: Triggers = try pl.waitTriggers(5000);
    try testing.expect(trgs1.accept == .on);

    // 4. Accept connection
    const tc_list_ptr: *TriggeredChannel = pl.trgChannel(1).?;
    var server_skt: Skt = (try tc_list_ptr.*.tskt.tryAccept()).?;
    errdefer server_skt.deinit();

    // 5. Setup IO channel
    const srv_io: IoSkt = try IoSkt.initServerSide(&pool, 2, server_skt);
    const tc_srv: *TriggeredChannel = try testing.allocator.create(TriggeredChannel);
    defer {
        tc_srv.tskt.deinit();
        testing.allocator.destroy(tc_srv);
    }
    tc_srv.* = TriggeredChannel{
        .tskt = .{ .io = srv_io },
        .acn = .{ .chn = 2 },
    };
    tc_srv.tskt.refreshPointers();
    _ = try pl.attachChannel(tc_srv);

    // 6. Send a formatted message from the client
    {
        const msg: *tofu.message.Message = try tofu.message.Message.create(testing.allocator);
        defer msg.*.destroy();
        try msg.*.body.append("Hello");

        var bh_bytes: [tofu.message.BinaryHeader.BHSIZE]u8 = undefined;
        msg.*.bhdr.@"<bl>" = @intCast(msg.*.actual_body_len());
        msg.*.bhdr.toBytes(&bh_bytes);

        const bh_sent = try client_skt.sendBuf(&bh_bytes);
        try testing.expect(bh_sent != null);
        try testing.expectEqual(@as(usize, bh_bytes.len), bh_sent.?);

        const body_sent = try client_skt.sendBuf(msg.*.body.body().?);
        try testing.expect(body_sent != null);
        try testing.expectEqual(@as(usize, msg.*.actual_body_len()), body_sent.?);
    }

    // 7. Poll for RECV
    const trgs2: Triggers = try pl.waitTriggers(5000);
    if (trgs2.recv == .off) {
        std.debug.print("\nUnexpected triggers in TCP recv poll: {any}\n", .{triggered.UnpackedTriggers.fromTriggers(trgs2)});
    }
    try testing.expect(trgs2.recv == .on);

    // 8. Receive on server side
    const tc_srv_ptr: *TriggeredChannel = pl.trgChannel(2).?;
    var mq: tofu.message.MessageQueue = try tc_srv_ptr.*.tskt.tryRecv();
    defer tofu.message.clearQueue(&mq);
    if (mq.count() == 0) {
        std.debug.print("\nMessage queue is empty after RECV trigger. Triggers: {any}\n", .{triggered.UnpackedTriggers.fromTriggers(trgs2)});
    }
    try testing.expect(mq.count() > 0);
    try testing.expectEqualStrings("Hello", mq.first.?.*.body.body().?);

    // 9. Queue a message on the server side to register SEND interest
    {
        const msg_out: *tofu.message.Message = try tofu.message.Message.create(testing.allocator);
        msg_out.*.bhdr.channel_number = 2;
        try tc_srv_ptr.*.tskt.addToSend(msg_out);
    }

    // 10. Poll for SEND readiness
    const trgs3: Triggers = try pl.waitTriggers(5000);
    try testing.expect(trgs3.send == .on);
}

// ---------------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

const tofu = @import("tofu");
const internal_mod = tofu.@"internal usage";
const Poller = internal_mod.Poller;
const Pool = internal_mod.Pool;
const Notifier = internal_mod.Notifier;
const Skt = internal_mod.Skt;
const SocketCreator = internal_mod.SocketCreator;
const triggered = internal_mod.triggeredSkts;
const Triggers = triggered.Triggers;
const NotificationSkt = triggered.NotificationSkt;
const IoSkt = triggered.IoSkt;
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;
const TCPServerAddress = tofu.address.TCPServerAddress;
const TCPClientAddress = tofu.address.TCPClientAddress;
