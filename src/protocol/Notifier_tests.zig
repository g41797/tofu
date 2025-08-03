// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "base Notifier" {
    var ntfr = try Notifier.init(testing.allocator);
    defer ntfr.deinit();

    try testing.expectEqual(true, ntfr.isReadyToSend());
    try testing.expectEqual(false, ntfr.isReadyToRecv());

    const notif: Notification = .{
        .kind = .oobMsg,
        .combination = .ByeSignal,
    };

    try ntfr.sendNotification(notif);
    try testing.expectEqual(true, ntfr.isReadyToRecv());

    const ntfc = try ntfr.recvNotification();
    try testing.expectEqual(notif, ntfc);
}

const Notifier = @import("Notifier.zig");
const NotificationKind = Notifier.NotificationKind;
const Notification = Notifier.Notification;

const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const Allocator = std.mem.Allocator;
