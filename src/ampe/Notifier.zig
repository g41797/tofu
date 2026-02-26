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
    if (comptime builtin.os.tag == .windows) {
        return initTCP(allocator);
    }
    return initUDS(allocator) catch {
        return initTCP(allocator);
    };
}

fn initTCP(allocator: Allocator) !Notifier {
    var sc: SCreator = SCreator.init(allocator);

    const port: u16 = tofu.FindFreeTcpPort() catch 0;
    const server_addr: tofu.address.TCPServerAddress = tofu.address.TCPServerAddress.init("127.0.0.1", port);

    var listSkt: Skt = try sc.fromAddress(.{ .tcp_server_addr = server_addr });
    defer listSkt.deinit();

    const client_addr: tofu.address.TCPClientAddress = tofu.address.TCPClientAddress.init("127.0.0.1", listSkt.address.getPort());
    var senderSkt: Skt = try sc.fromAddress(.{ .tcp_client_addr = client_addr });
    errdefer senderSkt.deinit();

    // Start connecting
    _ = try senderSkt.connect();

    // Wait for completion (loopback should be fast)
    _ = try waitConnect(senderSkt.socket.?);

    // Accept a sender connection - create receiver socket
    var receiverSkt: Skt = undefined;
    while (true) {
        if (try listSkt.accept()) |s| {
            receiverSkt = s;
            break;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    errdefer receiverSkt.deinit();

    try senderSkt.disableNagle();
    try receiverSkt.disableNagle();

    log.info(" notifier sender {any} receiver {any}", .{ senderSkt.socket.?, receiverSkt.socket.? });

    return .{
        .sender = senderSkt,
        .receiver = receiverSkt,
    };
}

fn initUDS(allocator: Allocator) !Notifier {
    var tup: TempUdsPath = .{};

    var socket_file: []u8 = try tup.buildPath(allocator);

    // "regular" uds path looks like:
    // /tmp/tofuYFJ1MWuUSjA.port (Linux)
    // C:\Users\...\tofu*.port   (Windows)
    //
    // for notifier it will be:
    // /tmp/tofuYFJ1MWuUSjA.ntfr (Linux)
    // C:\Users\...\tofu*.ntfr   (Windows)
    //
    // Get status of notifier UDS on linux
    // ss -x| grep tofu| grep ntfr
    const original_sub: []const u8 = "port";
    const replacement: []const u8 = "ntfr";
    const index_opt = std.mem.indexOf(u8, socket_file, original_sub);
    const target_slice: []u8 = socket_file[index_opt.? .. index_opt.? + replacement.len];
    std.mem.copyForwards(u8, target_slice, replacement);

    // Abstract sockets on Linux only (macOS/BSD and Windows do not support abstract namespace)
    if (builtin.os.tag == .linux) {
        socket_file[0] = 0;
    }

    var listSkt: Skt = try SCreator.createUdsListener(allocator, socket_file);
    defer listSkt.deinit();

    // Create sender(client) socket
    var senderSkt: Skt = try SCreator.createUdsSocket(socket_file);
    errdefer senderSkt.deinit();

    if (builtin.os.tag == .windows) {
        // Windows: initiate non-blocking connect first, then wait for completion
        const connected = try senderSkt.connect();
        if (!connected) {
            _ = try waitConnect(senderSkt.socket.?);
        }
    } else {
        // Linux: wait for socket readiness, then raw connect
        _ = try waitConnect(senderSkt.socket.?);
        try posix.connect(senderSkt.socket.?, &listSkt.address.any, listSkt.address.getOsSockLen());
    }

    // Accept a sender connection - create receiver socket
    var receiverSkt: Skt = undefined;
    while (true) {
        if (try listSkt.accept()) |s| {
            receiverSkt = s;
            break;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    errdefer receiverSkt.deinit();

    log.info(" notifier sender {any} receiver {any}", .{ senderSkt.socket.?, receiverSkt.socket.? });

    return .{
        .sender = senderSkt,
        .receiver = receiverSkt,
    };
}

pub fn isReadyToRecv(ntfr: *Notifier) bool {
    return _isReadyToRecv(ntfr.receiver.socket.?);
}

pub fn _isReadyToRecv(receiver: socket_t) bool {
    var rpoll: [1]pollfd = .{
        .{
            .fd = receiver,
            .events = POLL.IN,
            .revents = 0,
        },
    };

    const pollstatus = posix.poll(&rpoll, poll_SEC_TIMEOUT) catch {
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
    return _isReadyToSend(ntfr.sender.socket.?);
}

pub fn _isReadyToSend(sender: socket_t) bool {
    var spoll: [1]pollfd = .{
        .{
            .fd = sender,
            .events = POLL.OUT,
            .revents = 0,
        },
    };

    const pollstatus = posix.poll(&spoll, poll_SEC_TIMEOUT * 2) catch |err| {
        log.warn(" !!! notifier {any} poll error {s}", .{ spoll[0].fd, @errorName(err) });
        return false;
    };

    if (pollstatus == 0) {
        return false;
    }

    if (spoll[0].revents & std.posix.POLL.HUP != 0) {
        log.warn(" !!! notifier socket {any} error HUP", .{spoll[0].fd});
        return false;
    }

    return true;
}

pub fn waitConnect(client: socket_t) !bool {
    var spoll: [1]pollfd = undefined;

    while (true) {
        spoll = .{
            .{
                .fd = client,
                .events = POLL.OUT,
                .revents = 0,
            },
        };

        const pollstatus = try posix.poll(&spoll, poll_SEC_TIMEOUT * 3);

        if (pollstatus == 1) {
            break;
        }
    }

    if (spoll[0].revents & std.posix.POLL.HUP != 0) {
        return false;
    }

    return true;
}

pub fn recvNotification(ntfr: *Notifier) !Notification {
    const byte = try recvByte(ntfr.receiver.socket.?);
    const ntptr: *const Notification = @ptrCast(&byte);
    return (ntptr.*);
}

pub fn recv_notification(receiver: socket_t) !Notification {
    const byte = try recvByte(receiver);
    const ntptr: *const Notification = @ptrCast(&byte);
    return (ntptr.*);
}

pub inline fn recvByte(receiver: socket_t) !u8 {
    var byte_array: [1]u8 = undefined;
    _ = std.posix.recv(receiver, &byte_array, 0) catch {
        return AmpeError.NotificationFailed;
    };
    return byte_array[0];
}

pub fn sendNotification(ntfr: *Notifier, notif: Notification) AmpeError!void {
    const byteptr: *const u8 = @ptrCast(&notif);

    for (0..10) |_| {
        if (ntfr.isReadyToSend()) {
            return sendByte(ntfr.sender.socket.?, byteptr.*);
        }
    }

    return AmpeError.NotificationFailed;
}

pub fn send_notification(sender: socket_t, notif: Notification) !void {
    const byteptr: *const u8 = @ptrCast(&notif);
    return sendByte(sender, byteptr.*);
}

pub inline fn sendByte(sender: socket_t, notif: u8) AmpeError!void {
    var byte_array = [_]u8{notif};
    _ = std.posix.send(sender, &byte_array, 0) catch |err| {
        log.warn(" !!! notifier {any} send error {s}", .{ sender, @errorName(err) });
        return AmpeError.NotificationFailed;
    };
    return;
}

pub fn deinit(ntfr: *Notifier) void {
    log.warn("!!! notifiers will be destroyed !!!", .{});

    ntfr.sender.deinit();
    ntfr.receiver.deinit();
}

const tofu = @import("../tofu.zig");

const internal = @import("internal.zig");

const poll_SEC_TIMEOUT: i32 = @import("poller.zig").poll_SEC_TIMEOUT;

const TempUdsPath = tofu.TempUdsPath;

const message = tofu.message;

const status = tofu.status;
const AmpeError = status.AmpeError;

const Skt = internal.Skt;
const SCreator = internal.SocketCreator;

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket_t = posix.socket_t;
const system = posix.system;
const pollfd = posix.pollfd;
const POLL = system.POLL;
const Allocator = std.mem.Allocator;

// Get list of connected uds
// ss -x|grep tofu

// Get list of connected notifiers
// ss -x|grep ntfr

const log = std.log;
