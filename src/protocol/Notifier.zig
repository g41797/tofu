// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const SEC_TIMEOUT_MS = 1_000;
const INFINITE_TIMEOUT_MS = -1;

pub const Notifier = @This();

sender: socket_t = undefined,
receiver: socket_t = undefined,

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
    var rpoll: pollfd = .{
        .fd = ntfr.receiver,
        .events = POLL.IN,
        .revents = 0,
    };

    const cpoll: [*c]pollfd = &rpoll;

    const pollstatus = system.poll(cpoll, 1, SEC_TIMEOUT_MS);

    if (pollstatus == 0) {
        return false;
    }

    if (rpoll.revents & std.posix.POLL.HUP != 0) {
        return false;
    }

    return true;
}

pub fn isReadyToSend(ntfr: *Notifier) bool {
    var spoll: pollfd = .{
        .fd = ntfr.sender,
        .events = POLL.OUT,
        .revents = 0,
    };
    const cpoll: [*c]pollfd = &spoll;

    const pollstatus = system.poll(cpoll, 1, SEC_TIMEOUT_MS);

    if (pollstatus == 0) {
        return false;
    }

    if (spoll.revents & std.posix.POLL.HUP != 0) {
        return false;
    }

    return true;
}

pub fn recvNotification(ntfr: *Notifier) !u8 {
    var byte_array: [1]u8 = undefined;
    _ = std.posix.recv(ntfr.receiver, &byte_array, 0) catch |err| {
        return err;
    };
    return byte_array[0];
}

pub fn sendNotification(ntfr: *Notifier, notif: u8) !void {
    var byte_array = [_]u8{notif};
    _ = std.posix.send(ntfr.sender, &byte_array, 0) catch |err| {
        return err;
    };
    return;
}

pub fn deinit(ntfr: *Notifier) void {
    posix.close(ntfr.sender);
    posix.close(ntfr.receiver);
}

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
