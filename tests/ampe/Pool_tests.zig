// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("Pool_tests\r\n", .{});
}

test "Pool init" {
    var pool: Pool = try Pool.init(std.testing.allocator, null, null, null);
    pool.close();
}

test "Pool base finctionality" {
    var pool: Pool = try Pool.init(std.testing.allocator, null, null, null);
    pool.freeAll();
    try testing.expectError(AmpeError.PoolEmpty, pool.get(.poolOnly));

    var msg1: ?*tofu.message.Message = try pool.get(.always);

    var msg2: ?*tofu.message.Message = try pool.get(.always);

    pool.put(msg1.?);
    pool.put(msg2.?);

    pool.freeAll();

    msg1 = try pool.get(.always);

    msg2 = try pool.get(.always);

    pool.put(msg1.?);
    pool.put(msg2.?);

    try testing.expectEqual(msg2, pool.get(.poolOnly));
    try testing.expectEqual(msg1, pool.get(.poolOnly));
    pool.free(msg1.?);
    pool.free(msg2.?);

    try testing.expectError(AmpeError.PoolEmpty, pool.get(.poolOnly));

    pool.close();
}

const tofu = @import("tofu");
const AmpeError = tofu.status.AmpeError;
const AllocationStrategy = tofu.AllocationStrategy;

const Pool = tofu.@"internal usage".Pool;

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
