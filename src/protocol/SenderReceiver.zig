// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const SenderReceiver = @This();

mutex: Mutex = undefined,
prnt: *Poller = undefined,
id: u32 = undefined,
allocator: Allocator = undefined,
msgs: MSGMailBox = undefined,

pub fn sr(srs: *SenderReceiver) Sr {
    const result: Sr = .{
        .ptr = srs,
        .vtable = &.{
            .get = get,
            .put = put,
            .asyncSend = asyncSend,
            .waitReceive = waitReceive,
            .interruptWait = interruptWait,
        },
    };
    return result;
}

pub fn create(prnt: *Poller, id: u32) !*SenderReceiver {
    const srs = try prnt.allocator.create(SenderReceiver);
    errdefer prnt.allocator.destroy(srs);
    srs.* = SenderReceiver.init(prnt, id);
    return srs;
}

pub fn destroy(srs: *SenderReceiver) void {
    const gpa = srs.prnt.allocator;
    srs.deinit();
    gpa.destroy(srs);
}

pub fn init(prnt: *Poller, id: u32) SenderReceiver {
    const srs: SenderReceiver = .{
        .mutex = .{},
        .prnt = prnt,
        .id = id,
        .allocator = prnt.allocator,
        .msgs = .{},
    };

    return srs;
}

pub fn deinit(srs: *SenderReceiver) void {
    _ = srs.prnt.acns.removeChannels(srs) catch unreachable;

    var allocated = srs.msgs.close();
    while (allocated != null) {
        const next = allocated.?.next;
        allocated.?.destroy();
        allocated = next;
    }

    return;
}

pub fn get(ptr: ?*anyopaque, strategy: AllocationStrategy) !*Message {
    const srs: *SenderReceiver = @alignCast(@ptrCast(ptr));
    _ = srs;
    _ = strategy;
    return error.NotImplementedYet;
}

pub fn put(ptr: ?*anyopaque, msg: *Message) void {
    const srs: *SenderReceiver = @alignCast(@ptrCast(ptr));
    _ = srs;
    _ = msg;
    return;
}

pub fn asyncSend(ptr: ?*anyopaque, msg: *Message) !BinaryHeader {
    const srs: *SenderReceiver = @alignCast(@ptrCast(ptr));
    _ = srs;
    _ = msg;
    return error.NotImplementedYet;
}

pub fn waitReceive(ptr: ?*anyopaque, timeout_ns: u64) !?*Message {
    const srs: *SenderReceiver = @alignCast(@ptrCast(ptr));
    _ = srs;
    _ = timeout_ns;
    return error.NotImplementedYet;
}

pub fn interruptWait(ptr: ?*anyopaque) void {
    const srs: *SenderReceiver = @alignCast(@ptrCast(ptr));
    _ = srs;
    return;
}

pub const message = @import("../message.zig");
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = @import("../TextHeaderIterator.zig");
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const VC = message.ValidCombination;

pub const Poller = @import("Poller.zig");

pub const protocol = @import("../protocol.zig");
pub const Options = protocol.Options;
pub const Sr = protocol.Sr;
pub const AllocationStrategy = protocol.AllocationStrategy;

pub const status = @import("../status.zig");
pub const AMPStatus = status.AMPStatus;
pub const AMPError = status.AMPError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const Pool = @import("Pool.zig");
const Notifier = @import("Notifier.zig");

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

pub const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
pub const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
