// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Gate = @This();

allocator: Allocator = undefined,
options: protocol.Options = undefined,
pool: Pool = undefined,
acns: ActiveChannels = undefined,
msgs: MSGMailBox = undefined,
mutex: Mutex = undefined,

pub fn init(gt: *Gate, allocator: Allocator, options: Options) !void {
    gt.allocator = allocator;
    gt.options = options;
    gt.pool = try Pool.init(gt.allocator);
    gt.acns = try ActiveChannels.init(allocator, 255);
    gt.msgs = .{};
    gt.mutex = .{};
    return;
}

pub fn amp(gt: *Gate) AMP {
    const result: AMP = .{
        .impl = gt,
        .functions = &.{
            .start_send = start_send,
            .wait_receive = wait_receive,
            .shutdown = shutdown,
            .get = get,
            .put = put,
        },
        .allocator = gt.allocator,
        .running = Atomic(bool).init(true),
        .shutdown_finished = Atomic(bool).init(false),
    };
    return result;
}

pub fn start_send(impl: *const anyopaque, msg: *Message) !BinaryHeader {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    return gt._start_send(msg);
}

pub fn wait_receive(impl: *const anyopaque, timeout_ns: u64) anyerror!?*Message {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    return gt._wait_receive(timeout_ns);
}

pub fn get(impl: *const anyopaque, force: bool) ?*Message {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    return gt._get(force);
}

pub fn put(impl: *const anyopaque, msg: *Message) void {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    return gt._put(msg);
}

pub fn shutdown(impl: *const anyopaque) !void {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    var allocator = gt.allocator;
    gt.deinit();
    allocator.destroy(gt);
    return;
}

inline fn _start_send(gt: *Gate, msg: *Message) !BinaryHeader {
    _ = gt;
    _ = msg;
    return .{};
}

inline fn _wait_receive(gt: *Gate, timeout_ns: u64) !?*Message {
    _ = gt;
    _ = timeout_ns;
    return null;
}

inline fn _get(gt: *Gate, force: bool) ?*Message {
    return gt.pool.get(force);
}

inline fn _put(gt: *Gate, msg: *Message) void {
    gt.pool.put(msg);

    return;
}

fn deinit(gt: *Gate) void {
    gt.pool.close();
    gt.acns.deinit();

    var allocated = gt.msgs.close();
    while (allocated != null) {
        const next = allocated.?.next;
        allocated.?.destroy();
        allocated = next;
    }

    return;
}

pub fn freeMsg(msg: *Message) void {
    // The same allocator was used for creation of Message and it's fields
    const allocator = msg.thdrs.buffer.allocator;
    msg.deinit();
    allocator.destroy(msg);
    return;
}

pub const protocol = @import("../protocol.zig");
pub const TextHeaderIterator = @import("../TextHeaderIterator.zig");

const AMP = protocol.AMP;
const Options = protocol.Options;
const Message = protocol.Message;
const BinaryHeader = protocol.BinaryHeader;
const ChannelNumber = protocol.ChannelNumber;
const MessageID = protocol.MessageID;

pub const status = @import("../status.zig");
pub const AMPStatus = status.AMPStatus;
pub const AMPError = status.AMPError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const Pool = @import("Pool.zig");
const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

pub const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
pub const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
