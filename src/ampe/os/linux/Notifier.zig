// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

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
    return initUDS(allocator);
}

fn initUDS(allocator: Allocator) !Notifier {
    var tup: TempUdsPath = .{};

    var socket_file: []u8 = try tup.buildPath(allocator);

    // "regular" uds path looks like:
    // /tmp/tofuYFJ1MWuUSjA.port
    //
    // for notifier it will be:
    // /tmp/tofuYFJ1MWuUSjA.ntfr
    //
    // Get status of notifier UDS on linux
    // ss -x| grep tofu| grep ntfr
    const original_sub: []const u8 = "port";
    const replacement: []const u8 = "ntfr";
    const index_opt = std.mem.indexOf(u8, socket_file, original_sub);
    const target_slice: []u8 = socket_file[index_opt.? .. index_opt.? + replacement.len];
    std.mem.copyForwards(u8, target_slice, replacement);

    // Set as 'abstract socket' - linux only
    socket_file[0] = 0;

    var listSkt: Skt = try SCreator.createUdsListener(allocator, socket_file);
    defer listSkt.deinit();

    // Create sender(client) socket
    var senderSkt: Skt = try SCreator.createUdsSocket(socket_file);
    errdefer senderSkt.deinit();

    _ = try waitConnect(senderSkt.socket.?);

    try posix.connect(senderSkt.socket.?, &listSkt.address.any, listSkt.address.getOsSockLen());

    // Accept a sender connection - create receiver socket
    const receiver_fd = try posix.accept(listSkt.socket.?, null, null, posix.SOCK.NONBLOCK);
    errdefer posix.close(receiver_fd);

    const receiverSkt: Skt = .{ .socket = receiver_fd, .address = listSkt.address };

    log.info(" notifier sender {any} receiver {any}", .{ senderSkt.socket.?, receiver_fd });

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

pub fn recvNotification(ntfr: *Notifier) !FacadeNotifier.Notification {
    const byte = try recvByte(ntfr.receiver.socket.?);
    const ntptr: *const FacadeNotifier.Notification = @ptrCast(&byte);
    return (ntptr.*);
}

pub fn recv_notification(receiver: socket_t) !FacadeNotifier.Notification {
    const byte = try recvByte(receiver);
    const ntptr: *const FacadeNotifier.Notification = @ptrCast(&byte);
    return (ntptr.*);
}

pub inline fn recvByte(receiver: socket_t) !u8 {
    var byte_array: [1]u8 = undefined;
    _ = std.posix.recv(receiver, &byte_array, 0) catch {
        return AmpeError.NotificationFailed;
    };
    return byte_array[0];
}

pub fn sendNotification(ntfr: *Notifier, notif: FacadeNotifier.Notification) AmpeError!void {
    const byteptr: *const u8 = @ptrCast(&notif);

    for (0..10) |_| {
        if (ntfr.isReadyToSend()) {
            return sendByte(ntfr.sender.socket.?, byteptr.*);
        }
    }

    return AmpeError.NotificationFailed;
}

pub fn send_notification(sender: socket_t, notif: FacadeNotifier.Notification) !void {
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

const FacadeNotifier = @import("../../Notifier.zig");

const tofu = @import("../../../tofu.zig");

const internal = @import("../../internal.zig");

const poll_SEC_TIMEOUT: i32 = @import("../../poller.zig").poll_SEC_TIMEOUT;

const TempUdsPath = tofu.TempUdsPath;

const status = tofu.status;
const AmpeError = status.AmpeError;

const Skt = internal.Skt;
const SCreator = internal.SocketCreator;

const std = @import("std");
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
