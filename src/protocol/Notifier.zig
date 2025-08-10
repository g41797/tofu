// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const SEC_TIMEOUT_MS = 1_000;
const INFINITE_TIMEOUT_MS = -1;

pub const NotificationKind = enum(u1) {
    message = 0,
    alert = 1,
};

pub const MessagePriority = enum(u1) {
    regularMsg = 0,
    oobMsg = 1,
};

pub const Alert = enum(u2) {
    freedMemory = 0,
    srRemoved = 1,
    shutdownStarted = 2,
    _reserved = 3,
};

pub const SendAlert = *const fn (context: ?*anyopaque, alrt: Alert) anyerror!void;

pub const Alerter = struct {
    ptr: ?*anyopaque,
    func: SendAlert = undefined,

    pub fn send_alert(ar: *Alerter, alert: Alert) anyerror!void {
        return ar.func(ar.ptr, alert);
    }
};

pub const Notification = packed struct(u8) {
    kind: NotificationKind = undefined,
    priority: MessagePriority = undefined,
    hint: ValidCombination = undefined,
    alert: Alert = undefined,
};

pub const Notifier = @This();

sender: socket_t = undefined,
receiver: socket_t = undefined,

pub fn create(allocator: Allocator) !*Notifier {
    const ntfr = try allocator.create(Notifier);
    errdefer allocator.destroy(ntfr);
    try ntfr.init(allocator);
    return ntfr;
}

pub fn destroy(ntfr: *Notifier, allocator: Allocator) void {
    ntfr.deinit();
    allocator.destroy(ntfr);
}

pub fn init(allocator: Allocator) !Notifier {
    var tempFile = try temp.create_file(allocator, "yaaamp*.port");
    tempFile.retain = false;
    defer tempFile.deinit();

    var socket_path: [104:0]u8 = undefined;

    const socket_file = try tempFile.parent_dir.realpath(tempFile.basename, socket_path[0..104]);
    // Remove socket file if it exists
    tempFile.parent_dir.deleteFile(tempFile.basename) catch {};

    const addr = try std.net.Address.initUnix(socket_file);

    // Create listening socket
    const server_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(server_fd);
    try std.posix.bind(server_fd, &addr.any, addr.getOsSockLen());
    try std.posix.listen(server_fd, @truncate(1));

    // Create sender(client) socket
    const sender_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(sender_fd);
    try posix.connect(sender_fd, &addr.any, addr.getOsSockLen());

    // Accept a sender connection - create receiver socket
    const receiver_fd = try posix.accept(server_fd, null, null, 0);
    errdefer posix.close(receiver_fd);

    try nats.Client.setSockNONBLOCK(sender_fd);
    try nats.Client.setSockNONBLOCK(receiver_fd);

    return .{
        .sender = sender_fd,
        .receiver = receiver_fd,
    };
}

pub fn isReadyToRecv(ntfr: *Notifier) bool {
    return _isReadyToRecv(ntfr.receiver);
}

pub fn _isReadyToRecv(receiver: socket_t) bool {
    var rpoll: [1]pollfd = .{
        .{
            .fd = receiver,
            .events = POLL.IN,
            .revents = 0,
        },
    };

    const pollstatus = posix.poll(&rpoll, SEC_TIMEOUT_MS) catch {
        return false;
    };

    if (pollstatus == 0) {
        return false;
    }

    if (rpoll[0].revents & std.posix.POLL.HUP != 0) {
        return false;
    }

    return true;
}

pub fn isReadyToSend(ntfr: *Notifier) bool {
    return _isReadyToSend(ntfr.sender);
}

pub fn _isReadyToSend(sender: socket_t) bool {
    var spoll: [1]pollfd = .{
        .{
            .fd = sender,
            .events = POLL.OUT,
            .revents = 0,
        },
    };

    const pollstatus = posix.poll(&spoll, SEC_TIMEOUT_MS) catch {
        return false;
    };

    if (pollstatus == 0) {
        return false;
    }

    if (spoll[0].revents & std.posix.POLL.HUP != 0) {
        return false;
    }

    return true;
}

pub fn recvNotification(ntfr: *Notifier) !Notification {
    const byte = try recvByte(ntfr.receiver);
    const ntptr: *const Notification = @ptrCast(&byte);
    return (ntptr.*);
}

pub inline fn recvByte(receiver: socket_t) !u8 {
    var byte_array: [1]u8 = undefined;
    _ = std.posix.recv(receiver, &byte_array, 0) catch |err| {
        return err;
    };
    return byte_array[0];
}

pub fn sendNotification(ntfr: *Notifier, notif: Notification) !void {
    const byteptr: *const u8 = @ptrCast(&notif);

    for (0..10) |_| {
        if (ntfr.isReadyToSend()) {
            return sendByte(ntfr.sender, byteptr.*);
        }
    }

    return AMPError.NotificationFailed;
}

pub inline fn sendByte(sender: socket_t, notif: u8) !void {
    var byte_array = [_]u8{notif};
    _ = std.posix.send(sender, &byte_array, 0) catch {
        return AMPError.NotificationFailed;
    };
    return;
}

pub fn sendAck(ntfr: *Notifier, ack: u8) !void {
    for (0..10) |_| {
        if (_isReadyToSend(ntfr.receiver)) {
            return sendByte(ntfr.receiver, ack);
        }
    }

    return AMPError.NotificationFailed;
}

pub fn recvAck(ntfr: *Notifier) !u8 {
    for (0..10) |_| {
        if (_isReadyToRecv(ntfr.sender)) {
            return recvByte(ntfr.sender);
        }
    }
    return AMPError.NotificationFailed;
}

pub fn deinit(ntfr: *Notifier) void {
    posix.close(ntfr.sender);
    posix.close(ntfr.receiver);
}

pub const message = @import("../message.zig");
pub const ValidCombination = message.ValidCombination;

pub const status = @import("../status.zig");
pub const AMPStatus = status.AMPStatus;
pub const AMPError = status.AMPError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const temp = @import("temp");
const nats = @import("nats");

const std = @import("std");
const posix = std.posix;
const socket_t = posix.socket_t;
const system = posix.system;
const pollfd = posix.pollfd;
const POLL = system.POLL;
const Allocator = std.mem.Allocator;

// Get list of connected uds
// ss -x|grep yaaamp
