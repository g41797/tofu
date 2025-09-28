// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Skt = @This();

socket: std.posix.socket_t = undefined,
address: std.net.Address = undefined,
server: bool = false,

pub fn listen(skt: *Skt) !void {
    skt.server = true;
    skt.deleteUDSPath();

    const kernel_backlog = 64;
    try skt.setREUSE();
    try posix.bind(skt.socket, &skt.address.any, skt.address.getOsSockLen());
    try posix.listen(skt.socket, kernel_backlog);

    // set address to the OS-chosen information - check for UDS!!!.
    var slen: posix.socklen_t = skt.address.getOsSockLen();
    try posix.getsockname(skt.socket, &skt.address.any, &slen);

    return;
}

pub fn accept(askt: *Skt) AmpeError!?Skt {
    var skt: Skt = .{};

    var addr: std.net.Address = undefined;
    var addr_len = askt.address.getOsSockLen();

    skt.socket = std.posix.accept(
        askt.socket,
        &addr.any,
        &addr_len,
        std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
    ) catch |e| {
        switch (e) {
            std.posix.AcceptError.WouldBlock => {
                return null;
            },
            std.posix.AcceptError.ConnectionAborted,
            std.posix.AcceptError.ConnectionResetByPeer,
            => return AmpeError.PeerDisconnected,
            else => return AmpeError.CommunicationFailed,
        }
    };
    errdefer posix.close(skt.socket);

    skt.address = addr;

    return skt;
}

pub fn connect(skt: *Skt) AmpeError!bool {
    if (isAlreadyConnected(skt.socket)) {
        return true;
    }

    var connected = true;

    std.posix.connect(
        skt.socket,
        &skt.address.any,
        skt.address.getOsSockLen(),
    ) catch |e| switch (e) {
        std.posix.ConnectError.WouldBlock => {
            connected = false;
        },
        std.posix.ConnectError.ConnectionPending => {
            connected = true; // for macOs
        },
        else => return AmpeError.PeerDisconnected,
    };

    if (connected) {
        log.debug("CONNECTED FD {x}", .{skt.socket});
    }
    return connected;
}

pub fn setREUSE(skt: *Skt) !void {
    switch (skt.address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => {
            if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
                try std.posix.setsockopt(skt.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
            } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
                try std.posix.setsockopt(skt.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            }
            try std.posix.setsockopt(skt.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        },
        else => return,
    }
}

pub fn disableNagle(skt: *Skt) !void {
    switch (skt.address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => {
            // try disable Nagle
            // const tcp_nodelay: c_int = 0;
            // try os.setsockopt(skt.socket, os.IPPROTO.TCP, os.TCP.NODELAY, mem.asBytes(&tcp_nodelay));
            try disable_nagle(skt.socket);
        },
        else => return,
    }
}

// const path_len = std.mem.indexOf(u8, path_slice, &[_]u8{0}) orelse path_slice.len;
fn deleteUDSPath(skt: *Skt) void {
    if (skt.server) {
        switch (skt.address.any.family) {
            std.posix.AF.UNIX => { // REUSEADDR and REUSEPORT are not supported for UDS
                const udsPath = skt.address.un.path[0..108];
                const path_len = std.mem.indexOf(u8, udsPath, &[_]u8{0}) orelse udsPath.len;
                if (path_len > 0) {
                    std.fs.deleteFileAbsolute(skt.address.un.path[0..path_len]) catch {};
                }
            },
            else => {},
        }
    }
    return;
}

pub fn deinit(skt: *Skt) void {
    skt.deleteUDSPath();
    posix.close(skt.socket);
}

pub fn knock(socket: std.posix.socket_t) bool {
    log.debug("knock-knock", .{});

    const slice: [1]u8 = .{0};

    _ = MsgSender.sendBufTo(socket, slice[0..0]) catch |err| {
        log.debug("knock error {s}", .{@errorName(err)});
        return false;
    };

    return true;
}

fn isAlreadyConnected(socket: std.posix.socket_t) bool {
    return knock(socket);
}

//
// https://github.com/tardy-org/tardy/blob/main/src/cross/socket.zig#L39
//
fn disable_nagle(socket: std.posix.socket_t) !void {
    if (comptime os.isBSD()) {
        // system.TCP is weird on MacOS.
        try std.posix.setsockopt(
            socket,
            std.posix.IPPROTO.TCP,
            1,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    } else {
        try std.posix.setsockopt(
            socket,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    }
}

const MsgSender = @import("MsgSender.zig");
const message = @import("../message.zig");
const Trigger = message.Trigger;

const BinaryHeader = message.BinaryHeader;
const Message = message.Message;
const MessageQueue = message.MessageQueue;
const sockets = @import("sockets.zig");
const DBG = @import("../engine.zig").DBG;
const AmpeError = @import("../status.zig").AmpeError;

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const os = builtin.os.tag;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Socket = std.posix.socket_t;

const log = std.log;
