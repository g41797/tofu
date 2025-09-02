// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const std_options: @import("std").Options = .{ .log_level = .debug };

test {
    std.testing.log_level = .debug;

    std.log.debug("message_tests\r\n", .{});
    _ = @import("message_tests.zig");

    std.log.debug("configurator_tests\r\n", .{});
    _ = @import("configurator_tests.zig");

    std.log.debug("channels_tests\r\n", .{});
    _ = @import("engine/channels_tests.zig");

    std.log.debug("Notifier_tests\r\n", .{});
    _ = @import("engine/Notifier_tests.zig");

    std.log.debug("Pool_tests\r\n", .{});
    _ = @import("engine/Pool_tests.zig");

    std.log.debug("sockets_tests\r\n", .{});
    _ = @import("engine/sockets_tests.zig");

    std.log.debug("engine_test\r\n", .{});
    _ = @import("engine_test.zig");

    @import("std").testing.refAllDecls(@This());
}

const std = @import("std");
