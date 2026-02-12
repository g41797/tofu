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
