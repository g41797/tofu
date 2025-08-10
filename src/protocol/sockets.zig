// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const PolledSkt = union(enum) {
    notification: ?*NotificationSkt,
    accept: ?*AcceptSkt,
    io: ?*IoSkt,
};

pub const NotificationSkt = struct {
    prnt: *Poller = undefined,
    skt: Skt = undefined,

    pub fn init(prnt: *Poller) NotificationSkt {
        return .{
            .prnt = prnt,
            .skt = prnt.ntfr.receiver,
        };
    }

    pub fn recvNotification(nskt: *NotificationSkt) !Notification {
        _ = nskt;
        return AMPError.NotImplementedYet;
    }

    pub fn deinit(nskt: *NotificationSkt) void {
        _ = nskt;
        return;
    }
};

pub const AcceptSkt = struct {
    prnt: *Poller = undefined,
    root: channels.ActiveChannel = undefined,
    skt: Skt = undefined,

    pub fn init(prnt: *Poller, wlcm: *Message) AMPError!AcceptSkt {
        _ = prnt;
        _ = wlcm;
        return AMPError.NotImplementedYet;
    }

    pub fn accept(askt: *AcceptSkt) AMPError!?Skt {
        _ = askt;
        return AMPError.NotImplementedYet;
    }

    pub fn deinit(askt: *AcceptSkt) void {
        std.posix.close(askt.skt);
        return;
    }
};

pub const Side = enum(u1) {
    client = 0,
    server = 1,
};

pub const IoSkt = struct {
    prnt: *Poller = undefined,
    side: Side = undefined,
    root: channels.ActiveChannel = undefined,
    skt: Skt = undefined,
    connected: bool = undefined,
    sendQ: MessageQueue = undefined,
    currSend: ?*Message = undefined,
    currRecv: ?*Message = undefined,
    hello: ?*Message = undefined,

    pub fn initServerSide(prnt: *Poller, sskt: Skt) AMPError!IoSkt {
        _ = prnt;
        _ = sskt;
        return AMPError.NotImplementedYet;
    }

    pub fn initClientSide(prnt: *Poller, hello: *Message) AMPError!IoSkt {
        _ = prnt;
        _ = hello;
        return AMPError.NotImplementedYet;
    }

    pub fn addToSend(ioskt: *IoSkt, sndmsg: *Message) AMPError!void {
        _ = ioskt;
        _ = sndmsg;
        return AMPError.NotImplementedYet;
    }

    pub fn tryConnect(ioskt: *IoSkt) AMPError!?*Message {
        _ = ioskt;
        return AMPError.NotImplementedYet;
    }

    pub fn tryRecv(ioskt: *IoSkt) AMPError!?*Message {
        _ = ioskt;
        return AMPError.NotImplementedYet;
    }

    pub fn trySend(ioskt: *IoSkt) AMPError!?*Message {
        _ = ioskt;
        return AMPError.NotImplementedYet;
    }

    pub fn deinit(ioskt: *IoSkt) void {
        std.posix.close(ioskt.skt);
        ioskt.sendQ.destroy();
        if (ioskt.currSend != null) {
            ioskt.currSend.?.destroy();
            ioskt.currSend = null;
        }
        if (ioskt.currRecv != null) {
            ioskt.currRecv.?.destroy();
            ioskt.currRecv = null;
        }
        if (ioskt.hello != null) {
            ioskt.hello.?.destroy();
            ioskt.hello = null;
        }
        return;
    }
};

pub const MsgSender = struct {
    skt: Skt = undefined,
    msg: ?*Message = undefined,
    bh: [BinaryHeader.BHSIZE]u8 = undefined,
    iov: [3]std.posix.iovec_const = undefined,
    vind: usize = undefined,
    sndlen: usize = undefined,

    pub fn init(skt: Skt) MsgSender {
        return .{
            .skt = skt,
            .msg = null,
            .sndlen = 0,
        };
    }

    pub fn deinit(ms: *MsgSender) void {
        if (ms.msg) |m| {
            m.destroy();
        }
        ms.msg = null;
        ms.sndlen = 0;
        return;
    }

    pub fn attach(ms: *MsgSender, msg: *Message) void {
        if (ms.msg) |m| {
            m.destroy();
        }

        ms.msg = msg;
        msg.bhdr.toBytes(&ms.bh);
        ms.vind = 0;

        ms.iov[0] = .{ .base = &ms.bh, .len = ms.bh.len };
        ms.sndlen = ms.bh.len;

        const hlen = msg.actual_headers_len();
        if (hlen == 0) {
            ms.iov[1] = .{ .base = null, .len = 0 };
        } else {
            ms.iov[1] = .{ .base = msg.thdrs.buffer.body().?, .len = hlen };
            ms.sndlen += hlen;
        }

        const blen = msg.actual_body_len();
        if (blen == 0) {
            ms.iov[2] = .{ .base = null, .len = 0 };
        } else {
            ms.iov[2] = .{ .base = msg.body.body().?, .len = blen };
            ms.sndlen += blen;
        }

        return;
    }

    pub fn dettach(ms: *MsgSender) ?*Message {
        const ret = ms.msg;
        ms.msg = null;
        ms.sndlen = 0;
        return ret;
    }

    pub fn send(ms: *MsgSender) !?*Message {
        if (ms.msg == null) {
            return error.NothingToWrite; // to  prevent bug
        }

        if (ms.sndlen == 0) {
            const ret = ms.msg;
            ms.msg = null;
            return ret;
        }

        var rest: usize = 0;
        while (ms.vind < 3) : (ms.vind += 1) {
            rest = ms.iov[ms.vind].len;
            if (rest != 0) {
                break;
            }
        }

        if (rest == 0) {
            return error.NothingToWrite; // to  prevent bug
        }

        return ms._send();
    }

    inline fn _send(ms: *MsgSender) !?*Message {
        const wasSend = std.posix.send(ms.skt, ms.iov[ms.vind].base[0..ms.iov[ms.vind].len], 0) catch |e| {
            switch (e) {
                std.posix.SendError.WouldBlock => return null,
                std.posix.SendError.ConnectionResetByPeer, std.posix.SendError.BrokenPipe => return AMPError.PeerDisconnected,
                else => return AMPError.CommunicatioinFailed,
            }
        };

        ms.iov[ms.vind].base += wasSend;
        ms.iov[ms.vind].len -= wasSend;
        ms.sndlen -= wasSend;

        if (ms.sndlen > 0) {
            return null;
        }

        const ret = ms.msg;
        ms.msg = null;
        return ret;
    }
};

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageMode = message.MessageMode;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = @import("../TextHeaderIterator.zig");
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageQueue = message.MessageQueue;

const MessageID = message.MessageID;
const VC = message.ValidCombination;

const Poller = @import("Poller.zig");

const protocol = @import("../protocol.zig");
const Options = protocol.Options;
const Sr = protocol.Sr;
const AllocationStrategy = protocol.AllocationStrategy;

const status = @import("../status.zig");
const AMPStatus = status.AMPStatus;
const AMPError = status.AMPError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const Pool = @import("Pool.zig");
const Notifier = @import("Notifier.zig");
const Notification = Notifier.Notification;

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

pub const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
pub const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Skt = std.posix.socket_t;
