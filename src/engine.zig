// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

/// Defines the strategy for allocating messages from a pool.
pub const AllocationStrategy = enum {
    /// Attempts to allocate a message from the pool, returning null if the pool is empty.
    poolOnly,
    /// Allocates a message from the pool or creates a new one if the pool is empty.
    always,
};

/// Represents a full duplex message pipe interface for asynchronous message passing.
/// Supports asynchronous bi-directional exchange of the messages.
pub const Fdmp = struct {
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
        ///
        /// Also may be received following Signals from engine itself:
        /// - Bye - peer disconnected
        /// - Status 'wait_interrupted' - see interruptWait call
        /// - Status 'pool_empty' - there are not free messages for receive.
        ///   Allocate and 'put' messages to the pool, at least received status.
        ///
        /// Thread-safe. The idiomatic way is to call `waitReceive` in a loop within the same thread.
        waitReceive: *const fn (ptr: ?*anyopaque, timeout_ns: u64) anyerror!?*Message,

        /// Interrupts a `waitReceive` call, causing it to return Status Signal with 'wait_interrupted' status.
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
    pub fn get(fdmp: Fdmp, strategy: AllocationStrategy) anyerror!*Message {
        return fdmp.vtable.get(fdmp.ptr, strategy);
    }

    /// Returns a message to the internal pool. If the pool is closed, destroys the message.
    ///
    /// Thread-safe.
    pub fn put(fdmp: Fdmp, msg: *Message) void {
        fdmp.vtable.put(fdmp.ptr, msg);
    }

    /// Initiates an asynchronous send of a message to a peer.
    /// Returns a filled BinaryHeader as correlation information if the send is initiated successfully.
    /// Returns an error if the message is invalid.
    ///
    /// Thread-safe.
    pub fn asyncSend(fdmp: Fdmp, msg: *Message) anyerror!BinaryHeader {
        return fdmp.vtable.asyncSend(fdmp.ptr, msg);
    }

    /// Waits for a message on the internal queue.
    /// Returns null if no message is received within the specified timeout (in nanoseconds).
    ///
    /// Also may be received following Signals from engine itself:
    /// - Bye - peer disconnected
    /// - Status 'wait_interrupted' - see interruptWait call
    /// - Status 'pool_empty' - there are not free messages for receive.
    ///  Allocate and 'put' messages to the pool, at least received status.
    ///
    /// Thread-safe. The idiomatic way is to call `waitReceive` in a loop within the same thread.
    pub fn waitReceive(fdmp: Fdmp, timeout_ns: u64) anyerror!?*Message {
        return fdmp.vtable.waitReceive(fdmp.ptr, timeout_ns);
    }

    /// Interrupts a `waitReceive` call, causing it to return Status Signal with 'wait_interrupted' status.
    /// If called before `waitReceive`, the next `waitReceive` call will be interrupted.
    /// No accumulation; only the last interrupt is saved.
    ///
    /// Thread-safe. The idiomatic way is to call this from a thread other than the one calling `waitReceive` to signal attention.
    pub fn interruptWait(fdmp: Fdmp) void {
        fdmp.vtable.interruptWait(fdmp.ptr);
    }
};

/// Represents an asynchronous message passing engine interface.
pub const Ampe = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Creates a new full duplex message pipe.
        /// Call `destroy` on the result to stop communication and free associated memory.
        ///
        /// Thread-safe.
        create: *const fn (ptr: ?*anyopaque) anyerror!*Fdmp,

        /// Destroys a full duplex message pipe, stopping communication and freeing associated memory.
        ///
        /// Thread-safe.
        destroy: *const fn (ptr: ?*anyopaque, fdmp: *Fdmp) anyerror!void,
    };

    /// Creates a new full duplex message pipe.
    /// Call `destroy` on the result to stop communication and free associated memory.
    ///
    /// Thread-safe.
    pub fn create(ampe: Ampe) anyerror!*Fdmp {
        return ampe.vtable.create(ampe.ptr);
    }

    /// Destroys a full duplex message pipe, stopping communication and freeing associated memory.
    ///
    /// Thread-safe.
    pub fn destroy(ampe: Ampe, fdmp: *Fdmp) anyerror!void {
        return ampe.vtable.destroy(ampe.ptr, fdmp);
    }
};

pub const Options = struct {
    // 2DO - add pool options
};

pub const message = @import("message.zig");
pub const Message = message.Message;

pub const BinaryHeader = message.BinaryHeader;
pub const ProtoFields = message.ProtoFields;
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const MessageID = message.MessageID;
pub const ChannelNumber = message.ChannelNumber;

pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = message.TextHeaderIterator;
pub const TextHeaders = message.TextHeaders;

pub const Appendable = @import("nats").Appendable;

pub const status = @import("status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

pub const Distributor = @import("engine/Distributor.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DBG = (@import("builtin").mode == .Debug);
