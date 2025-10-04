// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Triggers = packed struct(u8) {
    notify: Trigger = .off,
    accept: Trigger = .off,
    connect: Trigger = .off,
    send: Trigger = .off,
    recv: Trigger = .off,
    pool: Trigger = .off,
    err: Trigger = .off,
    timeout: Trigger = .off,

    pub inline fn eql(self: Triggers, other: Triggers) bool {
        return self == other;
    }

    pub inline fn off(self: Triggers) bool {
        const z: u8 = @bitCast(self);
        return (z == 0);
    }

    pub inline fn lor(self: Triggers, other: Triggers) Triggers {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }

    pub fn toStatus(self: Triggers) AmpeStatus {
        if (self.err == .off) {
            return .success;
        }

        if (self.notify == .on) {
            return AmpeStatus.notification_failed;
        }

        if (self.connect == .on) {
            return AmpeStatus.connect_failed;
        }

        if (self.accept == .on) {
            return AmpeStatus.accept_failed;
        }

        return AmpeStatus.communication_failed;
    }
};

pub const TriggersOff: Triggers = .{
    .accept = .off,
    .err = .off,
    .connect = .off,
    .notify = .off,
    .pool = .off,
    .recv = .off,
    .send = .off,
    .timeout = .off,
};

pub const UnpackedTriggers = struct {
    notify: u8 = 0,
    accept: u8 = 0,
    connect: u8 = 0,
    send: u8 = 0,
    recv: u8 = 0,
    pool: u8 = 0,
    err: u8 = 0,
    timeout: u8 = 0,

    pub fn fromTriggers(tr: Triggers) UnpackedTriggers {
        var ret: UnpackedTriggers = .{};
        if (!tr.off()) {
            if (tr.notify == .on) {
                ret.notify = 1;
            }
            if (tr.accept == .on) {
                ret.accept = 1;
            }
            if (tr.connect == .on) {
                ret.connect = 1;
            }
            if (tr.send == .on) {
                ret.send = 1;
            }
            if (tr.recv == .on) {
                ret.recv = 1;
            }
            if (tr.pool == .on) {
                ret.pool = 1;
            }
            if (tr.err == .on) {
                ret.err = 1;
            }
            if (tr.timeout == .on) {
                ret.timeout = 1;
            }
        }
        return ret;
    }
};

pub const Side = enum(u1) {
    client = 0,
    server = 1,
};

pub const TriggeredSkt = union(enum) {
    notification: NotificationSkt,
    accept: AcceptSkt,
    io: IoSkt,
    dumb: DumbSkt,

    pub fn triggers(tsk: *TriggeredSkt) !Triggers {
        const ret = switch (tsk.*) {
            .notification => try tsk.*.notification.triggers(),
            .accept => try tsk.*.accept.triggers(),
            .io => try tsk.*.io.triggers(),
            inline else => return .{},
        };

        if (DBG) {
            _ = sockets.UnpackedTriggers.fromTriggers(ret);
        }

        return ret;
    }

    pub inline fn getSocket(tsk: *TriggeredSkt) Socket {
        return switch (tsk.*) {
            .notification => tsk.*.notification.getSocket(),
            .accept => tsk.*.accept.getSocket(),
            .io => tsk.*.io.getSocket(),
            inline else => return 0, // For Linux
        };
    }

    pub fn tryRecvNotification(tsk: *TriggeredSkt) !Notification {
        return switch (tsk.*) {
            .notification => tsk.*.notification.tryRecvNotification(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryAccept(tsk: *TriggeredSkt) !?Skt {
        return switch (tsk.*) {
            .accept => tsk.*.accept.tryAccept(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryConnect(tsk: *TriggeredSkt) !bool {
        return switch (tsk.*) {
            .io => tsk.*.io.tryConnect(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryRecv(tsk: *TriggeredSkt) !MessageQueue {
        return switch (tsk.*) {
            .io => tsk.*.io.tryRecv(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn trySend(tsk: *TriggeredSkt) !MessageQueue {
        return switch (tsk.*) {
            .io => tsk.*.io.trySend(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn addToSend(tsk: *TriggeredSkt, sndmsg: *Message) !void {
        return switch (tsk.*) {
            .io => tsk.*.io.addToSend(sndmsg),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn addForRecv(tsk: *TriggeredSkt, rcvmsg: *Message) !void {
        return switch (tsk.*) {
            .io => tsk.*.io.addForRecv(rcvmsg),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn detach(tsk: *TriggeredSkt) MessageQueue {
        return switch (tsk.*) {
            .io => tsk.*.io.detach(),
            inline else => return .{},
        };
    }

    pub fn deinit(tsk: *TriggeredSkt) void {
        return switch (tsk.*) {
            .notification => tsk.*.notification.deinit(),
            .accept => tsk.*.accept.deinit(),
            .io => tsk.*.io.deinit(),
            .dumb => tsk.*.dumb.deinit(),
        };
    }
};

const NotificationTriggers: Triggers = .{
    .notify = .on,
};

pub const NotificationSkt = struct {
    socket: Socket = undefined,

    pub fn init(socket: Socket) NotificationSkt { // prnt.ntfr.receiver
        log.debug("NotificationSkt init", .{});
        return .{
            .socket = socket,
        };
    }

    pub fn triggers(nskt: *NotificationSkt) !Triggers {
        _ = nskt;
        return NotificationTriggers;
    }

    pub inline fn getSocket(self: *NotificationSkt) Socket {
        return self.socket;
    }

    pub fn tryRecvNotification(nskt: *NotificationSkt) !Notification {
        return Notifier.recv_notification(nskt.socket);
    }

    pub fn deinit(nskt: *NotificationSkt) void {
        // Notification sockets will be closed by ampe itself
        _ = nskt;
        return;
    }
};

const AcceptTriggers: Triggers = .{
    .accept = .on,
};

pub const AcceptSkt = struct {
    skt: Skt = undefined,

    pub fn init(wlcm: *Message, sc: *SocketCreator) AmpeError!AcceptSkt {
        return .{
            .skt = try sc.fromMessage(wlcm),
        };
    }

    pub fn triggers(askt: *AcceptSkt) !Triggers {
        _ = askt;
        return AcceptTriggers;
    }

    pub inline fn getSocket(self: *AcceptSkt) Socket {
        return self.skt.socket.?;
    }

    pub fn tryAccept(askt: *AcceptSkt) AmpeError!?Skt {
        return askt.skt.accept();
    }

    pub fn deinit(askt: *AcceptSkt) void {
        askt.skt.close();
        return;
    }
};

pub const DumbSkt = struct {
    pub fn deinit(dskt: *DumbSkt) void {
        _ = dskt;
        return;
    }
};

const tofu = @import("../tofu.zig");

const message = tofu.message;
const MessageQueue = message.MessageQueue;
const Trigger = message.Trigger;
const BinaryHeader = message.BinaryHeader;
const Message = message.Message;
const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;
const AmpeStatus = tofu.status.AmpeStatus;

const IoSkt = @import("IoSkt.zig");
const SocketCreator = @import("SocketCreator.zig");
const Skt = @import("Skt.zig");
const sockets = @import("sockets.zig");
const Notifier = @import("Notifier.zig");
const Notification = Notifier.Notification;

const std = @import("std");
const Socket = std.posix.socket_t;
const log = std.log;
