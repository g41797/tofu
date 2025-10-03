// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
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

pub const ActiveChannel = struct {
    chn: ChannelNumber = undefined,
    mid: MessageID = undefined,
    intr: ?message.ProtoFields = undefined,
    ctx: ?*anyopaque = undefined,
};

pub const ActiveChannels = struct {
    allocator: Allocator = undefined,
    nodes: []ChannelNode = undefined,
    removed: ChannelNodeQueue = .{},
    free: ChannelNodeQueue = .{},
    active: std.AutoArrayHashMap(ChannelNumber, ActiveChannel) = undefined,
    mutex: Mutex = undefined,

    pub fn create(gpa: Allocator) !*ActiveChannels {
        const cns = try gpa.create(ActiveChannels);
        errdefer gpa.destroy(cns);
        try cns.init(gpa);
        return cns;
    }

    pub fn destroy(cns: *ActiveChannels) void {
        const gpa = cns.allocator;
        cns.deinit();
        gpa.destroy(cns);
    }

    pub fn init(gpa: Allocator, rrchn: u8) !ActiveChannels {
        if (rrchn == 0) {
            return error.RecentlyRemovedChannelsNumber;
        }
        var nodes: []ChannelNode = try gpa.alloc(ChannelNode, rrchn);

        var channels: ActiveChannels = .{
            .allocator = gpa,
            .nodes = nodes,
            .removed = .{},
            .free = .{},
            .active = .init(gpa),
        };

        try channels.active.ensureTotalCapacity(256);

        for (0..rrchn) |i| {
            const node = &nodes[i];
            channels.free.enqueue(node);
        }

        channels.mutex = .{};

        return channels;
    }

    pub fn deinit(cns: *ActiveChannels) void {
        cns.mutex.lock();
        defer cns.mutex.unlock();

        cns.allocator.free(cns.nodes);
        cns.active.deinit();
    }

    // Called on both caller and Engine threads
    pub fn createChannel(cns: *ActiveChannels, mid: MessageID, intr: ?message.ProtoFields, ptr: ?*anyopaque) ActiveChannel {
        cns.mutex.lock();
        defer cns.mutex.unlock();

        while (true) {
            const rv = rand.int(ChannelNumber);

            if (cns.active.contains(rv)) {
                continue;
            }

            if (cns.removed.exists(rv)) {
                continue;
            }

            const ach: ActiveChannel = .{
                .chn = rv,
                .mid = mid,
                .intr = intr,
                .ctx = ptr,
            };
            cns.active.put(rv, ach) catch unreachable;

            return ach;
        }
    }

    pub fn exists(cns: *ActiveChannels, cn: ChannelNumber) bool {
        cns.mutex.lock();
        defer cns.mutex.unlock();

        return cns.active.contains(cn);
    }

    pub fn ctx(cns: *ActiveChannels, cn: ChannelNumber) ?*anyopaque {
        cns.mutex.lock();
        defer cns.mutex.unlock();

        const achn = cns.active.get(cn) catch {
            return null;
        };

        return achn.ctx;
    }

    pub fn activeChannel(cns: *ActiveChannels, cn: ChannelNumber) !ActiveChannel {
        cns.mutex.lock();
        defer cns.mutex.unlock();

        const achn = cns.active.get(cn);

        if (achn == null) {
            return AmpeError.InvalidChannelNumber;
        }

        return achn.?;
    }

    // Called only on Engine thread
    pub fn removeChannel(cns: *ActiveChannels, cn: ChannelNumber) bool {
        cns.mutex.lock();
        defer cns.mutex.unlock();

        return _removeChannel(cns, cn);
    }

    // Called only on Engine thread
    pub fn removeChannels(cns: *ActiveChannels, ptr: ?*anyopaque) !usize {
        cns.mutex.lock();
        defer cns.mutex.unlock();

        var removedChns: usize = 0;

        var chns_to_remove = std.ArrayList(ChannelNumber).init(cns.allocator);
        defer chns_to_remove.deinit();

        var it = cns.active.iterator();
        while (it.next()) |kv_pair| {
            if (kv_pair.value_ptr.ctx == ptr) {
                try chns_to_remove.append(kv_pair.key_ptr.*);
            }
        }

        for (chns_to_remove.items) |cnm| {
            if (_removeChannel(cns, cnm)) {
                removedChns += 1;
            }
        }

        return removedChns;
    }

    fn _removeChannel(cns: *ActiveChannels, cn: ChannelNumber) bool {
        const wasRemoved = cns.active.orderedRemove(cn);

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

    pub fn channelsGroup(cns: *ActiveChannels, ptr: ?*anyopaque) !std.ArrayList(ChannelNumber) {
        cns.mutex.lock();
        defer cns.mutex.unlock();

        var chns = std.ArrayList(ChannelNumber).init(cns.allocator);
        errdefer chns.deinit();

        var it = cns.active.iterator();
        while (it.next()) |kv_pair| {
            if (kv_pair.value_ptr.ctx == ptr) {
                try chns.append(kv_pair.key_ptr.*);
            }
        }

        return chns;
    }

    pub fn allChannels(cns: *ActiveChannels, chns: *std.ArrayList(ChannelNumber)) !void {
        cns.mutex.lock();
        defer cns.mutex.unlock();
        chns.resize(0) catch unreachable;

        var it = cns.active.iterator();
        while (it.next()) |kv_pair| {
            try chns.append(kv_pair.key_ptr.*);
        }

        return;
    }
};

const status = @import("tofu").status;
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;

const message = @import("tofu").message;
pub const ChannelNumber = message.ChannelNumber;
const MessageID = message.MessageID;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const rand = std.crypto.random;
