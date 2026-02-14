// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

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

