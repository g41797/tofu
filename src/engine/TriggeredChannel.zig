// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const TriggeredChannel = @This();

prnt: *Engine = undefined,
acn: channels.ActiveChannel = undefined,
resp2ac: bool = undefined,
tskt: TriggeredSkt = undefined,
exp: sockets.Triggers = undefined,
act: sockets.Triggers = undefined,
mrk4del: bool = undefined,
st: ?AmpeStatus = undefined,

pub fn createDumbChannel(prnt: *Engine) TriggeredChannel {
    const ret: TriggeredChannel = .{
        .prnt = prnt,
        .acn = .{
            .chn = 0,
            .mid = 0,
            .ctx = null,
        },
        .tskt = .{
            .dumb = .{},
        },
        .exp = sockets.TriggersOff,
        .act = sockets.TriggersOff,
        .mrk4del = true,
        .resp2ac = true,
        .st = null,
    };
    return ret;
}

pub fn createNotificationChannel(prnt: *Engine) !void {
    var ntcn = createDumbChannel(prnt);
    ntcn.resp2ac = true;
    ntcn.tskt = .{
        .notification = sockets.NotificationSkt.init(prnt.ntfr.receiver),
    };

    try prnt.addChannel(ntcn);

    prnt.ntfcsEnabled = true;

    return;
}

pub fn createIoClientChannel(eng: *Engine) AmpeError!void {
    const hello: *Message = eng.currMsg.?;

    var tc = createDumbChannel(eng);
    tc.acn = eng.*.acns.activeChannel(hello.bhdr.channel_number) catch unreachable;

    try eng.addChannel(tc);

    var sc: sockets.SocketCreator = sockets.SocketCreator.init(eng.allocator);
    var clSkt: sockets.IoSkt = .{};
    errdefer clSkt.deinit();

    try clSkt.initClientSide(&eng.pool, hello, &sc);
    eng.currMsg = null;

    const tcptr = eng.trgrd_map.getPtr(hello.bhdr.channel_number).?;
    tcptr.disableDelete();
    tcptr.*.resp2ac = true;

    const tskt: TriggeredSkt = .{
        .io = clSkt,
    };
    tcptr.*.tskt = tskt;

    return;
}

pub fn createAcceptChannel(eng: *Engine) AmpeError!void {
    const welcome: *Message = eng.currMsg.?;

    var tc = createDumbChannel(eng);
    tc.acn = eng.*.acns.activeChannel(welcome.bhdr.channel_number) catch unreachable;

    try eng.addChannel(tc);

    var sc: sockets.SocketCreator = sockets.SocketCreator.init(eng.allocator);
    var accSkt: sockets.AcceptSkt = .{};
    errdefer accSkt.deinit();

    accSkt = try sockets.AcceptSkt.init(welcome, &sc);

    const tcptr = eng.trgrd_map.getPtr(welcome.bhdr.channel_number).?;
    tcptr.disableDelete();
    tcptr.*.resp2ac = true;

    const tskt: TriggeredSkt = .{
        .accept = accSkt,
    };
    tcptr.*.tskt = tskt;

    // Listener started, so we can send succ. status to the caller.
    if (tcptr.*.acn.intr.?.role == .request) {
        eng.currMsg.?.bhdr.proto.role = .response;
        eng.currMsg.?.bhdr.status = 0;
        tcptr.sendToCtx(&eng.currMsg);
    }

    return;
}

pub fn deinit(tchn: *TriggeredChannel) void {
    defer tchn.remove();

    if (tchn.acn.chn != 0) {
        _ = tchn.prnt.acns.removeChannel(tchn.acn.chn);

        const exists = tchn.prnt.trgrd_map.contains(tchn.acn.chn);
        if (exists) {
            tchn.prnt.cnmapChanged = true;
        }
    }

    defer tchn.tskt.deinit();

    if ((tchn.acn.ctx == null) or (tchn.resp2ac == false)) {
        return;
    }

    var mq = tchn.tskt.detach();
    var next = mq.dequeue();
    const st = if (tchn.st != null) status.status_to_raw(tchn.st.?) else status.status_to_raw(.channel_closed);
    while (next != null) {
        next.?.bhdr.proto.origin = .engine;
        next.?.bhdr.status = st;
        tchn.sendToCtx(&next);
        next = mq.dequeue();
    }

    var statusMsg = tchn.prnt.buildStatusSignal(.channel_closed);

    statusMsg.bhdr.channel_number = tchn.acn.chn;
    statusMsg.bhdr.message_id = tchn.acn.mid;

    // 2DO Move processing of intr to another place
    // switch (tchn.acn.intr.?) {
    //     .WelcomeRequest => {}, // Accept skt
    //     .WelcomeSignal => {}, // Accept skt
    //     .HelloRequest => {}, // IO skt client
    //     .HelloSignal => {}, // IO skt client
    //     else => {}, // IO skt server
    // }

    var responseToCtx: ?*Message = statusMsg;

    tchn.sendToCtx(&responseToCtx);

    return;
}

pub fn sendToCtx(tchn: *TriggeredChannel, storedMsg: *?*Message) void {
    if (storedMsg.* == null) {
        return;
    }

    defer tchn.prnt.releaseToPool(storedMsg);

    if ((tchn.acn.ctx == null) or (tchn.resp2ac == false)) {
        return;
    }

    MchnGroup.sendToWaiter(tchn.acn.ctx.?, storedMsg) catch {};

    return;
}

inline fn remove(tchn: *TriggeredChannel) void {
    if (tchn.acn.chn != 0) {
        const prnt = tchn.prnt;
        const wasRemoved = tchn.prnt.trgrd_map.orderedRemove(tchn.acn.chn);
        if (wasRemoved) {
            prnt.cnmapChanged = true;
        }
    }
}

pub inline fn markForDelete(tchn: *TriggeredChannel, reason: AmpeStatus) void {
    tchn.mrk4del = true;
    tchn.st = reason;
}

pub inline fn disableDelete(tchn: *TriggeredChannel) void {
    tchn.mrk4del = false;
    tchn.st = null;
}

const tofu = @import("tofu");

const Engine = tofu.Engine;

const configurator = tofu.configurator;
const Configurator = configurator.Configurator;

const message = tofu.message;
const MessageType = message.MessageType;
const MessageRole = message.MessageRole;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = message.TextHeaderIterator;
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageID = message.MessageID;
const VC = message.ValidCombination;

const Options = tofu.Options;
const Ampe = tofu.Ampe;

const status = tofu.status;
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const internal = @import("../internal.zig");
const MchnGroup = internal.MchnGroup;

const Notifier = internal.Notifier;
const Pool = internal.Pool;
const channels = internal.channels;
const ActiveChannels = channels.ActiveChannels;
const sockets = internal.sockets;
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;
const DumbSkt = internal.triggeredSkts.DumbSkt;
const poller = internal.poller;

const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;
const log = std.log;
const assert = std.debug.assert;
