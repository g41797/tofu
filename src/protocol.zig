// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

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
pub const AMPStatus = status.AMPStatus;
pub const AMPError = status.AMPError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const Gate = @import("protocol/Gate.zig");
const Pool = @import("protocol/Pool.zig");

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
