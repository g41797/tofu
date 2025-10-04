// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const MsgReceiver = @This();

ready: bool = undefined,
cn: message.ChannelNumber = undefined,
socket: Socket = undefined,
pool: *Pool = undefined,
ptrg: Trigger = undefined,
bh: [BinaryHeader.BHSIZE]u8 = [_]u8{'-'} ** BinaryHeader.BHSIZE,
iov: [3]std.posix.iovec = undefined,
vind: usize = undefined,
rcvlen: usize = undefined,
msg: ?*Message = undefined,

pub fn init(pool: *Pool) MsgReceiver {
    return .{
        .ready = false,
        .pool = pool,
        .msg = null,
        .rcvlen = 0,
        .vind = 3,
        .ptrg = .off, // Possibly msg == null will be good enough
    };
}

pub fn set(mr: *MsgReceiver, cn: message.ChannelNumber, socket: Socket) !void {
    if (mr.ready) {
        return AmpeError.NotAllowed;
    }
    mr.cn = cn;
    mr.socket = socket;
    mr.ready = true;
}

pub fn recvIsPossible(mr: *MsgReceiver) !bool {
    if (mr.msg != null) {
        return true;
    }

    const msg = mr.getFromPool() catch |err| {
        if (err != AmpeError.PoolEmpty) {
            return err;
        }
        return false;
    };
    mr.msg = msg;
    mr.prepareMsg();
    return true;
}

pub fn attach(mr: *MsgReceiver, msg: *Message) !void {
    if ((!mr.ready) or (mr.msg != null)) {
        return AmpeError.NotAllowed;
    }

    mr.msg = msg;
    mr.ptrg = .off;

    mr.prepareMsg();

    return;
}

inline fn prepareMsg(mr: *MsgReceiver) void {
    mr.msg.?.reset();
    @memset(&mr.bh, ' ');
    assert(mr.bh.len == message.BinaryHeader.BHSIZE);

    mr.iov[0] = .{ .base = &mr.bh, .len = mr.bh.len };
    mr.iov[1] = .{ .base = mr.msg.?.thdrs.buffer.buffer.?.ptr, .len = 0 };
    mr.iov[2] = .{ .base = mr.msg.?.body.buffer.?.ptr, .len = 0 };

    mr.vind = 0;
    mr.rcvlen = 0;
    return;
}

fn getFromPool(mr: *MsgReceiver) AmpeError!*Message {
    const ret = mr.pool.get(.poolOnly) catch |e| {
        switch (e) {
            AmpeError.PoolEmpty => {
                mr.ptrg = .on;
                return e;
            },
            else => return AmpeError.AllocationFailed,
        }
    };
    mr.ptrg = .off;
    return ret;
}

pub fn recv(mr: *MsgReceiver) !?*Message {
    if (!mr.ready) {
        return AmpeError.NotAllowed;
    }

    if (mr.msg == null) {
        mr.msg = try mr.getFromPool();
        mr.prepareMsg();
    }

    while (mr.vind < 3) : (mr.vind += 1) {
        while (mr.iov[mr.vind].len > 0) {
            const wasRecv = try recvToBuf(mr.socket, mr.iov[mr.vind].base[0..mr.iov[mr.vind].len]);
            if (wasRecv == null) {
                return null;
            }

            if (wasRecv.? == 0) {
                return null;
            }
            mr.iov[mr.vind].base += wasRecv.?;
            mr.iov[mr.vind].len -= wasRecv.?;
            mr.rcvlen += wasRecv.?;
        }

        if (mr.vind == 0) {
            mr.msg.?.bhdr.fromBytes(&mr.bh);
            if (mr.msg.?.bhdr.text_headers_len > 0) {
                mr.iov[1].len = mr.msg.?.bhdr.text_headers_len;

                // Allow direct receive to the buffer of appendable without copy
                mr.msg.?.thdrs.buffer.alloc(mr.iov[1].len) catch {
                    return AmpeError.AllocationFailed;
                };
                mr.msg.?.thdrs.buffer.change(mr.iov[1].len) catch unreachable;
            }
            if (mr.msg.?.bhdr.body_len > 0) {
                mr.iov[2].len = mr.msg.?.bhdr.body_len;

                // Allow direct receive to the buffer of appendable without copy
                mr.msg.?.body.alloc(mr.iov[2].len) catch {
                    return AmpeError.AllocationFailed;
                };
                mr.msg.?.body.change(mr.iov[2].len) catch unreachable;
            }
        }
    }

    const ret = mr.msg;
    mr.msg = null;
    return ret;
}

pub inline fn isReady(mr: *MsgReceiver) bool {
    return mr.ready;
}

pub fn deinit(mr: *MsgReceiver) void {
    if (mr.msg) |m| {
        m.destroy();
    }
    mr.msg = null;
    mr.rcvlen = 0;
    return;
}

pub fn recvToBuf(socket: std.posix.socket_t, buf: []u8) AmpeError!?usize {
    var wasRecv: usize = 0;
    wasRecv = std.posix.recv(socket, buf, 0) catch |e| {
        switch (e) {
            std.posix.RecvFromError.WouldBlock => {
                return null;
            },
            std.posix.RecvFromError.ConnectionResetByPeer, std.posix.RecvFromError.ConnectionRefused => return AmpeError.PeerDisconnected,
            else => return AmpeError.CommunicationFailed,
        }
    };

    return wasRecv;
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
const Pool = internal.Pool;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Socket = std.posix.socket_t;
const log = std.log;
