// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Skt = @This();

socket: ?std.posix.socket_t = null,
address: std.net.Address = undefined,
server: bool = false,

pub fn listen(skt: *Skt) !void {
    skt.server = true;
    skt.deleteUDSPath();

    const kernel_backlog = 64;
    try skt.setREUSE();
    try posix.bind(skt.socket.?, &skt.address.any, skt.address.getOsSockLen());
    try posix.listen(skt.socket.?, kernel_backlog);

    // set address to the OS-chosen information - check for UDS!!!.
    var slen: posix.socklen_t = skt.address.getOsSockLen();
    try posix.getsockname(skt.socket.?, &skt.address.any, &slen);

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
    errdefer skt.close();

    skt.address = addr;

    return skt;
}

pub fn connect(skt: *Skt) AmpeError!bool {
    if (isAlreadyConnected(skt.socket.?)) {
        return true;
    }

    var connected = true;

    connectPosix(
        skt.socket.?,
        &skt.address.any,
        skt.address.getOsSockLen(),
    ) catch |e| switch (e) {
        std.posix.ConnectError.WouldBlock => {
            connected = false;
        },
        std.posix.ConnectError.ConnectionPending => {
            connected = true; // for macOs
        },
        std.posix.ConnectError.ConnectionRefused => {
            return AmpeError.PeerDisconnected;
        },
        else => return AmpeError.PeerDisconnected,
    };

    if (connected) {
        log.debug("CONNECTED FD {x}", .{skt.socket.?});
    }
    return connected;
}

pub fn setREUSE(skt: *Skt) !void {
    switch (skt.address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => {
            if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
                try std.posix.setsockopt(skt.socket.?, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
            } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
                try std.posix.setsockopt(skt.socket.?, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            }
            try std.posix.setsockopt(skt.socket.?, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
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
            try disable_nagle(skt.socket.?);
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
    skt.close();
}

pub fn close(skt: *Skt) void {
    if (skt.socket) |socket| {
        posix.close(socket);
        skt.socket = null;
    }
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

pub fn connectPosix(sock: posix.socket_t, sock_addr: *const posix.sockaddr, len: posix.socklen_t) !void { //ConnectError
    while (true) {
        const erStat = posix.errno(posix.system.connect(sock, sock_addr, len));

        const intErrStatus = @intFromEnum(erStat);

        if (intErrStatus == @intFromEnum(E.INTR)) {
            continue;
        }
        if (intErrStatus == @intFromEnum(E.SUCCESS)) {
            return;
        }
        if (intErrStatus == @intFromEnum(E.AGAIN)) {
            return error.WouldBlock;
        }
        if (intErrStatus == @intFromEnum(E.INPROGRESS)) {
            return error.WouldBlock;
        }
        if (intErrStatus == @intFromEnum(E.ALREADY)) {
            return error.ConnectionPending;
        }
        if (intErrStatus == @intFromEnum(E.CONNREFUSED)) {
            return error.ConnectionRefused;
        }
        if (intErrStatus == @intFromEnum(E.CONNABORTED)) {
            return connectError.ConnectedAborted;
        }
        return error.Unexpected;

        // switch (intErrStatus) {
        //     @intFromEnum(E.SUCCESS) => return,
        //     @intFromEnum(E.ACCES) => return connectError.AccessDenied,
        //     @intFromEnum(E.PERM) => return error.PermissionDenied,
        //     @intFromEnum(E.ADDRINUSE) => return error.AddressInUse,
        //     @intFromEnum(E.ADDRNOTAVAIL) => return error.AddressNotAvailable,
        //     @intFromEnum(E.AFNOSUPPORT) => return error.AddressFamilyNotSupported,
        //     @intFromEnum(E.AGAIN), @intFromEnum(E.INPROGRESS) => return error.WouldBlock,
        //     @intFromEnum(E.ALREADY) => return error.ConnectionPending,
        //     @intFromEnum(E.BADF) => unreachable, // sockfd is not a valid open file descriptor.
        //     @intFromEnum(E.CONNREFUSED) => return error.ConnectionRefused,
        //     @intFromEnum(E.CONNRESET) => return error.ConnectionResetByPeer,
        //     @intFromEnum(E.FAULT) => error.Unexpected, // The socket structure address is outside the user's address space.
        //     @intFromEnum(E.INTR) => continue,
        //     @intFromEnum(E.ISCONN) => return connectError.AlreadyConnected, // The socket is already connected.
        //     @intFromEnum(E.HOSTUNREACH) => return error.NetworkUnreachable,
        //     @intFromEnum(E.NETUNREACH) => return error.NetworkUnreachable,
        //     @intFromEnum(E.NOTSOCK) => error.Unexpected, // The file descriptor sockfd does not refer to a socket.
        //     @intFromEnum(E.PROTOTYPE) => error.Unexpected, // The socket type does not support the requested communications protocol.
        //     @intFromEnum(E.TIMEDOUT) => return error.ConnectionTimedOut,
        //     @intFromEnum(E.NOENT) => return error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
        //     @intFromEnum(E.CONNABORTED) => return connectError.ConnectedAborted,
        //     // _ => return error.Unexpected,
        //     // else => return error.Unexpected,
        //     // else =>  | _ | return error.Unexpected,
        //     else =>  |err| return posix.unexpectedErrno(@enumFromInt(err)),
        // }
    }
}

pub const connectError = error{
    AccessDenied,
    AlreadyConnected,
    ConnectedAborted,
    _,
} || posix.ConnectError;

const tofu = @import("../tofu.zig");
const message = tofu.message;
const Trigger = message.Trigger;

const BinaryHeader = message.BinaryHeader;
const Message = message.Message;

const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;

const internal = @import("internal.zig");
const MsgSender = internal.MsgSender;
const sockets = internal.sockets;

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const os = builtin.os.tag;
const linux = std.os.linux;
const windows = std.os.windows;
const wasi = std.os.wasi;
const system = posix.system;
const E = system.E;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Socket = std.posix.socket_t;

const log = std.log;
