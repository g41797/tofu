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

pub const protocol = @import("../protocol.zig");
pub const ChannelNumber = protocol.ChannelNumber;

const std = @import("std");
const Allocator = std.mem.Allocator;
