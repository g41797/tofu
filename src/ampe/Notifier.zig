// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const builtin = @import("builtin");

// Shared types (platform-independent)

pub const NotificationKind = enum(u1) {
    message = 0,
    alert = 1,
};

pub const Alert = enum(u1) {
    freedMemory = 0,
    shutdownStarted = 1,
};

pub const SendAlert = *const fn (context: ?*anyopaque, alrt: Alert) AmpeError!void;

pub const Alerter = struct {
    ptr: ?*anyopaque,
    func: SendAlert = undefined,

    pub fn send_alert(ar: *Alerter, alert: Alert) AmpeError!void {
        return ar.func(ar.ptr, alert);
    }
};

/// High priority. Goes to head of queue.
pub const Oob = message.Trigger;

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

// Platform backend
pub const backend = switch (builtin.os.tag) {
    .windows => @import("os/windows/Notifier.zig"),
    else => @import("os/linux/Notifier.zig"),
};

// Re-export platform Notifier struct and static functions
pub const Notifier = backend.Notifier;
pub const recv_notification = backend.recv_notification;
pub const send_notification = backend.send_notification;

const tofu = @import("../tofu.zig");
const message = tofu.message;
const status = tofu.status;
const AmpeError = status.AmpeError;
