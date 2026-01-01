// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("Notifier_tests\r\n", .{});
}

test "create file for address of uds socket" {
    var buffer: [100]u8 = undefined;
    var tempFile = try temp.create_file(std.testing.allocator, "*.yaaamp");
    defer tempFile.deinit();
    const uds_path: []u8 = try tempFile.parent_dir.realpath(tempFile.basename, &buffer);
    try testing.expectEqual(uds_path.len > 0, true);
}

test "base Notifier" {
    std.testing.log_level = .debug;

    var ntfr: Notifier = try Notifier.init(testing.allocator);
    defer ntfr.deinit();

    try testing.expectEqual(true, ntfr.isReadyToSend());
    try testing.expectEqual(false, ntfr.isReadyToRecv());

    const notif: Notification = .{
        .kind = .message,
        .oob = .on,
    };

    try ntfr.sendNotification(notif);
    try testing.expectEqual(true, ntfr.isReadyToRecv());

    const ntfc: Notification = try ntfr.recvNotification();
    try testing.expectEqual(notif, ntfc);

    try ntfr.sendAck(0xFF);

    const ack: u8 = try ntfr.recvAck();

    try testing.expectEqual(0xFF, ack);
}
const tofu = @import("tofu");

const Notifier = tofu.@"internal usage".Notifier;
const NotificationKind = Notifier.NotificationKind;
const Notification = Notifier.Notification;

const temp = @import("temp");

const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const Allocator = std.mem.Allocator;
