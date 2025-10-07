// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

///////////////////////////////////////////////////////////////////////////
/// Terms client/server are used in tofu just for initial handshake.
/// After successful handshake, both sides (called 'peers') act as equals,
/// asynchronously sending/receiving messages per application logic.
///////////////////////////////////////////////////////////////////////////

/// Represents Channels interface for asynchronous message passing.
/// Supports asynchronous bi-directional exchange of messages.
pub const Channels = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.CHNLSVTable,

    /// Initiates an asynchronous send of a message to a peer.
    ///
    /// If the send is initiated successfully:
    ///     - sets msg.* to null in order to prevent further usage.
    ///     - returns a filled BinaryHeader as correlation information .
    /// If the message is invalid:
    ///     - returns an error
    ///
    /// Thread-safe.
    pub fn sendToPeer(chnls: Channels, msg: *?*message.Message) status.AmpeError!message.BinaryHeader {
        return chnls.vtable.sendToPeer(chnls.ptr, msg);
    }

    /// Waits for a message on the internal queue.
    ///
    /// Returns null if no message is received within
    /// the specified timeout (in nanoseconds).
    ///
    /// There are 3 senders of messages:
    /// - peer (via sendToPeer on the other side)
    /// - application (via updateWaiter on the same channels
    /// - engine (sends status messages to the same internal queue)
    ///
    /// You can differentiate source of the message using BinaryHeader.
    ///
    /// Idiomatic usage involves calling `waitReceive` in a loop
    /// within the same dispatch thread.
    ///
    /// Thread-safe.
    pub fn waitReceive(chnls: Channels, timeout_ns: u64) status.AmpeError!?*message.Message {
        return chnls.vtable.waitReceive(chnls.ptr, timeout_ns);
    }

    /// If msg.* != nul, sends msg.* to Channels' internal queue for further processing after waitReceive.
    /// engine automatically set status of the message to 'waiter_update'.
    /// For successful send, sets msg.* to null in order to prevent further usage.
    ///
    /// Because message is used for internal communication, you don't need to supply
    /// channel_number and similar information.
    ///
    /// If msg.* == nul, creates Signal with 'waiter_update' status and sends it to internal queue,
    ///
    /// Returns an error if Channels or engine in shutdown stage.
    ///
    /// Idiomatic usage involves calling from a different thread
    /// - to signal attention (msg.* == null)
    /// - to provide additional information/command/notification to waiter
    ///
    /// [Note] tofu does not support priorities in internal queues, update
    /// message will be added to the tail of the queue and processed as
    /// regular one.
    ///
    /// Thread-safe.
    pub fn updateWaiter(chnls: Channels, update: *?*message.Message) status.AmpeError!void {
        return chnls.vtable.updateWaiter(chnls.ptr, update);
    }
};

/// Represents an asynchronous message passing engine (ampe) interface.
///
/// In tofu terminology, ampe and engine are interchangeable terms.
///
/// Provides methods to
/// - manage pool of the messages
/// - create and destroy channels
pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const vtables.AmpeVTable,

    /// Retrieves a message from the internal pool based on the specified
    /// allocation strategy.
    ///
    /// Returns null if the pool is empty and the strategy is poolOnly.
    ///
    /// Returns an error during engine shutdown or if allocation failed.
    ///
    /// Thread-safe.
    pub fn get(ampe: Ampe, strategy: AllocationStrategy) status.AmpeError!?*message.Message {
        return ampe.vtable.get(ampe.ptr, strategy);
    }

    /// Returns a message to the internal pool.
    /// If the pool is closed, destroys the message.
    ///
    /// Sets msg.* to null for preventing further usage.
    ///
    /// Thread-safe.
    pub fn put(ampe: Ampe, msg: *?*message.Message) void {
        ampe.vtable.put(ampe.ptr, msg);
    }

    /// Creates a new Channels.
    ///
    /// Call `destroy` on the result to stop communication and free associated memory.
    ///
    /// Thread-safe.
    pub fn create(ampe: Ampe) status.AmpeError!Channels {
        return ampe.vtable.create(ampe.ptr);
    }

    /// Destroys Channels, stopping communication and freeing associated memory.
    ///
    /// Thread-safe.
    pub fn destroy(ampe: Ampe, chnls: Channels) status.AmpeError!void {
        return ampe.vtable.destroy(ampe.ptr, chnls.ptr);
    }
};

/// Defines the strategy for allocating messages from a pool.
pub const AllocationStrategy = enum {
    /// Attempts to allocate a message from the pool, returning null if the pool is empty.
    poolOnly,
    /// Allocates a message from the pool or creates a new one if the pool is empty.
    always,
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

const message = @import("message.zig");
const status = @import("status.zig");
const vtables = @import("ampe/vtables.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
