// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const TempUdsPath = struct {
    tempFile: temp.TempFile = undefined,
    socket_path: [104:0]u8 = undefined,

    pub fn buildPath(tup: *TempUdsPath, allocator: Allocator) ![]u8 {
        tup.tempFile = try temp.create_file(allocator, "yaaamp*.port");
        tup.tempFile.retain = false;
        defer tup.tempFile.deinit();

        const socket_file = tup.tempFile.parent_dir.realpath(tup.tempFile.basename, tup.socket_path[0..104]) catch {
            return AmpeError.UnknownError;
        };

        // Remove socket file if it exists
        tup.tempFile.parent_dir.deleteFile(tup.tempFile.basename) catch {};
        return socket_file;
    }
};

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

    // tardy: poll.zig - slightly changed
    if (comptime false) { // was builtin.os.tag == .macos
        const server_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(server_socket);

        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        try std.posix.bind(server_socket, &addr.any, addr.getOsSockLen());

        var binded_addr: std.posix.sockaddr = undefined;
        var binded_size: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        try std.posix.getsockname(server_socket, &binded_addr, &binded_size);

        try std.posix.listen(server_socket, 1);

        const write_end = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(write_end);

        _ = try waitConnect(write_end);

        try std.posix.connect(write_end, &binded_addr, binded_size);

        const read_end = try std.posix.accept(server_socket, null, null, std.posix.SOCK.NONBLOCK);
        errdefer std.posix.close(read_end);

        return .{
            .sender = write_end,
            .receiver = read_end,
        };
    }

    var tup: TempUdsPath = .{};

    const socket_file = try tup.buildPath(allocator);

    var listSkt = try SCreator.createUdsListener(allocator, socket_file);
    defer listSkt.deinit();

    // Create sender(client) socket
    var senderSkt = try SCreator.createUdsSocket(socket_file);
    errdefer senderSkt.deinit();

    _ = try waitConnect(senderSkt.socket);

    try posix.connect(senderSkt.socket, &listSkt.address.any, listSkt.address.getOsSockLen());

    // Accept a sender connection - create receiver socket
    const receiver_fd = try posix.accept(listSkt.socket, null, null, posix.SOCK.NONBLOCK);
    errdefer posix.close(receiver_fd);

    return .{
        .sender = senderSkt.socket,
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

// pub fn waitConnect(client: socket_t) !bool {
//     var spoll: [1]pollfd = undefined;
//
//     while (true) {
//         spoll = .{
//             .{
//                 .fd = client,
//                 .events = POLL.OUT,
//                 .revents = 0,
//             },
//         };
//
//         const pollstatus = try posix.poll(&spoll, SEC_TIMEOUT_MS * 3);
//
//         if (pollstatus == 1) {
//             break;
//         }
//     }
//
//     if (spoll[0].revents & std.posix.POLL.HUP != 0) {
//         return false;
//     }
//
//     return true;
// }

pub fn recvNotification(ntfr: *Notifier) !Notification {
    const byte = try recvByte(ntfr.receiver);
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

pub fn sendNotification(ntfr: *Notifier, notif: Notification) !void {
    const byteptr: *const u8 = @ptrCast(&notif);

    for (0..10) |_| {
        if (ntfr.isReadyToSend()) {
            return sendByte(ntfr.sender, byteptr.*);
        }
    }

    return AmpeError.NotificationFailed;
}

pub fn send_notification(sender: socket_t, notif: Notification) !void {
    const byteptr: *const u8 = @ptrCast(&notif);
    return sendByte(sender, byteptr.*);
}

pub inline fn sendByte(sender: socket_t, notif: u8) !void {
    var byte_array = [_]u8{notif};
    _ = std.posix.send(sender, &byte_array, 0) catch {
        return AmpeError.NotificationFailed;
    };
    return;
}

pub fn sendAck(ntfr: *Notifier, ack: u8) !void {
    for (0..10) |_| {
        if (_isReadyToSend(ntfr.receiver)) {
            return sendByte(ntfr.receiver, ack);
        }
    }

    return AmpeError.NotificationFailed;
}

pub fn recvAck(ntfr: *Notifier) !u8 {
    for (0..10) |_| {
        if (_isReadyToRecv(ntfr.sender)) {
            return recvByte(ntfr.sender);
        }
    }
    return AmpeError.NotificationFailed;
}

pub fn deinit(ntfr: *Notifier) void {
    posix.close(ntfr.sender);
    posix.close(ntfr.receiver);
}

const ValidCombination = @import("../message.zig").ValidCombination;

const status = @import("../status.zig");
const AmpeError = status.AmpeError;

const sockets = @import("sockets.zig");
const Skt = sockets.Skt;
const SCreator = sockets.SocketCreator;

const temp = @import("temp");
const nats = @import("nats");

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket_t = posix.socket_t;
const system = posix.system;
const pollfd = posix.pollfd;
const POLL = system.POLL;
const Allocator = std.mem.Allocator;

// Get list of connected uds
// ss -x|grep yaaamp

// 2DO  Add Windows implementation: TCP 127.0.0.1:0 instead of UDS

// Grok generated from former waitConnect
// Define kqueue constants for macOS
pub fn waitConnect(client: posix.socket_t) !bool {
    log.debug("TRY WAITCONNECT ON FD {x}", .{client});
    defer log.debug("FINISH WAITCONNECT ON FD {x}", .{client});
    if (comptime false) { // grok version below
        // Compile-time OS detection
        switch (builtin.os.tag) {
            .linux => {
                // Linux implementation using poll
                var spoll: [1]posix.pollfd = .{
                    .{
                        .fd = client,
                        .events = posix.POLL.OUT,
                        .revents = 0,
                    },
                };

                const timeout_ms = 3000; // Assuming SEC_TIMEOUT_MS is 1000
                const pollstatus = try posix.poll(&spoll, timeout_ms);

                if (pollstatus == 0) {
                    return false;
                }

                if (spoll[0].revents & posix.POLL.HUP != 0) {
                    return false;
                }

                return true;
            },
            .macos => {
                // macOS implementation using kqueue
                const kq = try posix.kqueue();
                defer posix.close(kq);

                var changelist: [1]posix.Kevent = .{
                    .{
                        .ident = @intCast(client),
                        .filter = KqueueConstants.EVFILT_WRITE,
                        .flags = KqueueConstants.EV_ADD | KqueueConstants.EV_ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = 0,
                    },
                };

                const timeout_ms = 3000; // Assuming SEC_TIMEOUT_MS is 1000
                var timeout = posix.timespec{
                    .sec = timeout_ms / 1000,
                    .nsec = (timeout_ms % 1000) * 1_000_000,
                };

                var eventlist: [1]posix.Kevent = undefined;
                const nevents = try posix.kevent(kq, &changelist, &eventlist, &timeout);

                if (nevents == 0) {
                    return false;
                }

                if (eventlist[0].flags & KqueueConstants.EV_ERROR != 0 or
                    eventlist[0].flags & KqueueConstants.EV_EOF != 0)
                {
                    return false;
                }

                return true;
            },
            else => @compileError("Unsupported OS: waitConnect is only implemented for Linux (poll) and macOS (kqueue)."),
        }
    } else { //chatgpt version
        if (builtin.os.tag == .linux) {
            return waitConnectLinux(client);
        } else if (builtin.os.tag == .macos) {
            return waitConnectMacos(client);
        } else {
            @compileError("waitConnect is only implemented for Linux and macOS.");
        }
    }
}

fn waitConnectLinux(client: posix.socket_t) !bool {
    var spoll: [1]posix.pollfd = undefined;

    while (true) {
        spoll = .{
            .{
                .fd = client,
                .events = posix.POLL.OUT,
                .revents = 0,
            },
        };

        const pollstatus = try posix.poll(&spoll, SEC_TIMEOUT_MS * 3);

        if (pollstatus == 1) {
            break;
        }
    }

    if (spoll[0].revents & posix.POLL.HUP != 0) {
        return false;
    }

    return true;
}

fn waitConnectMacos(client: posix.socket_t) !bool {
    const kq = try posix.kqueue();
    defer posix.close(kq);

    const change: posix.Kevent = .{
        .ident = @intCast(client),
        .filter = KqueueConstants.EVFILT_WRITE,
        .flags = KqueueConstants.EV_ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };

    _ = try posix.kevent(kq, &.{change}, &.{}, null);

    var ts: posix.timespec = .{
        .sec = SEC_TIMEOUT_MS * 3 / 1000,
        .nsec = (SEC_TIMEOUT_MS * 3 % 1000) * 1_000_000,
    };

    var ev: [1]posix.Kevent = undefined;

    while (true) {
        const n = try posix.kevent(kq, &.{}, &ev, &ts);
        if (n == 0) {
            continue;
        }
        if (n == 1) {
            break;
        }
    }

    if ((ev[0].flags & KqueueConstants.EV_ERROR) != 0 or
        (ev[0].flags & KqueueConstants.EV_EOF) != 0)
    {
        return false;
    }

    return true;
}

const KqueueConstants = if (builtin.os.tag == .macos) struct {
    const EVFILT_WRITE: i16 = -2; // From sys/event.h
    const EV_ADD: u16 = 0x0001;
    const EV_ONESHOT: u16 = 0x0010;
    const EV_ERROR: u16 = 0x4000;
    const EV_EOF: u16 = 0x8000;
} else struct {};

const log = std.log;
