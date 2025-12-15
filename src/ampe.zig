// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

// 2DO - Define error set(s) for errors returned by ChannelGroup and Ampe

/// Defines the async message passing engine interface.
/// "Ampe" and "engine" mean the same thing.
///
/// Provides methods to:
/// - Get/return messages from the internal pool.
/// - Create/destroy ChannelGroups.
/// - Access the shared allocator for memory management.
pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.AmpeVTable,

    /// Gets a message from the internal pool.
    ///
    /// Uses the given `strategy` to decide how to allocate.
    /// Returns `null` if pool is empty and `strategy` is `poolOnly`.
    ///
    /// Returns error if engine is shutting down or allocation fails.
    ///
    /// Thread-safe.
    pub fn get(
        ampe: Ampe,
        strategy: AllocationStrategy,
    ) status.AmpeError!?*message.Message {
        return ampe.vtable.get(ampe.ptr, strategy);
    }

    /// Returns a message to the internal pool.
    /// If pool is closed, destroys the message instead.
    ///
    /// Always sets `msg.*` to `null` to prevent reuse.
    ///
    /// Thread-safe.
    pub fn put(
        ampe: Ampe,
        msg: *?*message.Message,
    ) void {
        if (msg.* == null) {
            return;
        }

        // Reset message to avoid issues if used in another thread
        msg.*.?.reset();
        msg.*.?.prev = null;
        msg.*.?.next = null;

        ampe.vtable.put(ampe.ptr, msg);
    }

    /// Creates a new `ChannelGroup`.
    ///
    /// Call `destroy` on result to stop communication and free memory.
    ///
    /// Thread-safe.
    pub fn create(
        ampe: Ampe,
    ) status.AmpeError!ChannelGroup {
        return ampe.vtable.create(ampe.ptr);
    }

    /// Destroys `ChannelGroup`, stops communication, frees memory.
    ///
    /// Thread-safe.
    pub fn destroy(
        ampe: Ampe,
        chnls: ChannelGroup,
    ) status.AmpeError!void {
        return ampe.vtable.destroy(ampe.ptr, chnls.ptr);
    }

    /// Returns the allocator used by the engine for all memory.
    ///
    /// Thread-safe.
    pub fn getAllocator(
        ampe: Ampe,
    ) Allocator {
        return ampe.vtable.getAllocator(ampe.ptr);
    }
};

/// Defines how messages are allocated from the pool.
pub const AllocationStrategy = enum {
    /// Tries to get a message from the pool. Returns null if the pool is empty.
    poolOnly,
    /// Gets a message from the pool or creates a new one if the pool is empty.
    always,
};

//////////////////////////////////////////////////////////////////////////
// Client and server terms are used only during the initial handshake.
// After the handshake, both sides are equal. We call them **peers**.
// They send and receive messages based on application logic.
//////////////////////////////////////////////////////////////////////////

/// Defines the ChannelGroup interface for async message passing.
/// Supports two-way message exchange between peers.
pub const ChannelGroup = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.CHNLSVTable,

    /// Submits a message for async processing:
    /// - most cases: send to peer
    /// - others: internal network related processing
    ///
    /// On success:
    /// - Sets `msg.*` to null (prevents reuse).
    /// - Returns `BinaryHeader` for tracking.
    ///
    /// On error:
    /// - Returns an error.
    /// - If the engine cannot use the message (internal failure),
    ///   also sets `msg.*` to null.
    ///
    /// Thread-safe.
    pub fn enqueueToPeer(
        chnls: ChannelGroup,
        msg: *?*message.Message,
    ) status.AmpeError!message.BinaryHeader {
        return chnls.vtable.enqueueToPeer(chnls.ptr, msg);
    }

    /// Waits for the next message from the internal queue.
    ///
    /// Timeout is in nanoseconds. Returns `null` if no message arrives in time.
    ///
    /// Message sources:
    /// - Remote peer (via `enqueueToPeer` on their side).
    /// - Application (via `updateReceiver` on this ChannelGroup).
    /// - Ampe (status/control messages).
    ///
    /// Check `BinaryHeader` to identify the source.
    ///
    /// On error: stop using this ChannelGroup.
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

/// Holds configuration options for the message passing engine.
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
