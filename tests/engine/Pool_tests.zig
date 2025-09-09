// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "Pool init" {
    var pool = try Pool.init(std.testing.allocator, null, null, null);
    pool.close();
}

test "Pool base finctionality" {
    var pool = try Pool.init(std.testing.allocator, null, null, null);
    pool.freeAll();
    try testing.expectError(AmpeError.PoolEmpty, pool.get(.poolOnly));

    var msg1 = try pool.get(.always);

    var msg2 = try pool.get(.always);

    pool.put(msg1);
    pool.put(msg2);

    pool.freeAll();

    msg1 = try pool.get(.always);

    msg2 = try pool.get(.always);

    pool.put(msg1);
    pool.put(msg2);

    try testing.expectEqual(msg2, pool.get(.poolOnly));
    try testing.expectEqual(msg1, pool.get(.poolOnly));
    pool.free(msg1);
    pool.free(msg2);

    try testing.expectError(AmpeError.PoolEmpty, pool.get(.poolOnly));

    pool.close();
}

const Pool = @import("tofu").Pool;
const AmpeError = @import("tofu").status.AmpeError;
const engine = @import("tofu").engine;
const AllocationStrategy = engine.AllocationStrategy;

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
