// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.AmpeVTable,

    /// Gets a message from the internal pool based on the allocation strategy.
    ///
    /// Returns null if the pool is empty and the strategy is poolOnly.
    /// Returns an error if the engine is shutting down or allocation fails.
    ///
    /// Thread-safe.
    pub fn get(
        ampe: Ampe,
        strategy: AllocationStrategy,
    ) status.AmpeError!?*message.Message {
        return ampe.vtable.get(ampe.ptr, strategy);
    }

    /// Returns a message to the internal pool.
    ///
    /// If the pool is closed, destroys the message.
    /// Sets msg.* to null to prevent reuse.
    ///
    /// Thread-safe.
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

    /// Don't forget:
    ///     - Call destroy on the result to abort communication and free memory.
    ///
    /// Thread-safe.
    pub fn create(
        ampe: Ampe,
    ) status.AmpeError!ChannelGroup {
        return ampe.vtable.create(ampe.ptr);
    }

    /// Aborts communication,  frees memory
    ///
    /// Thread-safe.
    pub fn destroy(
        ampe: Ampe,
        chnls: ChannelGroup,
    ) status.AmpeError!void {
        return ampe.vtable.destroy(ampe.ptr, chnls.ptr);
    }

    /// I hope returns "GPA-compatible" allocator
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

pub const ChannelGroup = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.CHNLSVTable,

    /// Submits a message for async processing:
    /// - most cases: send to peer
    /// - others: internal network related processing
    ///
    /// The message is not actually sent, or
    /// handled, when this call returns
    ///
    /// On success:
    /// - Sets `msg.*` to null (prevents reuse).
    /// - Returns `BinaryHeader` for tracking.
    ///
    ///
    /// On error:
    /// - Returns an error.
    /// - If the engine cannot use the message (internal failure),
    ///   also sets `msg.*` to null.
    ///
    /// Thread-safe.
    pub fn post(
        chnls: ChannelGroup,
        msg: *?*message.Message,
    ) status.AmpeError!message.BinaryHeader {
        return chnls.vtable.post(chnls.ptr, msg);
    }

    /// Waits for the next message from the internal queue.
    ///
    /// Timeout is in nanoseconds. Returns `null` if no message arrives in time.
    ///
    /// Message sources:
    /// - Remote peer (via `post` on their side).
    /// - Application (via `updateReceiver` on this ChannelGroup).
    /// - Ampe (status/control messages).
    ///
    /// Check `BinaryHeader` to identify the source.
    ///
    /// On error: stop using this ChannelGroup and call `ampe.destroy` on it.
    ///
    /// Call in a loop from **one thread only**.
    pub fn waitReceive(
        chnls: ChannelGroup,
        timeout_ns: u64,
    ) status.AmpeError!?*message.Message {
        return chnls.vtable.waitReceive(chnls.ptr, timeout_ns);
    }

    /// Adds a message to the internal queue for `waitReceive`.
    ///
    /// If `msg.*` is not null:
    /// - Engine sets status to `'receiver_update'`.
    /// - Sets `msg.*` to null after success.
    /// - No need for `channel_number` or similar fields.
    ///
    /// If `msg.*` is null:
    /// - Creates a `'receiver_update'` Signal and adds it.
    ///
    /// Returns error if shutting down.
    ///
    /// Use from another thread to:
    /// - Wake the receiver (`msg.*` = null).
    /// - Send info/commands/notifications.
    ///
    /// FIFO order only. No priority queues.
    ///
    /// Thread-safe.
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
