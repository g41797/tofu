// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("\r\n   ****  ROOT TESTS  ****\r\n", .{});

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
const Allocator = std.mem.Allocator;
const gpa = std.testing.allocator;

// pub const Msg = struct {
//     body: [16]u8 = undefined,
//
//     pub fn create(allocator: Allocator) !*Msg {
//         return try allocator.create(Msg);
//     }
//     pub fn destroy(msg: *Msg, allocator: Allocator) void {
//         allocator.destroy(msg);
//     }
//     pub fn DestroySendMsg(msgoptptr: *?*Msg) void {
//         const msgopt = msgoptptr.*;
//         if (msgopt) |msg| {
//             msg.destroy();
//             msgoptptr.* = null;
//         }
//     }
// };
//
//
// // Sends msg to another thread for the transfer
// // If msg is not valid - returns error
// pub fn asyncMsgSend(msg: *?*Msg) !void {
//     msg.* = null;
// }
//
// pub fn alwaysError() !void {
//     return error.Timeout;
// }

// test "something" {
//     var msg = try Msg.create(gpa);
//     errdefer msg.destroy(gpa);
//     try asyncMsgSend(msg);
// }

// test "anything" {
//     var msg: ?*Msg = try Msg.create(gpa);
//     defer msg.DestroySendMsg(&msg);
//     try asyncMsgSend(&msg);
//
// }
