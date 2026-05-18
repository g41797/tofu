// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("Notifier_tests\r\n", .{});
}

test "TempUdsPath produces unique absolute path" {
    try tofu.initPlatform();
    defer tofu.deinitPlatform();
    var tup: tofu.TempUdsPath = .{};
    const uds_path = try tup.buildPath();
    try testing.expect(uds_path.len > 0);
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

const std = @import("std");
const testing = std.testing;
