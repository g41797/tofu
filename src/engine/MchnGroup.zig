// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const MchnGroup = @This();

prnt: *Engine = undefined,
id: u32 = undefined,
allocator: Allocator = undefined,
msgs: MSGMailBox = undefined,
cmpl: ResetEvent = undefined,

pub fn mcg(grp: *MchnGroup) MessageChannelGroup {
    const result: MessageChannelGroup = .{
        .ptr = grp,
        .vtable = &.{
            .asyncSend = asyncSend,
            .waitReceive = waitReceive,
            .interruptWait = interruptWait,
        },
    };
    return result;
}

pub fn Create(prnt: *Engine, id: u32) AmpeError!*MchnGroup {
    const grp = prnt.allocator.create(MchnGroup) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer prnt.allocator.destroy(grp);
    grp.* = MchnGroup.init(prnt, id);
    return grp;
}

pub fn Destroy(grp: *MchnGroup) void {
    const gpa = grp.prnt.allocator;
    grp.deinit();
    gpa.destroy(grp);
}

fn init(prnt: *Engine, id: u32) MchnGroup {
    const grp: MchnGroup = .{
        .prnt = prnt,
        .id = id,
        .allocator = prnt.allocator,
        .msgs = .{},
        .cmpl = ResetEvent{},
    };

    return grp;
}

fn deinit(grp: *MchnGroup) void {
    var allocated = grp.msgs.close();
    while (allocated != null) {
        const next = allocated.?.next;
        grp.prnt.pool.put(allocated.?);
        allocated = next;
    }

    return;
}

pub fn asyncSend(ptr: ?*anyopaque, amsg: *?*Message) AmpeError!BinaryHeader {
    const msgopt = amsg.*;
    if (msgopt == null) {
        return AmpeError.NullMessage;
    }

    const sendMsg = msgopt.?;

    const vc = try sendMsg.check_and_prepare();

    const grp: *MchnGroup = @alignCast(@ptrCast(ptr));

    if (sendMsg.bhdr.channel_number != 0) {
        if (!grp.prnt.acns.exists(sendMsg.bhdr.channel_number)) {
            return AmpeError.InvalidChannelNumber;
        }
    } else {
        var proto = sendMsg.bhdr.proto;
        proto._internal = 0; // As sign of the "local" hello/welcome

        const ach = grp.prnt.acns.createChannel(sendMsg.bhdr.message_id, sendMsg.bhdr.proto, grp);
        sendMsg.bhdr.channel_number = ach.chn;
    }
    try grp.prnt.submitMsg(sendMsg, vc);

    amsg.* = null;

    return sendMsg.bhdr;
}

pub fn waitReceive(ptr: ?*anyopaque, timeout_ns: u64) AmpeError!?*Message {
    const grp: *MchnGroup = @alignCast(@ptrCast(ptr));
    const recvMsg: *Message = grp.msgs.receive(timeout_ns) catch |err| {
        switch (err) {
            error.Timeout => {
                return null;
            },
            error.Closed => {
                return AmpeError.ShutdownStarted;
            },
            error.Interrupted => {
                return grp.prnt.buildStatusSignal(.wait_interrupted);
            },
        }
    };

    return recvMsg;
}

pub fn interruptWait(ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!void {
    _ = msg;
    const grp: *MchnGroup = @alignCast(@ptrCast(ptr));
    grp.msgs.interrupt() catch {};
    return AmpeError.NotImplementedYet;
}

pub fn setReleaseCompleted(grp: *MchnGroup) void {
    grp.cmpl.set();
    return;
}

pub fn waitReleaseCompleted(grp: *MchnGroup) void {
    grp.cmpl.wait();
    return;
}

pub fn sendToWaiter(ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!void {
    if (msg.* == null) {
        return AmpeError.NullMessage;
    }
    const grp: *MchnGroup = @alignCast(@ptrCast(ptr));

    grp.msgs.send(msg.*.?) catch {
        return AmpeError.ShutdownStarted;
    };

    msg.* = null;
    return;
}

const tofu = @import("tofu");

pub const message = tofu.message;
pub const MessageType = message.MessageType;
pub const MessageRole = message.MessageRole;
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

pub const Engine = tofu.Engine;

const engine = tofu;
const MessageChannelGroup = engine.MessageChannelGroup;
const AllocationStrategy = engine.AllocationStrategy;
const AmpeError = tofu.status.AmpeError;

const Notifier = @import("Notifier.zig");
const ActiveChannels = @import("channels.zig").ActiveChannels;

const Appendable = @import("nats").Appendable;
const MSGMailBox = @import("mailbox").MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const ResetEvent = std.Thread.ResetEvent;
