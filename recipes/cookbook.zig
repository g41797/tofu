// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const tofu = @import("tofu");

pub fn nop() void {
    std.testing.log_level = .debug;
    std.log.debug("\r\n   ****  cookbook nop  ****\r\n", .{});

    if (tofu.DBG) {
        std.log.debug("\r\n   ****  TOFU DEBUG MODE  ****\r\n", .{});
    } else {
        std.log.debug("\r\n   ****  TOFU NON DEBUG MODE  ****\r\n", .{});
    }
}

const std = @import("std");
