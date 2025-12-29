// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

// 2DO - Define error set(s) for errors returned by ChannelGroup and Ampe

pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.AmpeVTable,

    /// Thread-safe. Returns null if pool empty and strategy is poolOnly.
    pub fn get(
        ampe: Ampe,
        strategy: AllocationStrategy,
    ) status.AmpeError!?*message.Message {
        return ampe.vtable.get(ampe.ptr, strategy);
    }

    /// Thread-safe. Sets msg to null.
    pub fn put(
        ampe: Ampe,
        msg: *?*message.Message,
    ) void {
        if (msg.* == null) {
            return;
        }

        msg.*.?.reset();
        msg.*.?.prev = null;
        msg.*.?.next = null;

        ampe.vtable.put(ampe.ptr, msg);
    }

    /// Thread-safe.
    pub fn create(
        ampe: Ampe,
    ) status.AmpeError!ChannelGroup {
        return ampe.vtable.create(ampe.ptr);
    }

    /// Thread-safe.
    pub fn destroy(
        ampe: Ampe,
        chnls: ChannelGroup,
    ) status.AmpeError!void {
        return ampe.vtable.destroy(ampe.ptr, chnls.ptr);
    }

    pub fn getAllocator(
        ampe: Ampe,
    ) Allocator {
        return ampe.vtable.getAllocator(ampe.ptr);
    }
};

pub const AllocationStrategy = enum {
    poolOnly, // Returns null if pool empty
    always, // Creates new if pool empty
};

// After handshake, both sides are peers.

pub const ChannelGroup = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.CHNLSVTable,

    /// Thread-safe. Sets msg to null. Returns BinaryHeader for tracking.
    pub fn enqueueToPeer(
        chnls: ChannelGroup,
        msg: *?*message.Message,
    ) status.AmpeError!message.BinaryHeader {
        return chnls.vtable.enqueueToPeer(chnls.ptr, msg);
    }

    /// Single thread only. Timeout in nanoseconds. Returns null on timeout.
    pub fn waitReceive(
        chnls: ChannelGroup,
        timeout_ns: u64,
    ) status.AmpeError!?*message.Message {
        return chnls.vtable.waitReceive(chnls.ptr, timeout_ns);
    }

    /// Thread-safe. Wake receiver or send notification. FIFO only.
    /// Pass null msg to just wake receiver, non-null to send data.
    pub fn updateReceiver(
        chnls: ChannelGroup,
        update: *?*message.Message,
    ) status.AmpeError!void {
        return chnls.vtable.updateReceiver(chnls.ptr, update);
    }
};

pub const Options = struct {
    initialPoolMsgs: ?u16 = null,
    maxPoolMsgs: ?u16 = null,
};

pub const DefaultOptions: Options = .{
    .initialPoolMsgs = 16,
    .maxPoolMsgs = 64,
};

pub const waitReceive_INFINITE_TIMEOUT: u64 = std.math.maxInt(u64);
pub const waitReceive_SEC_TIMEOUT: u64 = std.time.ns_per_s;
pub const DBG = (@import("builtin").mode == .Debug);

const message = @import("message.zig");
const status = @import("status.zig");
const vtables = @import("ampe/vtables.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
