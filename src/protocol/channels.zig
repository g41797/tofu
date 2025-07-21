// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const ChannelNode = struct {
    prev: ?*ChannelNode = null,
    next: ?*ChannelNode = null,
    cn: ChannelNumber = 0,
};

pub const ChannelNodeQueue = struct {
    const Self = @This();

    first: ?*ChannelNode = null,
    last: ?*ChannelNode = null,

    pub fn enqueue(fifo: *Self, new_ChannelNode: *ChannelNode) void {
        new_ChannelNode.prev = null;
        new_ChannelNode.next = null;

        if (fifo.last) |last| {
            last.next = new_ChannelNode;
            new_ChannelNode.prev = last;
        } else {
            fifo.first = new_ChannelNode;
        }

        fifo.last = new_ChannelNode;

        return;
    }

    pub fn dequeue(fifo: *Self) ?*ChannelNode {
        if (fifo.first == null) {
            return null;
        }

        var result = fifo.first;
        fifo.first = result.?.next;

        if (fifo.first == null) {
            fifo.last = null;
        } else {
            fifo.first.?.prev = fifo.first;
        }

        result.?.prev = null;
        result.?.next = null;

        return result;
    }

    pub fn exists(fifo: *Self, cn: ChannelNumber) bool {
        var node = fifo.first;
        while (node != null) {
            if (node.?.cn == cn) {
                return true;
            }
            node = node.?.next;
        }
        return false;
    }

    pub fn remove(fifo: *Self, cn: ChannelNumber) ?*ChannelNode {
        var node = fifo.first;
        while (node != null) {
            if (node.?.cn == cn) {
                if (node.?.prev) |prev_node| {
                    // Intermediate node.
                    prev_node.next = node.?.next;
                } else {
                    // First element of the list.
                    fifo.first = node.?.next;
                }

                if (node.?.next) |next_node| {
                    // Intermediate node.
                    next_node.prev = node.?.prev;
                } else {
                    // Last element of the list.
                    fifo.last = node.?.prev;
                }

                node.?.next = null;
                node.?.prev = null;
                return node;
            }
            node = node.?.next;
        }
        return null;
    }
};

pub const ActiveChannels = struct {
    allocator: Allocator = undefined,
    nodes: []ChannelNode = undefined,
    removed: ChannelNodeQueue = .{},
    free: ChannelNodeQueue = .{},
    active: AutoHashMap(ChannelNumber, MessageID) = undefined,

    pub fn init(allocator: Allocator, rrchn: u8) !ActiveChannels {
        if (rrchn == 0) {
            return error.RecentlyRemovedChannelsNumber;
        }
        var nodes: []ChannelNode = try allocator.alloc(ChannelNode, rrchn);

        var channels: ActiveChannels = .{
            .allocator = allocator,
            .nodes = nodes,
            .removed = .{},
            .free = .{},
            .active = .init(allocator),
        };

        try channels.active.ensureTotalCapacity(256);

        for (0..rrchn) |i| {
            const node = &nodes[i];
            channels.free.enqueue(node);
        }

        return channels;
    }

    pub fn deinit(cns: *ActiveChannels) void {
        cns.allocator.free(cns.nodes);
        cns.active.deinit();
    }

    pub fn createChannel(cns: *ActiveChannels, mID: ?MessageID) struct { ChannelNumber, MessageID } {
        while (true) {
            const rv = rand.int(ChannelNumber);

            if (cns.active.contains(rv)) {
                continue;
            }

            if (cns.removed.exists(rv)) {
                continue;
            }

            var mid: MessageID = undefined;
            if (mID) |mval| {
                mid = mval;
            } else {
                mid = protocol.next_mid();
            }

            cns.active.put(rv, mid) catch unreachable;

            return .{ rv, mid };
        }
    }

    pub inline fn exists(cns: *ActiveChannels, cn: ChannelNumber) bool {
        return cns.active.contains(cn);
    }

    pub fn removeChannel(cns: *ActiveChannels, cn: ChannelNumber) bool {
        const wasRemoved = cns.active.remove(cn);

        const alreadyRemoved = cns.removed.remove(cn);

        if (alreadyRemoved != null) {
            cns.removed.enqueue(alreadyRemoved.?);
            return true;
        }

        if (!wasRemoved) {
            return false;
        }

        const free = cns.free.dequeue();
        if (free != null) {
            free.?.cn = cn;
            cns.removed.enqueue(free.?);
            return true;
        }

        const rewrcn = cns.free.dequeue().?;
        rewrcn.cn = cn;
        cns.removed.enqueue(rewrcn);
        return true;
    }
};

pub const protocol = @import("../protocol.zig");
pub const ChannelNumber = protocol.ChannelNumber;
pub const MessageID = protocol.MessageID;

const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const rand = std.crypto.random;
