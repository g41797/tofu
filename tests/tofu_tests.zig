// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;

    std.log.debug("\r\n   ****  tofu TESTS no sockets ****\r\n", .{});

    // Platform-independent tests (no sockets):
    _ = @import("ampe/Pool_tests.zig");
    _ = @import("ampe/channels_tests.zig");
    _ = @import("address_tests.zig");
    _ = @import("message_tests.zig");

    std.log.debug("\r\n   ****  tofu TESTS Notifier ****\r\n", .{});

    // Socket-dependent tests (all platforms):
    _ = @import("ampe/Notifier_tests.zig");

    // Windows-specific POC/Poller tests:
    if (@import("builtin").os.tag == .windows) {
        _ = @import("os_windows_tests.zig");
        _ = @import("windows_poller_tests.zig");
    }

    // Linux Skt/SocketCreator contract tests (baseline for posix removal):
    if (@import("builtin").os.tag == .linux) {
        _ = @import("ampe/sockets_tests.zig");
    }

    std.log.debug("\r\n   ****  tofu TESTS Reactor ****\r\n", .{});

    // Main test - for Linux
    // if (@import("builtin").os.tag == .linux) {
    _ = @import("reactor_tests.zig");
    // }


    @import("std").testing.refAllDecls(@This());
}

const tofu = @import("tofu");
const recipes = @import("recipes");

const std = @import("std");
const Allocator = std.mem.Allocator;
const gpa = std.testing.allocator;
