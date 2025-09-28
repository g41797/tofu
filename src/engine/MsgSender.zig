// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const MsgSender = @This();

ready: bool = undefined,
cn: message.ChannelNumber = undefined,
socket: Socket = undefined,
msg: ?*Message = undefined,
bh: [BinaryHeader.BHSIZE]u8 = [_]u8{'+'} ** BinaryHeader.BHSIZE,
iov: [3]std.posix.iovec_const = undefined,
vind: usize = undefined,
sndlen: usize = undefined,
iovPrepared: bool = undefined,

pub fn init() MsgSender {
    return .{
        .ready = false,
        .msg = null,
        .sndlen = 0,
        .vind = 3,
        .iovPrepared = false,
    };
}

pub fn set(ms: *MsgSender, cn: message.ChannelNumber, socket: Socket) !void {
    if (ms.ready) {
        return AmpeError.NotAllowed;
    }
    ms.cn = cn;
    ms.socket = socket;
    ms.ready = true;
}

pub inline fn isReady(ms: *MsgSender) bool {
    return ms.ready;
}

pub fn deinit(ms: *MsgSender) void {
    if (ms.msg) |m| {
        m.destroy();
    }
    ms.msg = null;
    ms.sndlen = 0;
    return;
}

pub fn attach(ms: *MsgSender, msg: *Message) !void {
    if (!ms.ready) {
        return AmpeError.NotAllowed;
    }

    if (ms.msg) |m| {
        m.destroy();
    }

    ms.msg = msg;
    ms.iovPrepared = false;

    return;
}

inline fn prepare(ms: *MsgSender) void {
    const hlen = ms.msg.?.actual_headers_len();
    const blen = ms.msg.?.actual_body_len();

    ms.msg.?.bhdr.body_len = @intCast(blen);
    ms.msg.?.bhdr.text_headers_len = @intCast(hlen);

    @memset(&ms.bh, ' ');

    ms.msg.?.bhdr.toBytes(&ms.bh);
    ms.vind = 0;

    assert(ms.bh.len == message.BinaryHeader.BHSIZE);

    ms.iov[0] = .{ .base = &ms.bh, .len = ms.bh.len };
    ms.sndlen = ms.bh.len;

    if (hlen == 0) {
        ms.iov[1] = .{ .base = @ptrCast(""), .len = 0 };
    } else {
        ms.iov[1] = .{ .base = @ptrCast(ms.msg.?.thdrs.buffer.body().?.ptr), .len = hlen };
        ms.sndlen += hlen;
    }

    if (blen == 0) {
        ms.iov[2] = .{ .base = @ptrCast(""), .len = 0 };
    } else {
        ms.iov[2] = .{ .base = @ptrCast(ms.msg.?.body.body().?.ptr), .len = blen };
        ms.sndlen += blen;
    }

    ms.iovPrepared = true;
    return;
}

pub inline fn started(ms: *MsgSender) bool {
    return (ms.msg != null);
}

pub fn detach(ms: *MsgSender) ?*Message {
    const ret = ms.msg;
    ms.msg = null;
    ms.sndlen = 0;
    ms.vind = 3;
    return ret;
}

pub fn send(ms: *MsgSender) AmpeError!?*Message {
    if (!ms.ready) {
        return AmpeError.NotAllowed;
    }
    if (ms.msg == null) {
        return AmpeError.NotAllowed; // to  prevent bug
    }

    if (!ms.iovPrepared) {
        ms.prepare();
    }

    while (ms.vind < 3) : (ms.vind += 1) {
        while (ms.iov[ms.vind].len > 0) {
            const wasSend = try sendBuf(ms.socket, ms.iov[ms.vind].base[0..ms.iov[ms.vind].len]);
            if (wasSend == null) {
                return null;
            }
            ms.iov[ms.vind].base += wasSend.?;
            ms.iov[ms.vind].len -= wasSend.?;
            ms.sndlen -= wasSend.?;

            if (ms.sndlen > 0) {
                continue;
            }

            const ret = ms.msg;
            ms.msg = null;
            return ret;
        }
    }
    return AmpeError.NotAllowed; // to  prevent bug
}

pub fn sendBuf(socket: std.posix.socket_t, buf: []const u8) AmpeError!?usize {
    var wasSend: usize = 0;
    wasSend = std.posix.send(socket, buf, 0) catch |e| {
        switch (e) {
            std.posix.SendError.WouldBlock => {
                return null;
            },
            std.posix.SendError.ConnectionResetByPeer, std.posix.SendError.BrokenPipe => return AmpeError.PeerDisconnected,
            else => return AmpeError.CommunicationFailed,
        }
    };

    if (wasSend == 0) {
        return null;
    }

    return wasSend;
}

pub fn sendBufTo(socket: std.posix.socket_t, buf: []const u8) AmpeError!?usize {
    var wasSend: usize = 0;
    wasSend = std.posix.sendto(socket, buf, 0, null, 0) catch |e| {
        switch (e) {
            std.posix.SendError.WouldBlock => {
                return null;
            },
            else => return AmpeError.CommunicationFailed,
        }
    };

    if (wasSend == 0) {
        return null;
    }

    return wasSend;
}

const message = @import("../message.zig");
const Trigger = message.Trigger;
const BinaryHeader = message.BinaryHeader;
const Message = message.Message;
const MessageQueue = message.MessageQueue;
const MessageID = message.MessageID;
const DBG = @import("../engine.zig").DBG;
const AmpeError = @import("../status.zig").AmpeError;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Socket = std.posix.socket_t;
const log = std.log;
