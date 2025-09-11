// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

/// Represents an asynchronous message passing engine interface.
/// Provides methods to acquire and release message channel groups for communication.
pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.AmpeVTable,

    /// Acquires a new message channel group.
    /// Call `release` on the result to stop communication and free associated memory.
    /// Thread-safe.
    pub fn acquire(ampe: Ampe) status.AmpeError!MessageChannelGroup {
        return ampe.vtable.acquire(ampe.ptr);
    }

    /// Releases a message channel group, stopping communication and freeing associated memory.
    /// Thread-safe.
    pub fn release(ampe: Ampe, mcg: MessageChannelGroup) status.AmpeError!void {
        return ampe.vtable.release(ampe.ptr, mcg.ptr);
    }
};

/// Defines the strategy for allocating messages from a pool.
pub const AllocationStrategy = enum {
    /// Attempts to allocate a message from the pool, returning null if the pool is empty.
    poolOnly,
    /// Allocates a message from the pool or creates a new one if the pool is empty.
    always,
};

/// Represents a message channel group interface for asynchronous message passing.
/// Supports asynchronous bi-directional exchange of messages.
/// Acts as a client to the Ampe engine.
pub const MessageChannelGroup = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.MCGVTable,

    /// Retrieves a message from the internal pool based on the specified allocation strategy.
    /// Returns מוךך if the pool is empty and the strategy is poolOnly.
    /// Returns an error during mcg release or if allocation failed.
    /// Thread-safe.
    pub fn get(mcg: MessageChannelGroup, strategy: AllocationStrategy) status.AmpeError!?*message.Message {
        return mcg.vtable.get(mcg.ptr, strategy);
    }

    /// Returns a message to the internal pool. If the pool is closed, destroys the message.
    /// Sets msg to null for preventing further usage.
    /// For safe destroying - use message.DestroySendMsg(msg),
    /// where msg: *?*message.Message (see  asyncSend comment).
    /// Thread-safe.
    pub fn put(mcg: MessageChannelGroup, msg: *?*message.Message) void {
        mcg.vtable.put(mcg.ptr, msg);
    }

    /// Initiates an asynchronous send of a message to a peer.
    /// If the send is initiated successfully:
    ///     - set msg.* to null in order to prevent wrong message destroy/put.
    ///     - returns a filled BinaryHeader as correlation information .
    /// If the message is invalid:
    ///     - returns an error
    ///
    /// Idiomatic way of handling send messages:
    ///
    ///     var msg: ?*Message = try mcg.get(tofu.AllocationStrategy.poolOnly);
    ///
    ///     If was send - nothing,
    ///     if was not - message will be returned to the pool
    ///     defer mcg.put(&msg);
    ///     ..................
    ///     ..................
    ///     const bh  = mcg.asyncSend(&msg);
    ///
    /// Thread-safe.
    pub fn asyncSend(mcg: MessageChannelGroup, msg: *?*message.Message) status.AmpeError!message.BinaryHeader {
        return mcg.vtable.asyncSend(mcg.ptr, msg);
    }

    /// Waits for a message on the internal queue.
    /// Returns null if no message is received within the specified timeout (in nanoseconds).
    /// May receive signals from the engine, such as Bye (peer disconnected), Status 'wait_interrupted',
    /// or Status 'pool_empty' (indicating no free messages for receive).
    /// Idiomatic usage involves calling `waitReceive` in a loop within the same thread.
    /// Thread-safe.
    pub fn waitReceive(mcg: MessageChannelGroup, timeout_ns: u64) status.AmpeError!?*message.Message {
        return mcg.vtable.waitReceive(mcg.ptr, timeout_ns);
    }

    /// Interrupts a `waitReceive` call, causing it to return a Status Signal with 'wait_interrupted' status.
    /// If called before `waitReceive`, the next `waitReceive` call will be interrupted.
    /// Only the last interrupt is saved; no accumulation.
    /// Idiomatic usage involves calling from a different thread to signal attention.
    /// Thread-safe.
    pub fn interruptWait(mcg: MessageChannelGroup) void {
        mcg.vtable.interruptWait(mcg.ptr);
    }
};

/// Structure for holding configuration options for the message passing engine.
pub const Options = struct {
    initialPoolMsgs: ?u16 = null,
    maxPoolMsgs: ?u16 = null,
};

pub const DefaultOptions: Options = .{
    .initialPoolMsgs = 16,
    .maxPoolMsgs = 64,
};

pub const DBG = (@import("builtin").mode == .Debug);

pub const engine = @This();

pub const configurator = @import("configurator.zig");
pub const message = @import("message.zig");
pub const status = @import("status.zig");

pub const channels = @import("engine/channels.zig");
pub const Distributor = @import("engine/Distributor.zig");
pub const Notifier = @import("engine/Notifier.zig");
pub const Pool = @import("engine/Pool.zig");
pub const poller = @import("engine/poller.zig");
pub const sockets = @import("engine/sockets.zig");

const vtables = @import("engine/vtables.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
