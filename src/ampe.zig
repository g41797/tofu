// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

/// Represents an asynchronous message passing ampe interface.
/// Provides methods to
/// - manage pool of the messages
/// - create and destroy message channel groups
pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.AmpeVTable,

    /// Retrieves a message from the internal pool based on the specified allocation strategy.
    /// Returns null if the pool is empty and the strategy is poolOnly.
    /// Returns an error during ampe shutdown or if allocation failed.
    /// Thread-safe.
    pub fn get(ampe: Ampe, strategy: AllocationStrategy) status.AmpeError!?*message.Message {
        return ampe.vtable.get(ampe.ptr, strategy);
    }

    /// Returns a message to the internal pool. If the pool is closed, destroys the message.
    /// Sets msg to null for preventing further usage.
    /// For safe destroying - use message.DestroySendMsg(msg),
    /// where msg: *?*message.Message (see  asyncSend comment in MessageChannelGroup).
    /// Thread-safe.
    pub fn put(ampe: Ampe, msg: *?*message.Message) void {
        ampe.vtable.put(ampe.ptr, msg);
    }

    /// Creates a new message channel group.
    /// Call `destroy` on the result to stop communication and free associated memory.
    /// Thread-safe.
    pub fn create(ampe: Ampe) status.AmpeError!MessageChannelGroup {
        return ampe.vtable.create(ampe.ptr);
    }

    /// Destroys a message channel group, stopping communication and freeing associated memory.
    /// Thread-safe.
    pub fn destroy(ampe: Ampe, mcg: MessageChannelGroup) status.AmpeError!void {
        return ampe.vtable.destroy(ampe.ptr, mcg.ptr);
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
/// Acts as a client to the Ampe ampe.
pub const MessageChannelGroup = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.MCGVTable,

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
    ///     defer ampe.put(&msg);
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
    ///
    /// May receive messages from the ampe, such as Bye ('peer disconnected'), Signal ('wait_interrupted'),
    /// or Signal ('pool_empty') (indicating no free messages for receive).
    ///
    /// Application also may send message via interruptWait.
    /// In this case the status of this message will be set to 'wait_interrupted'.
    ///
    /// Idiomatic usage involves calling `waitReceive` in a loop within the same dispatch thread.
    ///
    /// Thread-safe.
    pub fn waitReceive(mcg: MessageChannelGroup, timeout_ns: u64) status.AmpeError!?*message.Message {
        return mcg.vtable.waitReceive(mcg.ptr, timeout_ns);
    }

    /// Interrupts a `waitReceive` call with possibility transmit message to the waiter thread.
    ///
    /// If msg.* == nul, 'waitReceive" will return a Signal with 'wait_interrupted' status.
    /// If msg.* != nul, 'waitReceive" will return the message with 'wait_interrupted' status.
    ///
    /// If called before `waitReceive`, the next `waitReceive` call will be interrupted.
    /// Only the last interrupt is saved; no accumulation.
    ///
    /// Idiomatic usage involves calling from a different thread to signal attention.
    ///
    /// Thread-safe.
    pub fn interruptWait(mcg: MessageChannelGroup, msg: *?*message.Message) status.AmpeError!void {
        mcg.vtable.interruptWait(mcg.ptr, msg);
    }
};

/// Structure for holding configuration options for the message passing ampe.
pub const Options = struct {
    initialPoolMsgs: ?u16 = null,
    maxPoolMsgs: ?u16 = null,
};

pub const DefaultOptions: Options = .{
    .initialPoolMsgs = 16,
    .maxPoolMsgs = 64,
};

pub const DBG = (@import("builtin").mode == .Debug);

const message = @import("message.zig");
const status = @import("status.zig");
const vtables = @import("ampe/vtables.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
