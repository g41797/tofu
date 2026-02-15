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

test "Windows Stage 0: IOCP Wakeup" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const win_poc = @import("win_poc");
    try win_poc.stage0.runTest();
}

test "Windows Stage 1: Accept Test" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const win_poc = @import("win_poc");
    try win_poc.stage1.runTest();
}

test "Windows Stage 1U: UDS Accept Test" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const win_poc = @import("win_poc");
    try win_poc.stage1U.runTest();
}

test "Windows Stage 1 IOCP: Accept Test" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const win_poc = @import("win_poc");
    try win_poc.stage1_iocp.runTest();
}

test "Windows Stage 2: Echo Test" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const win_poc = @import("win_poc");
    try win_poc.stage2.runTest();
}

test "Windows Stage 3: Stress & Cancellation Test" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }

    const win_poc = @import("win_poc");
    try win_poc.stage3.runTest();
}


const tofu = @import("tofu");

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const gpa = std.testing.allocator;