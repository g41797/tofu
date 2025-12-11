// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const MchnGroup = @This();

pub const GroupId = ?u32;

engine: *Reactor = undefined,
id: GroupId = null,
allocator: Allocator = undefined,
msgs: [2]MSGMailBox = undefined,
cmpl: Semaphore = undefined,

pub fn chnls(grp: *MchnGroup) ChannelGroup {
    const result: ChannelGroup = .{
        .ptr = grp,
        .vtable = &.{
            .enqueueToPeer = enqueueToPeer,
            .waitReceive = waitReceive,
            .updateWaiter = updateWaiter,
        },
    };
    return result;
}

pub fn Create(engine: *Reactor, id: ?u32) AmpeError!*MchnGroup {
    const grp = engine.allocator.create(MchnGroup) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer engine.allocator.destroy(grp);
    grp.* = MchnGroup.init(engine, id);
    return grp;
}

pub fn Destroy(grp: *MchnGroup) void {
    const gpa = grp.engine.allocator;
    grp.deinit();
    gpa.destroy(grp);
}

fn init(engine: *Reactor, id: ?u32) MchnGroup {
    const grp: MchnGroup = .{
        .engine = engine,
        .id = id,
        .allocator = engine.allocator,
        .msgs = .{ .{}, .{} },
        .cmpl = Semaphore{},
    };

    return grp;
}

fn deinit(grp: *MchnGroup) void {
    grp.cleanMboxes();
    return;
}

pub fn cleanMboxes(grp: *MchnGroup) void {
    for (0..2) |i| {
        var mbx = grp.msgs[i];
        var allocated = mbx.close();
        while (allocated != null) {
            const next = allocated.?.next;
            grp.engine.pool.put(allocated.?);
            allocated = next;
        }
    }
}

pub fn enqueueToPeer(ptr: ?*anyopaque, amsg: *?*Message) AmpeError!BinaryHeader {
    const msgopt = amsg.*;
    if (msgopt == null) {
        return AmpeError.NullMessage;
    }

    const sendMsg = msgopt.?;
    sendMsg.*.@"<ctx>" = ptr;

    const vc = try sendMsg.check_and_prepare();

    const grp: *MchnGroup = @alignCast(@ptrCast(ptr));

    var newChannelWasCreated: bool = false;

    if (sendMsg.bhdr.channel_number != 0) {
        try grp.engine.acns.check(sendMsg.bhdr.channel_number, ptr);
    } else {
        var proto = sendMsg.bhdr.proto;
        proto._internal = 0; // As sign of the "local" hello/welcome

        const ach = grp.engine.acns.createChannel(sendMsg.bhdr.message_id, sendMsg.bhdr.proto, grp);
        sendMsg.bhdr.channel_number = ach.chn;
        std.debug.assert(sendMsg.bhdr.channel_number != 0);
        newChannelWasCreated = true;
    }

    const ret: BinaryHeader = sendMsg.bhdr;

    grp.engine.submitMsg(sendMsg, vc) catch |err| {
        if (newChannelWasCreated) {
            // Called on caller thread
            grp.engine.acns.removeChannel(sendMsg.bhdr.channel_number);
        }

        if (err == AmpeError.NotificationFailed) {
            amsg.* = null;
        }

        return err;
    };

    amsg.* = null;

    return ret;
}

pub fn waitReceive(ptr: ?*anyopaque, timeout_ns: u64) AmpeError!?*Message {
    const grp: *MchnGroup = @alignCast(@ptrCast(ptr));
    const recvMsg: *Message = grp.msgs[1].receive(timeout_ns) catch |err| {
        switch (err) {
            error.Timeout => {
                return null;
            },
            error.Closed, error.Interrupted => {
                return AmpeError.ShutdownStarted;
            },
        }
    };

    if (recvMsg.*.bhdr.status != tofu.status.status_to_raw(.waiter_update)) {
        std.debug.assert(recvMsg.*.@"<ctx>" != null);
    }

    recvMsg.*.@"<ctx>" = null;
    return recvMsg;
}

pub fn updateWaiter(ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!void {
    const grp: *MchnGroup = @alignCast(@ptrCast(ptr));

    if (msg.* == null) {
        const updateSignal: *Message = grp.engine.buildStatusSignal(.waiter_update);
        grp.msgs[1].send(updateSignal) catch {
            grp.engine.pool.put(updateSignal);
            return AmpeError.ShutdownStarted;
        };
        return;
    }

    msg.*.?.bhdr.proto.origin = .application;
    msg.*.?.bhdr.status = tofu.status.status_to_raw(.waiter_update);
    msg.*.?.@"<ctx>" = null;

    grp.msgs[1].send(msg.*.?) catch {
        return AmpeError.ShutdownStarted;
    };
    msg.* = null;

    return;
}

pub inline fn setCmdCompleted(grp: *MchnGroup) void {
    grp.cmpl.post();
    return;
}

pub inline fn waitCmdCompleted(grp: *MchnGroup) void {
    grp.cmpl.timedWait(tofu.waitReceive_INFINITE_TIMEOUT) catch {
        // log.warn("waitCmdCompleted timeout group {*} gid {d}", .{ grp, grp.*.id.? });
        return;
    };
    return;
}

pub inline fn resetCmdCompleted(_: *MchnGroup) void {
    return;
}

pub fn sendToWaiter(ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!void {
    if (msg.* == null) {
        return AmpeError.NullMessage;
    }
    const grp: *MchnGroup = @alignCast(@ptrCast(ptr));

    grp.msgs[1].send(msg.*.?) catch {
        return AmpeError.ShutdownStarted;
    };

    msg.* = null;
    return;
}

const tofu = @import("../tofu.zig");

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

pub const Reactor = tofu.Reactor;

const ChannelGroup = tofu.ChannelGroup;
const AllocationStrategy = tofu.AllocationStrategy;
const AmpeError = tofu.status.AmpeError;
const AmpeStatus = tofu.status.AmpeStatus;

const Notifier = @import("Notifier.zig");
const ActiveChannels = @import("channels.zig").ActiveChannels;

const Appendable = @import("nats").Appendable;
const MSGMailBox = @import("mailbox").MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Semaphore = std.Thread.Semaphore;
const ResetEvent = std.Thread.ResetEvent;
const log = std.log;
