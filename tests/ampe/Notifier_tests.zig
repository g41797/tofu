// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("Notifier_tests\r\n", .{});
}

test "create file for address of uds socket" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var buffer: [100]u8 = undefined;
    var tempFile = try temp.create_file(std.testing.allocator, "*.yaaamp");
    defer tempFile.deinit();
    const uds_path: []u8 = try tempFile.parent_dir.realpath(tempFile.basename, &buffer);
    try testing.expectEqual(uds_path.len > 0, true);
}

test "base Notifier" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var ntfr: Notifier = try Notifier.init(testing.allocator);
    defer ntfr.deinit();
    const notif: Notification = .{ .kind = .message, .oob = .on };
    try ntfr.sendNotification(notif);
    const ntfc: Notification = try ntfr.recvNotification();
    try testing.expectEqual(notif, ntfc);
}

const tofu = @import("tofu");

const Notifier = tofu.@"internal usage".Notifier;
const NotificationKind = Notifier.NotificationKind;
const Notification = Notifier.Notification;

const temp = @import("temp");

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
