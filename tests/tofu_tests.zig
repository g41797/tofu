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

    // Socket-dependent tests (all platforms):
    std.log.debug("\r\n\r\n   ****  start Notifier tests ****\r\n\r\n", .{});
    _ = @import("ampe/Notifier_tests.zig");
    std.log.debug("\r\n\r\n   ****  finish Notifier tests ****\r\n\r\n", .{});

    // Linux Skt/SocketCreator contract tests (baseline for posix removal):
    if (@import("builtin").os.tag == .linux) {
        _ = @import("ampe/sockets_tests.zig");
    }

    // posix_net module contract tests :
    if (test_gate_options.portable) {
        _ = @import("posix_net/posix_net_tests.zig");
        _ = @import("ampe/portable_poller_tests.zig");
    }

    // Poller backend contract tests (backend-independent, all platforms):
    _ = @import("ampe/poller_tests.zig");

    // if (@import("builtin").os.tag != .macos) {

        // PollerCore integration tests (all backends, all platforms):
        _ = @import("pollercore_tests.zig");

        std.log.debug("\r\n   ****  tofu TESTS Reactor ****\r\n", .{});

        _ = @import("reactor_tests.zig");
    // }

    @import("std").testing.refAllDecls(@This());
}


const std = @import("std");
const Allocator = std.mem.Allocator;
const gpa = std.testing.allocator;

const recipes = @import("recipes");
const test_gate_options = @import("test_gate_options");
const tofu = @import("tofu");

