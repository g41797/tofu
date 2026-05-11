// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

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

pub const Notifier = @This();

sender: Skt = .{},
receiver: Skt = .{},

pub fn init(allocator: Allocator) !Notifier {
    if (comptime builtin.os.tag == .windows) {
        return initTCP(allocator);
    }
    return initUDS(allocator) catch {
        return initTCP(allocator);
    };
}

fn initTCP(allocator: Allocator) !Notifier {
    var sc = SCreator.init(allocator);
    var listener = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
    defer listener.deinit();
    var sender = try sc.fromAddress(.{ .tcp_client_addr = TCPClientAddress.init("127.0.0.1", listener.getPort().?) });
    errdefer sender.deinit();
    return initPair(&listener, &sender);
}

fn initUDS(allocator: Allocator) !Notifier {
    var tup: TempUdsPath = .{};
    var socket_file: []u8 = try tup.buildPath(allocator);

    const original_sub: []const u8 = "port";
    const replacement: []const u8 = "ntfr";
    const index_opt = std.mem.indexOf(u8, socket_file, original_sub);
    const target_slice: []u8 = socket_file[index_opt.? .. index_opt.? + replacement.len];
    std.mem.copyForwards(u8, target_slice, replacement);

    if (builtin.os.tag == .linux) {
        socket_file[0] = 0;
    }

    var listener = try SCreator.createUdsListener(allocator, socket_file);
    defer listener.deinit();
    var sender = try SCreator.createUdsSocket(socket_file);
    errdefer sender.deinit();
    return initPair(&listener, &sender);
}

fn initPair(listener: *Skt, sender: *Skt) !Notifier {
    var receiver: ?Skt = null;
    errdefer if (receiver) |*r| r.deinit();
    var connected = false;
    for (0..MAX_RETRIES) |_| {
        if (!connected) connected = try sender.connect();
        if (receiver == null) receiver = try listener.accept();
        if (connected and receiver != null) break;
        std.Thread.sleep(SLEEP_NS);
    } else return AmpeError.CommunicationFailed;
    log.info(" notifier sender {d} receiver {d}", .{ sender.rawFd(), receiver.?.rawFd() });
    return .{ .sender = sender.*, .receiver = receiver.? };
}

pub fn sendNotification(ntfr: *Notifier, notif: Notification) AmpeError!void {
    const byte: u8 = @bitCast(notif);
    for (0..100) |_| {
        if (try ntfr.sender.sendBuf(&[1]u8{byte})) |_| return;
        std.Thread.sleep(SLEEP_NS);
    }
    return AmpeError.NotificationFailed;
}

pub fn recvNotification(ntfr: *Notifier) !Notification {
    var byte: [1]u8 = undefined;
    if (try ntfr.receiver.recvToBuf(&byte)) |_| return @bitCast(byte[0]);
    return AmpeError.NotificationFailed;
}

pub fn recv_notification(receiver: *Skt) !Notification {
    var byte: [1]u8 = undefined;
    if (try receiver.recvToBuf(&byte)) |_| return @bitCast(byte[0]);
    return AmpeError.NotificationFailed;
}

pub fn deinit(ntfr: *Notifier) void {
    log.warn("!!! notifiers will be destroyed !!!", .{});
    ntfr.sender.deinit();
    ntfr.receiver.deinit();
}

const tofu = @import("../tofu.zig");
const internal = @import("internal.zig");
const Skt = internal.Skt;
const SCreator = internal.SocketCreator;
const AmpeError = tofu.status.AmpeError;
const TCPServerAddress = tofu.address.TCPServerAddress;
const TCPClientAddress = tofu.address.TCPClientAddress;
const TempUdsPath = tofu.TempUdsPath;
const message = tofu.message;
const status = tofu.status;
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const log = std.log;
const MAX_RETRIES: usize = 10_000;
const SLEEP_NS: u64 = 1 * std.time.ns_per_ms;
