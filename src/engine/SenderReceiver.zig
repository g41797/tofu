// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const SenderReceiver = @This();

prnt: *Distributor = undefined,
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

pub fn create(prnt: *Distributor, id: u32) !*SenderReceiver {
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

pub fn init(prnt: *Distributor, id: u32) SenderReceiver {
    const srs: SenderReceiver = .{
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
    const msg = try srs.prnt.pool.get(strategy);
    return msg;
}

pub fn put(ptr: ?*anyopaque, msg: *Message) void {
    const srs: *SenderReceiver = @alignCast(@ptrCast(ptr));
    srs.prnt.pool.put(msg);
    return;
}

pub fn asyncSend(ptr: ?*anyopaque, msg: *Message) !BinaryHeader {
    const vc = try msg.check_and_prepare();

    const srs: *SenderReceiver = @alignCast(@ptrCast(ptr));

    if ((msg.bhdr.channel_number != 0) and (!srs.prnt.acns.exists(msg.bhdr.channel_number))) {
        return AmpeError.InvalidChannelNumber;
    }

    var mID: ?MessageID = null;
    if (msg.bhdr.message_id != 0) {
        mID = msg.bhdr.message_id;
    }

    const ach = srs.prnt.acns.createChannel(mID, srs);

    msg.bhdr.channel_number = ach.chn;
    msg.bhdr.message_id = ach.mid;

    const priority: Notifier.MessagePriority = switch (vc) {
        .ByeSignal => .oobMsg,
        else => .regularMsg,
    };

    try srs.prnt.submitMsg(msg, vc, priority);

    return msg.bhdr;
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
pub const TextHeaderIterator = message.TextHeaderIterator;
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const VC = message.ValidCombination;

pub const Distributor = @import("Distributor.zig");

pub const engine = @import("../engine.zig");
pub const Options = engine.Options;
pub const Sr = engine.Sr;
pub const AllocationStrategy = engine.AllocationStrategy;

pub const status = @import("../status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;
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
