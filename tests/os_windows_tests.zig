// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

test "find free TCP/IP port" {
    std.testing.log_level = .debug;

    log.info("start find free TCP/IP port ", .{});

    const port = try tofu.FindFreeTcpPort();

    log.debug("free TCP/IP port {d}", .{port});

    try std.testing.expect(port > 0); // Ensure a valid port is returned
}

test "temp path " {
    std.testing.log_level = .info;

    var tup: tofu.TempUdsPath = .{};

    const path: []u8 = try tup.buildPath(gpa);

    log.debug("\r\ntemp path {s}\r\n", .{path});

    return;
}

// test "Windows Stage 0: IOCP Wakeup" {
//    if (builtin.os.tag != .windows) {
//        return error.SkipZigTest;
//    }
//
//    const win_poc = @import("win_poc");
//    try win_poc.stage0.runTest();
// }
//
// test "Windows Stage 1: Accept Test" {
//    if (builtin.os.tag != .windows) {
//        return error.SkipZigTest;
//    }
//
//    const win_poc = @import("win_poc");
//    try win_poc.stage1.runTest();
// }
//
// test "Windows Stage 1U: UDS Accept Test" {
//    if (builtin.os.tag != .windows) {
//        return error.SkipZigTest;
//    }
//
//    const win_poc = @import("win_poc");
//    try win_poc.stage1U.runTest();
// }
//
// test "Windows Stage 1 IOCP: Accept Test" {
//    if (builtin.os.tag != .windows) {
//        return error.SkipZigTest;
//    }
//
//    const win_poc = @import("win_poc");
//    try win_poc.stage1_iocp.runTest();
// }
//
// test "Windows Stage 2: Echo Test" {
//    if (builtin.os.tag != .windows) {
//        return error.SkipZigTest;
//    }
//
//    const win_poc = @import("win_poc");
//    try win_poc.stage2.runTest();
// }
//
// test "Windows Stage 3: Stress & Cancellation Test" {
//    if (builtin.os.tag != .windows) {
//        return error.SkipZigTest;
//    }
//
//    const win_poc = @import("win_poc");
//    try win_poc.stage3.runTest(std.testing.allocator);
// }
//
// test "Windows Stage 4: PinnedState Indirection Test" {
//    if (builtin.os.tag != .windows) {
//        return error.SkipZigTest;
//    }
//
//    const win_poc = @import("win_poc");
//    try win_poc.stage4.runTest(std.testing.allocator);
// }

test "Windows Notifier" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const ws2_32 = std.os.windows.ws2_32;
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    std.testing.log_level = .debug;
    const Notifier = tofu.@"internal usage".Notifier;
    const Notification = Notifier.Notification;

    var ntfr: Notifier = try Notifier.init(std.testing.allocator);
    defer ntfr.deinit();

    try std.testing.expectEqual(true, ntfr.isReadyToSend());
    try std.testing.expectEqual(false, ntfr.isReadyToRecv());

    const notif: Notification = .{ .kind = .message, .oob = .on };
    try ntfr.sendNotification(notif);
    try std.testing.expectEqual(true, ntfr.isReadyToRecv());

    const ntfc: Notification = try ntfr.recvNotification();
    try std.testing.expectEqual(notif, ntfc);
}

const tofu = @import("tofu");

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const gpa = std.testing.allocator;