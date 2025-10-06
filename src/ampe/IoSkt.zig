// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const IoSkt = @This();

pool: *Pool = undefined,
side: Side = undefined,
cn: message.ChannelNumber = undefined,
skt: Skt = undefined,
connected: bool = undefined,
sendQ: MessageQueue = undefined,
currSend: MsgSender = undefined,
byeWasSend: bool = undefined,
currRecv: MsgReceiver = undefined,
byeResponseReceived: bool = undefined,
alreadySend: ?*Message = null,

pub fn initServerSide(pool: *Pool, cn: message.ChannelNumber, sskt: Skt) AmpeError!IoSkt {
    log.debug("Server IoSkt init", .{});

    var ret: IoSkt = .{
        .pool = pool,
        .side = .server,
        .cn = cn,
        .skt = sskt,
        .connected = true,
        .sendQ = .{},
        .currSend = MsgSender.init(),
        .currRecv = MsgReceiver.init(pool),
        .byeWasSend = false,
        .byeResponseReceived = false,
        .alreadySend = null,
    };

    ret.currSend.set(cn, sskt.socket.?) catch unreachable;
    ret.currRecv.set(cn, sskt.socket.?) catch unreachable;

    return ret;
}

pub fn initClientSide(ios: *IoSkt, pool: *Pool, hello: *Message, sc: *SocketCreator) AmpeError!void {
    log.debug("Client IoSkt init", .{});

    ios.pool = pool;
    ios.side = .client;
    ios.cn = hello.bhdr.channel_number;
    ios.skt = try sc.fromMessage(hello);
    ios.connected = false;
    ios.sendQ = .{};
    ios.currSend = MsgSender.init();
    ios.currRecv = MsgReceiver.init(pool);
    ios.byeResponseReceived = false;
    ios.byeWasSend = false;
    ios.alreadySend = null;

    errdefer ios.skt.deinit();

    ios.addToSend(hello) catch unreachable;

    // ios.connected = try ios.skt.connect();
    //
    // if (ios.connected) {
    //     ios.postConnect();
    //     var sq = try ios.trySend();
    //     ios.alreadySend = sq.dequeue();
    // }

    return;
}

pub fn triggers(ioskt: *IoSkt) !Triggers {
    if (ioskt.side == .client) { // Initial state of client ioskt - not-connected

        if (!ioskt.connected) {
            return .{
                .connect = .on,
            };
        }
    }

    var ret: Triggers = .{};
    if (!ioskt.sendQ.empty() or ioskt.currSend.started()) {
        if(!ioskt.byeWasSend) {
            ret.send = .on;
        }
    }

    if (!ioskt.byeResponseReceived) {
        const recvPossible = try ioskt.currRecv.recvIsPossible();

        if (recvPossible) {
            ret.recv = .on;
        } else {
            assert(ioskt.currRecv.ptrg == .on);
            ret.pool = .on;
        }
    }

    if (DBG) {
        const utrgs = sockets.UnpackedTriggers.fromTriggers(ret);
        _ = utrgs;
    }

    return ret;
}

pub inline fn getSocket(self: *IoSkt) Socket {
    return self.skt.socket.?;
}

pub fn addToSend(ioskt: *IoSkt, sndmsg: *Message) AmpeError!void {
    ioskt.sendQ.enqueue(sndmsg);
    return;
}

pub fn addForRecv(ioskt: *IoSkt, rcvmsg: *Message) AmpeError!void {
    return ioskt.currRecv.attach(rcvmsg);
}

// tryConnect is called by Engine for succ. connection.
// For the failed connection Engine uses detach: get Hello request , convert to filed Hello response...
pub fn tryConnect(ioskt: *IoSkt) AmpeError!bool {

    // Now it's ok to connect to already connected socket
    ioskt.connected = try ioskt.skt.connect();

    if (ioskt.connected) {
        ioskt.postConnect();
    }

    return ioskt.connected;
}

fn postConnect(ioskt: *IoSkt) void {
    ioskt.currSend.set(ioskt.cn, ioskt.skt.socket.?) catch unreachable;
    ioskt.currRecv.set(ioskt.cn, ioskt.skt.socket.?) catch unreachable;

    ioskt.currSend.attach(ioskt.sendQ.dequeue().?) catch unreachable;
    ioskt.alreadySend = null;
    return;
}

pub fn detach(ioskt: *IoSkt) MessageQueue {
    var ret: MessageQueue = .{};

    const last = ioskt.currSend.detach();

    if (last != null) {
        ret.enqueue(last.?);
    }

    ioskt.sendQ.move(&ret);

    return ret;
}

pub fn tryRecv(ioskt: *IoSkt) AmpeError!MessageQueue {
    if (!ioskt.connected) {
        return AmpeError.NotAllowed;
    }

    var ret: MessageQueue = .{};

    while (true) {
        const received = ioskt.currRecv.recv() catch |e| {
            switch (e) {
                AmpeError.PoolEmpty => {
                    return ret;
                },
                else => return e,
            }
        };

        if (received == null) {
            break;
        }

        // Replace "remote" channel_number with "local" one
        received.?.bhdr.channel_number = ioskt.cn;

        if ((received.?.bhdr.proto.mtype == .bye) and (received.?.bhdr.proto.role == .response)) {
            ioskt.byeResponseReceived = true;
        }

        ret.enqueue(received.?);

        if(ioskt.byeResponseReceived) {
            break;
        }
    }

    return ret;
}

pub fn trySend(ioskt: *IoSkt) AmpeError!MessageQueue {
    var ret: MessageQueue = .{};

    if (!ioskt.connected) {
        return AmpeError.NotAllowed;
    }

    while (true) {
        if (!ioskt.currSend.started()) {
            if (ioskt.sendQ.empty()) {
                break;
            }
            ioskt.currSend.attach(ioskt.sendQ.dequeue().?) catch unreachable; // Ok for non-empty q
        }

        const wasSend = try ioskt.currSend.send();

        if (wasSend == null) {
            break;
        }

        if (wasSend.?.bhdr.proto.mtype == .bye){
            ioskt.byeWasSend = true;
        }

        ret.enqueue(wasSend.?);

        if(ioskt.byeWasSend) {
            break;
        }
    }

    return ret;
}

pub fn deinit(ioskt: *IoSkt) void {
    ioskt.skt.deinit();
    message.clearQueue(&ioskt.sendQ);

    ioskt.currSend.deinit();
    ioskt.currRecv.deinit();

    if (ioskt.alreadySend != null) {
        ioskt.alreadySend.?.destroy();
        ioskt.alreadySend = null;
    }

    return;
}

const tofu = @import("../tofu.zig");

const message = tofu.message;
const Trigger = message.Trigger;
const BinaryHeader = message.BinaryHeader;
const Message = message.Message;
const MessageQueue = message.MessageQueue;
const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;

const internal = @import("internal.zig");

const SocketCreator = internal.SocketCreator;
const Skt = internal.Skt;
const MsgReceiver = internal.MsgReceiver;
const MsgSender = internal.MsgSender;

const sockets = internal.sockets;
const Triggers = sockets.Triggers;
const Side = internal.triggeredSkts.Side;
const Pool = internal.Pool;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Socket = std.posix.socket_t;

const log = std.log;
