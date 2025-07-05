// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "create file for address of uds socket" {
    var buffer: [100]u8 = undefined;
    var tempFile = try temp.create_file(std.testing.allocator, "*.yaaamp");
    defer tempFile.deinit();
    const uds_path = try tempFile.parent_dir.realpath(tempFile.basename, &buffer);
    try testing.expectEqual(uds_path.len > 0, true);
}

test {
    _ = @import("root.zig");
    _ = @import("TextHeaderIterator_tests.zig");

    _ = @import("protocol_test.zig");
    _ = @import("protocol/Pool_tests.zig");
    @import("std").testing.refAllDecls(@This());
}

const std = @import("std");
const testing = std.testing;

const os = std.os;
const mem = std.mem;
const Allocator = mem.Allocator;

const libxev = @import("xev");
const temp = @import("temp");
const protocol = @import("protocol.zig");
