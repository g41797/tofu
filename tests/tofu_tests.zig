// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "find free TCP/IP port" {
    std.testing.log_level = .debug;

    try tofu.initPlatform();
    defer tofu.deinitPlatform();

    std.log.info("start find free TCP/IP port ", .{});

    const port = try tofu.FindFreeTcpPort();

    std.debug.print("free TCP/IP port {d}", .{port});

    try std.testing.expect(port > 0); // Ensure a valid port is returned
}

test {
    std.testing.log_level = .debug;

    // Platform-independent (no sockets):
    _ = @import("ampe/Pool_tests.zig");
    _ = @import("ampe/channels_tests.zig");
    _ = @import("address_tests.zig");
    _ = @import("message_tests.zig");
    _ = @import("ampe/temp_uds_path_tests.zig");

    // Linux Skt/SocketCreator
    if (@import("builtin").os.tag == .linux) {
        _ = @import("ampe/sockets_tests.zig");
    }

    // Socket-dependent (all platforms):
    std.log.debug("\r\n\r\n   ****  start Notifier tests ****\r\n\r\n", .{});
    _ = @import("ampe/Notifier_tests.zig");
    std.log.debug("\r\n\r\n   ****  finish Notifier tests ****\r\n\r\n", .{});

    // posix_net :
    if (test_gate_options.posixnet) {
        _ = @import("posix_net/posix_net_tests.zig");
        _ = @import("ampe/portable_poller_tests.zig");
    }

    // Poller backend (backend-independent, all platforms):
    _ = @import("ampe/poller_tests.zig");

    // "Application" level
    std.log.debug("\r\n   ****  tofu TESTS Reactor ****\r\n", .{});

    _ = @import("reactor_tests.zig");

    std.log.debug("\r\n   ****  tofu TESTS no sockets ****\r\n", .{});

    @import("std").testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const gpa = std.testing.allocator;

const builtin = @import("builtin");
const isMac = builtin.os.tag == .macos;

const recipes = @import("recipes");
const test_gate_options = @import("test_gate_options");
const tofu = @import("tofu");
