// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

/// Defines the strategy for allocating messages from a pool.
pub const AllocationStrategy = enum {
    /// Attempts to allocate a message from the pool, returning null if the pool is empty.
    poolOnly,
    /// Allocates a message from the pool or creates a new one if the pool is empty.
    always,
};

/// Represents a sender-receiver interface for asynchronous message passing.
pub const Sr = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Retrieves a message from the internal pool based on the specified allocation strategy.
        /// The only error when the pool can still be used is `error.EmptyPool`.
        ///
        /// Thread-safe.
        get: *const fn (ptr: ?*anyopaque, strategy: AllocationStrategy) anyerror!*Message,

        /// Returns a message to the internal pool. If the pool is closed, destroys the message.
        ///
        /// Thread-safe.
        put: *const fn (ptr: ?*anyopaque, msg: *Message) void,

        /// Initiates an asynchronous send of a message to a peer.
        /// Returns a filled BinaryHeader as correlation information if the send is initiated successfully.
        /// Returns an error if the message is invalid.
        ///
        /// Thread-safe.
        asyncSend: *const fn (ptr: ?*anyopaque, msg: *Message) anyerror!BinaryHeader,

        /// Waits for a message on the internal queue.
        /// Returns null if no message is received within the specified timeout (in nanoseconds).
        /// The only error when it’s possible to continue calling this function is `error.Interrupted` (see `interruptWait`).
        ///
        /// Thread-safe. The idiomatic way is to call `waitReceive` in a loop within the same thread.
        waitReceive: *const fn (ptr: ?*anyopaque, timeout_ns: u64) anyerror!?*Message,

        /// Interrupts a `waitReceive` call, causing it to return `error.Interrupted`.
        /// If called before `waitReceive`, the next `waitReceive` call will be interrupted.
        /// No accumulation; only the last interrupt is saved.
        ///
        /// Thread-safe. The idiomatic way is to call this from a thread other than the one calling `waitReceive` to signal attention.
        interruptWait: *const fn (ptr: ?*anyopaque) void,
    };

    /// Retrieves a message from the internal pool based on the specified allocation strategy.
    /// The only error when the pool can still be used is `error.EmptyPool`.
    ///
    /// Thread-safe.
    pub fn get(sr: Sr, strategy: AllocationStrategy) anyerror!*Message {
        return sr.vtable.get(sr.ptr, strategy);
    }

    /// Returns a message to the internal pool. If the pool is closed, destroys the message.
    ///
    /// Thread-safe.
    pub fn put(sr: Sr, msg: *Message) void {
        sr.vtable.put(sr.ptr, msg);
    }

    /// Initiates an asynchronous send of a message to a peer.
    /// Returns a filled BinaryHeader as correlation information if the send is initiated successfully.
    /// Returns an error if the message is invalid.
    ///
    /// Thread-safe.
    pub fn asyncSend(sr: Sr, msg: *Message) anyerror!BinaryHeader {
        return sr.vtable.asyncSend(sr.ptr, msg);
    }

    /// Waits for a message on the internal queue.
    /// Returns null if no message is received within the specified timeout (in nanoseconds).
    /// The only error when it’s possible to continue calling this function is `error.Interrupted` (see `interruptWait`).
    ///
    /// Thread-safe. The idiomatic way is to call `waitReceive` in a loop within the same thread.
    pub fn waitReceive(sr: Sr, timeout_ns: u64) anyerror!?*Message {
        return sr.vtable.waitReceive(sr.ptr, timeout_ns);
    }

    /// Interrupts a `waitReceive` call, causing it to return `error.Interrupted`.
    /// If called before `waitReceive`, the next `waitReceive` call will be interrupted.
    /// No accumulation; only the last interrupt is saved.
    ///
    /// Thread-safe. The idiomatic way is to call this from a thread other than the one calling `waitReceive` to signal attention.
    pub fn interruptWait(sr: Sr) void {
        sr.vtable.interruptWait(sr.ptr);
    }
};

/// Represents an asynchronous message passing engine interface.
pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Creates a new sender-receiver.
        /// Call `destroy` on the result to stop communication and free associated memory.
        ///
        /// Thread-safe.
        create: *const fn (ptr: ?*anyopaque) anyerror!*Sr,

        /// Destroys a sender-receiver, stopping communication and freeing associated memory.
        ///
        /// Thread-safe.
        destroy: *const fn (ptr: ?*anyopaque, sr: *Sr) anyerror!void,
    };

    /// Creates a new sender-receiver.
    /// Call `destroy` on the result to stop communication and free associated memory.
    ///
    /// Thread-safe.
    pub fn create(ampe: Ampe) anyerror!*Sr {
        return ampe.vtable.create(ampe.ptr);
    }

    /// Destroys a sender-receiver, stopping communication and freeing associated memory.
    ///
    /// Thread-safe.
    pub fn destroy(ampe: Ampe, sr: *Sr) anyerror!void {
        return ampe.vtable.destroy(ampe.ptr, sr);
    }
};

pub const AMP = struct {
    impl: *const anyopaque = undefined,
    functions: *const AMPFunctions = undefined,
    allocator: Allocator = undefined,
    running: Atomic(bool) = undefined,
    shutdown_finished: Atomic(bool) = undefined,

    pub const AMPFunctions = struct {
        /// Initiates asynchronous send of Message to peer
        /// Returns errors (TBD) or filled BinaryHeader of the Message.
        start_send: *const fn (impl: *const anyopaque, msg: *Message) anyerror!BinaryHeader,

        /// Waits *Message on internal queue.
        /// If during timeout_ns message was not received, return null.
        wait_receive: *const fn (impl: *const anyopaque, timeout_ns: u64) anyerror!?*Message,

        /// Gets *Message from internal pool.
        /// If message is not available, allocates new and returns result (force == true) or null otherwice.
        /// If pool was closed, returns null
        get: *const fn (impl: *const anyopaque, force: bool) ?*Message,

        /// Returns *Message to internal pool.
        put: *const fn (impl: *const anyopaque, msg: *Message) void,

        /// Stop all activities/threads/io, release memory in internal pool
        shutdown: *const fn (impl: *const anyopaque) anyerror!void,
    };

    // Initiates asynchronous send of Message to peer
    // Returns errors (TBD) or filled BinaryHeader of the Message.
    pub fn start_send(amp: *AMP, msg: *Message) !BinaryHeader {
        if (!amp.running.load(.monotonic)) {
            return error.ShutdownStarted;
        }
        return try amp.functions.start_send(amp.impl, msg);
    }

    // Waits *Message on internal queue.
    // If during timeout_ns message was not received, return null.
    pub fn wait_receive(amp: *AMP, timeout_ns: u64) !?*Message {
        if (!amp.running.load(.monotonic)) {
            return error.ShutdownStarted;
        }
        return try amp.functions.wait_receive(amp.impl, timeout_ns);
    }

    // Gets *Message from internal pool.
    // If message is not available, allocates new and returns result (force == true) or null otherwice.
    // If pool was closed, returns null
    pub fn get(amp: *AMP, force: bool) ?*Message {
        if (!amp.running.load(.monotonic)) {
            return null;
        }
        return amp.functions.get(amp.impl, force);
    }

    // Returns *Message to internal pool.
    pub fn put(amp: *AMP, msg: *Message) void {
        if (!amp.running.load(.monotonic)) {
            msg.destroy();
            return;
        }
        return amp.functions.put(amp.impl, msg);
    }

    // Shutdown + free of amp memory
    pub fn destroy(amp: *AMP) !void {
        _ = try amp.shutdown();
        const allocator = amp.allocator;
        allocator.destroy(amp);
        return;
    }

    // Stop all activities/threads/io, release memory in internal pool
    fn shutdown(amp: *AMP) !void {
        amp.running.store(false, .release);
        if (amp.shutdown_finished.load(.monotonic)) {
            return;
        }

        defer amp.shutdown_finished.store(true, .release);

        try amp.functions.shutdown(amp.impl);

        return;
    }
};

pub const Options = struct {
    // Placeholder
};

pub fn start(allocator: Allocator, options: Options) !*AMP {
    const amp = try allocator.create(AMP);
    errdefer allocator.destroy(amp);

    var gt = try allocator.create(Gate);
    errdefer allocator.destroy(gt);
    gt.* = .{};

    try gt.init(allocator, options);

    amp.* = gt.amp();
    return amp;
}

pub const message = @import("message.zig");
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = @import("TextHeaderIterator.zig");
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const ChannelNumber = message.ChannelNumber;
pub const next_mid = Message.next_mid;
pub const Appendable = @import("nats").Appendable;

pub const status = @import("status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const Gate = @import("engine/Gate.zig");
const Pool = @import("engine/Pool.zig");

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
