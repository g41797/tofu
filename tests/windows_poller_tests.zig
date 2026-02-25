// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

test "Windows Poller: Basic Wakeup via Notifier" {
    if (@import("builtin").os.tag != .windows) {
        return error.SkipZigTest;
    }

    const ws2_32 = std.os.windows.ws2_32;
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    var ntfr: internal.Notifier = try internal.Notifier.init(testing.allocator);
    defer ntfr.deinit();

    var pl = try internal.Poller.init(testing.allocator);
    defer pl.deleteAll();

    // Set up TriggeredChannel for Notifier receiver
    const ntfr_skt: internal.triggeredSkts.NotificationSkt = internal.triggeredSkts.NotificationSkt.init(&ntfr.receiver);
    var tc: TriggeredChannel = TriggeredChannel{
        .tskt = .{ .notification = ntfr_skt },
        .acn = .{ .chn = tofu.message.SpecialMaxChannelNumber },
    };

    _ = try pl.attachChannel(&tc);

    // Initial poll - should timeout
    const trgs1: Triggers = try pl.waitTriggers(100);
    try testing.expect(trgs1.timeout == .on);

    // Send notification
    const notif: internal.Notifier.Notification = internal.Notifier.Notification{
        .kind = .message,
        .oob = .on,
    };
    try ntfr.sendNotification(notif);

    // Poll again - should trigger notify
    // Wait a bit longer to ensure it's delivered
    const trgs2: Triggers = try pl.waitTriggers(1000);
    try testing.expect(trgs2.notify == .on);

    // Verify received notification
    const tc_ptr: *TriggeredChannel = pl.trgChannel(tofu.message.SpecialMaxChannelNumber).?;
    const rcvd: internal.Notifier.Notification = try tc_ptr.*.tskt.tryRecvNotification();
    try testing.expectEqual(notif, rcvd);

    // Poll again - should timeout (as we drained it)
    const trgs3: Triggers = try pl.waitTriggers(100);
    try testing.expect(trgs3.timeout == .on);
}

test "Windows Poller: TCP Echo Readiness" {
    if (@import("builtin").os.tag != .windows) {
        return error.SkipZigTest;
    }

    const ws2_32 = std.os.windows.ws2_32;
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    var pl = try internal.Poller.init(testing.allocator);
    defer pl.deleteAll();

    // 1. Setup Listener
    const port: u16 = try tofu.FindFreeTcpPort();
    const server_addr: tofu.address.TCPServerAddress = tofu.address.TCPServerAddress.init("127.0.0.1", port);
    var sc: SocketCreator = SocketCreator.init(testing.allocator);
    const list_skt: Skt = try sc.fromAddress(.{ .tcp_server_addr = server_addr });
    // list_skt will be owned by AcceptSkt/TriggeredChannel

    var tc_list: TriggeredChannel = TriggeredChannel{
        .tskt = .{ .accept = .{ .skt = list_skt } },
        .acn = .{ .chn = 1 },
    };

    _ = try pl.attachChannel(&tc_list);

    // 2. Setup Client
    const client_addr: tofu.address.TCPClientAddress = tofu.address.TCPClientAddress.init("127.0.0.1", port);
    var client_skt: Skt = try sc.fromAddress(.{ .tcp_client_addr = client_addr });
    defer client_skt.deinit();

    // Start connecting
    _ = try client_skt.connect();

    // 3. Poll for ACCEPT
    const trgs1: Triggers = try pl.waitTriggers(1000);
    try testing.expect(trgs1.accept == .on);

    // 4. Accept connection
    const tc_list_ptr: *TriggeredChannel = pl.trgChannel(1).?;
    const server_skt: Skt = (try tc_list_ptr.*.tskt.tryAccept()).?;
    // server_skt will be owned by IoSkt

    // 5. Setup IO channels
    var pool: internal.Pool = try internal.Pool.init(testing.allocator, 10, 1024, null);
    defer pool.close();

    const srv_io: internal.triggeredSkts.IoSkt = try internal.triggeredSkts.IoSkt.initServerSide(&pool, 2, server_skt);
    var tc_srv: TriggeredChannel = TriggeredChannel{
        .tskt = .{ .io = srv_io },
        .acn = .{ .chn = 2 },
    };
    _ = try pl.attachChannel(&tc_srv);

    // 6. Send properly formatted message from client
    {
        const msg: *tofu.message.Message = try tofu.message.Message.create(testing.allocator);
        defer msg.*.destroy();
        try msg.*.body.append("Hello");

        var bh_bytes: [tofu.message.BinaryHeader.BHSIZE]u8 = undefined;
        msg.*.bhdr.@"<bl>" = @intCast(msg.*.actual_body_len());
        msg.*.bhdr.toBytes(&bh_bytes);

        _ = try client_skt.send(&bh_bytes);
        _ = try client_skt.send(msg.*.body.body().?);
    }

    // 7. Poll for RECV
    const trgs2: Triggers = try pl.waitTriggers(1000);
    try testing.expect(trgs2.recv == .on);

    // 8. Receive data on server
    const tc_srv_ptr_final: *TriggeredChannel = pl.trgChannel(2).?;
    var mq: tofu.message.MessageQueue = try tc_srv_ptr_final.tskt.tryRecv();
    defer tofu.message.clearQueue(&mq);
    try testing.expect(mq.count() > 0);
    try testing.expectEqualStrings("Hello", mq.first.?.*.body.body().?);

    // 9. Add something to send queue to trigger SEND interest
    {
        const msg_out: *tofu.message.Message = try tofu.message.Message.create(testing.allocator);
        msg_out.*.bhdr.channel_number = 2;
        try tc_srv_ptr_final.tskt.addToSend(msg_out);
    }

    // 10. Poll for SEND readiness
    const trgs3: Triggers = try pl.waitTriggers(1000);
    try testing.expect(trgs3.send == .on);
}

const std = @import("std");
const tofu = @import("tofu");
const internal = tofu.@"internal usage";
const Skt = internal.Skt;
const SocketCreator = internal.SocketCreator;
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;
const Triggers = internal.triggeredSkts.Triggers;
const testing = std.testing;
