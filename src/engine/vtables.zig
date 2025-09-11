// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const AmpeVTable = struct {
    /// Acquires a new message channel group.
    /// Call `release` on the result to stop communication and free associated memory.
    ///
    /// Thread-safe.
    acquire: *const fn (ptr: ?*anyopaque) AmpeError!engine.MessageChannelGroup,

    /// Releases a message channel group, stopping communication and freeing associated memory.
    ///
    /// Thread-safe.
    release: *const fn (ptr: ?*anyopaque, mcgimpl: ?*anyopaque) AmpeError!void,
};

pub const MCGVTable = struct {
    /// Retrieves a message from the internal pool based on the specified allocation strategy.
    ///
    /// Thread-safe.
    get: *const fn (ptr: ?*anyopaque, strategy: engine.AllocationStrategy) AmpeError!?*message.Message,

    /// Returns a message to the internal pool. If the pool is closed, destroys the message.
    ///
    /// Thread-safe.
    put: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) void,

    /// Initiates an asynchronous send of a message to a peer.
    /// Returns a filled BinaryHeader as correlation information if the send is initiated successfully.
    /// Returns an error if the message is invalid.
    ///
    /// Thread-safe.
    asyncSend: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!message.BinaryHeader,

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
    waitReceive: *const fn (ptr: ?*anyopaque, timeout_ns: u64) AmpeError!?*message.Message,

    /// Interrupts a `waitReceive` call, causing it to return Status Signal with 'wait_interrupted' status.
    /// If called before `waitReceive`, the next `waitReceive` call will be interrupted.
    /// No accumulation; only the last interrupt is saved.
    ///
    /// Thread-safe. The idiomatic way is to call this from a thread other
    /// than the one calling `waitReceive` to signal attention.
    interruptWait: *const fn (ptr: ?*anyopaque) void,
};

pub const engine = @import("../engine.zig");
pub const message = @import("../message.zig");
pub const status = @import("../status.zig");
pub const AmpeError = status.AmpeError;
