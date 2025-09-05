// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Gate = @This();

prnt: *Distributor = undefined,
id: u32 = undefined,
allocator: Allocator = undefined,
msgs: MSGMailBox = undefined,

pub fn mcg(gt: *Gate) MessageChannelGroup {
    const result: MessageChannelGroup = .{
        .ptr = gt,
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

pub fn Create(prnt: *Distributor, id: u32) AmpeError!*Gate {
    const gt = prnt.allocator.create(Gate) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer prnt.allocator.destroy(gt);
    gt.* = Gate.init(prnt, id);
    return gt;
}

pub fn Destroy(gt: *Gate) void {
    const gpa = gt.prnt.allocator;
    gt.deinit();
    gpa.destroy(gt);
}

fn init(prnt: *Distributor, id: u32) Gate {
    const gt: Gate = .{
        .prnt = prnt,
        .id = id,
        .allocator = prnt.allocator,
        .msgs = .{},
    };

    return gt;
}

fn deinit(gt: *Gate) void {
    _ = gt.prnt.acns.removeChannels(gt) catch unreachable;

    var allocated = gt.msgs.close();
    while (allocated != null) {
        const next = allocated.?.next;
        allocated.?.destroy();
        allocated = next;
    }

    return;
}

pub fn get(ptr: ?*anyopaque, strategy: AllocationStrategy) AmpeError!*Message {
    const gt: *Gate = @alignCast(@ptrCast(ptr));
    const msg = try gt.prnt.pool.get(strategy);
    return msg;
}

pub fn put(ptr: ?*anyopaque, msg: *Message) void {
    const gt: *Gate = @alignCast(@ptrCast(ptr));
    gt.prnt.pool.put(msg);
    return;
}

pub fn asyncSend(ptr: ?*anyopaque, msg: *Message) AmpeError!BinaryHeader {
    const vc = try msg.check_and_prepare();

    const gt: *Gate = @alignCast(@ptrCast(ptr));

    if ((msg.bhdr.channel_number != 0) and (!gt.prnt.acns.exists(msg.bhdr.channel_number))) {
        return AmpeError.InvalidChannelNumber;
    }

    var mID: ?MessageID = null;
    if (msg.bhdr.message_id != 0) {
        mID = msg.bhdr.message_id;
    }

    const ach = gt.prnt.acns.createChannel(mID, gt);

    msg.bhdr.channel_number = ach.chn;
    msg.bhdr.message_id = ach.mid;

    try gt.prnt.submitMsg(msg, vc, msg.bhdr.proto.oob);

    return msg.bhdr;
}

pub fn waitReceive(ptr: ?*anyopaque, timeout_ns: u64) AmpeError!?*Message {
    const gt: *Gate = @alignCast(@ptrCast(ptr));
    _ = gt;
    _ = timeout_ns;
    return error.NotImplementedYet;
}

pub fn interruptWait(ptr: ?*anyopaque) void {
    const gt: *Gate = @alignCast(@ptrCast(ptr));
    _ = gt;
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

const engine = @import("../engine.zig");
const MessageChannelGroup = engine.MessageChannelGroup;
const AllocationStrategy = engine.AllocationStrategy;

const AmpeError = @import("../status.zig").AmpeError;
const Notifier = @import("Notifier.zig");
const ActiveChannels = @import("channels.zig").ActiveChannels;
const Appendable = @import("nats").Appendable;
const MSGMailBox = @import("mailbox").MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
