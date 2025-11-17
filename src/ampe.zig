// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

///////////////////////////////////////////////////////////////////////////
/// Client and server terms are used only for the initial handshake.
/// After the handshake, both sides (called peers) are equal.
/// They send and receive messages based on application logic.
///////////////////////////////////////////////////////////////////////////

/// Defines the ChannelGroup interface for async message passing.
/// Supports two-way message exchange.
pub const ChannelGroup = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.CHNLSVTable,

    /// Sends a message to a peer asynchronously.
    ///
    /// If the send starts successfully:
    ///     - Sets msg.* to null to prevent reuse.
    ///     - Returns a BinaryHeader for tracking.
    /// If the message is invalid:
    ///     - Returns an error.
    ///
    /// Safe for use in multiple threads.
    pub fn sendToPeer(chnls: ChannelGroup, msg: *?*message.Message) status.AmpeError!message.BinaryHeader {
        return chnls.vtable.sendToPeer(chnls.ptr, msg);
    }

    /// Waits for a message from the internal queue.
    ///
    /// Returns null if no message arrives within the timeout (in nanoseconds).
    ///
    /// Messages can come from three sources:
    /// - Peer (via sendToPeer from the other side).
    /// - Application (via updateWaiter on the same channels).
    /// - Engine (sends status messages to the internal queue).
    ///
    /// Use BinaryHeader of the received message to identify the message source.
    ///
    /// Any returned error is the sign that any further should be stopped.
    ///
    ///  Call this in a loop in the same thread.
    pub fn waitReceive(chnls: ChannelGroup, timeout_ns: u64) status.AmpeError!?*message.Message {
        return chnls.vtable.waitReceive(chnls.ptr, timeout_ns);
    }

    /// Sends a message to the ChannelGroup' internal queue for processing after waitReceive.
    /// If msg.* is not null, the engine sets the message status to 'waiter_update'.
    /// After a successful send, sets msg.* to null to prevent reuse.
    /// No need to provide channel_number or similar details for this internal message.
    ///
    /// If msg.* is null, creates a Signal with 'waiter_update' status and sends it.
    ///
    ///
    /// Returns an error if ChannelGroup or engine is shutting down.
    ///
    /// Use this from a different thread to:
    /// - Signal attention (msg.* is null).
    /// - Send extra info, commands, or notifications to the waiter.
    ///
    /// Note: Messages are added to the end of the queue and processed in order.
    /// The system does not support priority queues.
    ///
    /// Safe for use in multiple threads.
    pub fn updateWaiter(chnls: ChannelGroup, update: *?*message.Message) status.AmpeError!void {
        return chnls.vtable.updateWaiter(chnls.ptr, update);
    }
};

/// Defines the async message passing engine (ampe) interface.
/// In this system, ampe and engine mean the same thing.
///
/// Provides methods to:
/// - Manage the message pool.
/// - Create and destroy communication channels.
/// - Access to shared allocator used for memory management
/// within engine.
pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.AmpeVTable,

    /// Gets a message from the internal pool based on the allocation strategy.
    ///
    /// Returns null if the pool is empty and the strategy is poolOnly.
    ///
    /// Returns an error if the engine is shutting down or allocation fails.
    ///
    /// Safe for use in multiple threads.
    pub fn get(ampe: Ampe, strategy: AllocationStrategy) status.AmpeError!?*message.Message {
        return ampe.vtable.get(ampe.ptr, strategy);
    }

    /// Returns a message to the internal pool.
    /// If the pool is closed, destroys the message.
    ///
    /// Sets msg.* to null to prevent reuse.
    ///
    /// Safe for use in multiple threads.
    pub fn put(ampe: Ampe, msg: *?*message.Message) void {
        ampe.vtable.put(ampe.ptr, msg);
    }

    /// Creates new ChannelGroup.
    ///
    /// Call destroy on the result to stop communication and free memory.
    ///
    /// Safe for use in multiple threads.
    pub fn create(ampe: Ampe) status.AmpeError!ChannelGroup {
        return ampe.vtable.create(ampe.ptr);
    }

    /// Destroys ChannelGroup, stops communication, and frees memory.
    ///
    /// Safe for use in multiple threads.
    pub fn destroy(ampe: Ampe, chnls: ChannelGroup) status.AmpeError!void {
        return ampe.vtable.destroy(ampe.ptr, chnls.ptr);
    }

    /// Gets allocator used by engine for all memory management.
    ///
    /// Safe for use in multiple threads.
    pub fn getAllocator(ampe: Ampe) Allocator {
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
