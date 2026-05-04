// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const tofu = @import("../../tofu.zig");
const AmpeError = tofu.status.AmpeError;

pub const NotificationKind = enum(u1) { message = 0, alert = 1 };
pub const Alert = enum(u1) { freedMemory = 0, shutdownStarted = 1 };
pub const SendAlert = *const fn (context: ?*anyopaque, alrt: Alert) AmpeError!void;

pub const Alerter = struct {
    ptr: ?*anyopaque,
    func: SendAlert = undefined,
    pub fn send_alert(ar: *Alerter, alert: Alert) AmpeError!void {
        return ar.func(ar.ptr, alert);
    }
};

pub const Oob = @import("../../tofu.zig").message.Trigger;

pub const Notification = packed struct(u8) {
    kind: NotificationKind = undefined,
    oob: Oob = undefined,
    alert: Alert = undefined,
    _reserved: u5 = 0,
};

pub const UnpackedNotification = struct {
    kind: u8 = 0,
    oob: u8 = 0,
    alert: u8 = 0,
    pub fn fromNotification(nt: Notification) UnpackedNotification {
        return .{
            .kind = @intFromEnum(nt.kind),
            .oob = @intFromEnum(nt.oob),
            .alert = @intFromEnum(nt.alert),
        };
    }
};

pub const Notifier = @This();

pub fn init(_: Allocator) !Notifier {
    return AmpeError.NotImplementedYet;
}

pub fn deinit(_: *Notifier) void {}

pub fn isReadyToRecv(_: *Notifier) bool { return false; }
pub fn isReadyToSend(_: *Notifier) bool { return false; }

pub fn recvNotification(_: *Notifier) !Notification {
    return AmpeError.NotImplementedYet;
}

pub fn sendNotification(_: *Notifier, _: Notification) AmpeError!void {
    return AmpeError.NotImplementedYet;
}
