// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "Pool init" {
    var pool = try Pool.init(std.testing.allocator);
    pool.close();
}

test "Pool base finctionality" {
    var pool = try Pool.init(std.testing.allocator);
    var msg = pool.get(false);
    try testing.expectEqual(null, msg);

    msg = pool.get(true);
    try testing.expect(msg != null);
    pool.free(msg.?);

    var msg1 = pool.get(true);
    try testing.expect(msg1 != null);

    var msg2 = pool.get(true);
    try testing.expect(msg2 != null);

    pool.put(msg1.?);
    pool.put(msg2.?);

    pool.freeAll();

    msg1 = pool.get(true);
    try testing.expect(msg1 != null);

    msg2 = pool.get(true);
    try testing.expect(msg2 != null);

    pool.put(msg1.?);
    pool.put(msg2.?);

    try testing.expectEqual(msg2.?, pool.get(false).?);
    try testing.expectEqual(msg1.?, pool.get(false).?);
    pool.free(msg1.?);
    pool.free(msg2.?);

    try testing.expectEqual(null, pool.get(false));

    pool.close();
}

const Pool = @import("Pool.zig");

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
