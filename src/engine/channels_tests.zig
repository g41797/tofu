// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "ChannelNodeQueue tests" {
    var cq: ChannelNodeQueue = .{};

    var c1: ChannelNode = .{
        .cn = 1,
    };

    try testing.expectEqual(null, cq.dequeue());
    try testing.expectEqual(false, cq.exists(c1.cn));

    var c2: ChannelNode = .{
        .cn = 2,
    };

    cq.enqueue(&c1);
    cq.enqueue(&c2);

    try testing.expectEqual(true, cq.exists(c1.cn));
    try testing.expectEqual(true, cq.exists(c2.cn));

    try testing.expectEqual(&c1, cq.dequeue());
    try testing.expectEqual(false, cq.exists(c1.cn));

    try testing.expectEqual(&c2, cq.dequeue());
    try testing.expectEqual(false, cq.exists(c2.cn));

    try testing.expectEqual(null, cq.dequeue());

    var c3: ChannelNode = .{
        .cn = 3,
    };

    cq.enqueue(&c1);
    cq.enqueue(&c2);
    cq.enqueue(&c3);

    try testing.expectEqual(null, cq.remove(4));
    try testing.expectEqual(&c2, cq.remove(2));
    try testing.expectEqual(&c1, cq.remove(1));
    try testing.expectEqual(&c3, cq.remove(3));

    try testing.expectEqual(null, cq.remove(2));
    try testing.expectEqual(null, cq.dequeue());
}

test "Channels basic tests" {
    var acns = try ActiveChannels.init(std.testing.allocator, 3);
    acns.deinit();
}

const channels = @import("channels.zig");
const ChannelNode = channels.ChannelNode;
const ChannelNodeQueue = channels.ChannelNodeQueue;
const ActiveChannels = channels.ActiveChannels;

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
