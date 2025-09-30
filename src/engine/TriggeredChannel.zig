// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const TriggeredChannel = @This();

prnt: *Distributor = undefined,
acn: channels.ActiveChannel = undefined,
resp2ac: bool = undefined,
tskt: TriggeredSkt = undefined,
exp: sockets.Triggers = undefined,
act: sockets.Triggers = undefined,
mrk4del: bool = undefined,
st: ?AmpeStatus = undefined,

pub fn createDumbChannel(prnt: *Distributor) TriggeredChannel {
    const ret: Distributor.TriggeredChannel = .{
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

pub fn createNotificationChannel(prnt: *Distributor) !void {
    var ntcn = createDumbChannel(prnt);
    ntcn.resp2ac = true;
    ntcn.tskt = .{
        .notification = sockets.NotificationSkt.init(prnt.ntfr.receiver),
    };

    prnt.trgrd_map.put(ntcn.acn.chn, ntcn) catch {
        return AmpeError.AllocationFailed;
    };
    prnt.cnmapChanged = true;

    prnt.ntfcsEnabled = true;

    return;
}

pub fn createIoClientChannel(dtr: *Distributor) AmpeError!void {
    const hello: *Message = dtr.currMsg.?;

    var tc = createDumbChannel(dtr);
    tc.acn = dtr.*.acns.activeChannel(hello.bhdr.channel_number) catch unreachable;

    // 2DO - Add method put to dtr
    dtr.trgrd_map.put(hello.bhdr.channel_number, tc) catch {
        return AmpeError.AllocationFailed;
    };
    dtr.cnmapChanged = true;

    var sc: sockets.SocketCreator = sockets.SocketCreator.init(dtr.allocator);
    var clSkt: sockets.IoSkt = .{};
    errdefer clSkt.deinit();

    try clSkt.initClientSide(&dtr.pool, hello, &sc);
    dtr.currMsg = null;

    const tcptr = dtr.trgrd_map.getPtr(hello.bhdr.channel_number).?;
    tcptr.disableDelete();
    tcptr.*.resp2ac = true;

    const tskt: TriggeredSkt = .{
        .io = clSkt,
    };
    tcptr.*.tskt = tskt;

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

    if ((tchn.acn.ctx == null) or (tchn.resp2ac == false)) {
        tchn.tskt.deinit();
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

    const statusMsgUn = tchn.prnt.pool.get(.always);
    if (statusMsgUn) |statusMsg| {
        statusMsg.bhdr.channel_number = tchn.acn.chn;
        statusMsg.bhdr.message_id = tchn.acn.mid;
        statusMsg.bhdr.proto.origin = .engine;
        statusMsg.bhdr.status = status.status_to_raw(.channel_closed);

        switch (tchn.acn.intr.?) {
            .WelcomeRequest => {}, // Accept skt
            .WelcomeSignal => {}, // Accept skt
            .HelloRequest => {}, // IO skt client
            .HelloSignal => {}, // IO skt client
            else => {}, // IO skt server
        }

        statusMsg.bhdr.proto.role = .signal;

        var responseToCtx: ?*Message = statusMsg;

        tchn.sendToCtx(&responseToCtx);
    } else |_| {}

    tchn.tskt.deinit();
}

pub fn sendToCtx(tchn: *TriggeredChannel, storedMsg: *?*Message) void {
    if (storedMsg.* == null) {
        return;
    }

    defer tchn.prnt.releaseToPool(storedMsg);

    if ((tchn.acn.ctx == null) or (tchn.resp2ac == false)) {
        return;
    }

    Gate.sendToWaiter(tchn.acn.ctx.?, storedMsg) catch {};

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

const configurator = @import("../configurator.zig");
const Configurator = configurator.Configurator;

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageRole = message.MessageRole;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = @import("../message.zig").TextHeaderIterator;
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageID = message.MessageID;
const VC = message.ValidCombination;

const engine = @import("../engine.zig");
const Options = engine.Options;
const Ampe = engine.Ampe;
const MessageChannelGroup = engine.MessageChannelGroup;

const status = @import("../status.zig");
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const Notifier = @import("Notifier.zig");

const Pool = @import("Pool.zig");

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

const sockets = @import("sockets.zig");
const TriggeredSkt = @import("triggeredSkts.zig").TriggeredSkt;
const DumbSkt = @import("triggeredSkts.zig").DumbSkt;

const Gate = @import("Gate.zig");

const poller = @import("poller.zig");

const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const Distributor = @import("Distributor.zig");

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;
const log = std.log;
const assert = std.debug.assert;
