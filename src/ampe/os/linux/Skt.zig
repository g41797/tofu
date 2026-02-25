// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Skt = @This();

socket: ?std.posix.socket_t = null,
address: std.net.Address = undefined,
server: bool = false,

pub fn listen(skt: *Skt) !void {
    skt.*.server = true;
    skt.*.deleteUDSPath();

    const kernel_backlog: u31 = 1024;
    try skt.*.setREUSE();
    try posix.bind(skt.*.socket.?, &skt.*.address.any, skt.*.address.getOsSockLen());
    try posix.listen(skt.*.socket.?, kernel_backlog);

    // set address to the OS-chosen information - check for UDS!!!.
    var slen: posix.socklen_t = skt.*.address.getOsSockLen();
    try posix.getsockname(skt.*.socket.?, &skt.*.address.any, &slen);

    return;
}

pub fn accept(askt: *Skt) AmpeError!?Skt {
    var skt: Skt = .{};

    var addr: std.net.Address = undefined;
    var addr_len: posix.socklen_t = askt.*.address.getOsSockLen();

    const flags: u32 = std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;

    skt.socket = acceptOs(
        askt.*.socket.?,
        &addr.any,
        &addr_len,
        flags,
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

    try skt.setLingerAbort();

    skt.address = addr;

    return skt;
}

pub fn connect(skt: *Skt) AmpeError!bool {
    var connected: bool = true;

    connectOs(
        skt.*.socket.?,
        &skt.*.address.any,
        skt.*.address.getOsSockLen(),
    ) catch |e| switch (e) {
        error.WouldBlock => {
            connected = false;
        },
        error.ConnectionPending => {
            connected = true; // for macOs
        },
        error.ConnectionRefused => {
            return AmpeError.PeerDisconnected;
        },
        error.FileNotFound => {
            return AmpeError.UDSPathNotFound;
        },
        else => {
            log.warn("<{d}> connectOs error {s}", .{ getCurrentTid(), @errorName(e) });
            return AmpeError.PeerDisconnected;
        },
    };

    return connected;
}

pub fn setREUSE(skt: *Skt) !void {
    switch (skt.*.address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => {
            if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
                try std.posix.setsockopt(skt.*.socket.?, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
            } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
                try std.posix.setsockopt(skt.*.socket.?, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            }
            try std.posix.setsockopt(skt.*.socket.?, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        },
        else => return,
    }
}

pub const Linger = extern struct {
    l_onoff: c_int, // Option on/off
    l_linger: c_int, // Linger time in seconds
};

pub fn setLingerAbort(skt: *Skt) AmpeError!void {
    // POSIX-specific setsockopt
    const linger_config: Linger = Linger{
        .l_onoff = 1, // Enable linger
        .l_linger = 0, // Set timeout to 0 (immediate abort)
    };

    _ = std.posix.setsockopt(skt.*.socket.?, std.posix.SOL.SOCKET, std.posix.SO.LINGER, &std.mem.toBytes(linger_config)) catch {
        return AmpeError.SetsockoptFailed;
    };
    return;
}

pub fn disableNagle(skt: *Skt) !void {
    switch (skt.*.address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => {
            try disable_nagle(skt.*.socket.?);
        },
        else => return,
    }
}

fn deleteUDSPath(skt: *Skt) void {
    if (skt.*.server) {
        switch (skt.*.address.any.family) {
            std.posix.AF.UNIX => {
                const udsPath: *const [108]u8 = &skt.*.address.un.path;
                const path_len: usize = std.mem.indexOf(u8, udsPath, &[_]u8{0}) orelse udsPath.*.len;
                if (path_len > 0) {
                    std.fs.deleteFileAbsolute(udsPath[0..path_len]) catch {};
                }
            },
            else => {},
        }
    }
    return;
}

pub fn deinit(skt: *Skt) void {
    skt.*.deleteUDSPath();
    skt.*.close();
}

pub fn close(skt: *Skt) void {
    if (skt.*.socket) |socket| {
        _ = skt.*.setLingerAbort() catch {};
        posix.close(socket);
        skt.*.socket = null;
    }
}

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

pub fn connectOs(sock: posix.socket_t, sock_addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    while (true) {
        const erStat: posix.E = posix.errno(posix.system.connect(sock, sock_addr, len));
        const intErrStatus: usize = @intFromEnum(erStat);

        if (intErrStatus == @intFromEnum(E.INTR)) {
            continue;
        }
        if (intErrStatus == @intFromEnum(E.SUCCESS)) {
            return;
        }
        if (intErrStatus == @intFromEnum(E.ISCONN)) {
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
        if (intErrStatus == @intFromEnum(E.NOENT)) {
            return connectError.FileNotFound;
        }

        log.warn("<{d}> posix.system.connect errno {s}", .{ getCurrentTid(), @tagName(erStat) });

        return error.Unexpected;
    }
}

pub fn acceptOs(
    sock: posix.socket_t,
    addr: ?*posix.sockaddr,
    addr_size: ?*posix.socklen_t,
    flags: u32,
) posix.AcceptError!posix.socket_t {
    const have_accept4: bool = !(builtin.target.os.tag.isDarwin() or native_os == .haiku);
    std.debug.assert(0 == (flags & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC))); // Unsupported flag(s)

    const accepted_sock: posix.socket_t = while (true) {
        const rc: usize = if (have_accept4)
            system.accept4(sock, addr, addr_size, flags)
        else
            system.accept(sock, addr, addr_size);

        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .INVAL => return error.SocketNotListening,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return posix.unexpectedErrno(err),
        }
    };

    errdefer posix.close(accepted_sock);

    if (!have_accept4) {
        try posix.setSockFlags(accepted_sock, flags);
    }
    return accepted_sock;
}

pub const connectError = error{
    AccessDenied,
    AlreadyConnected,
    ConnectedAborted,
    _,
} || posix.ConnectError;

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const os = builtin.os.tag;
const system = posix.system;
const E = system.E;
const Thread = std.Thread;
const getCurrentTid = Thread.getCurrentId;
const log = std.log;

const tofu = @import("../../../tofu.zig");
const message = tofu.message;
const AmpeError = tofu.status.AmpeError;

const internal = @import("../../internal.zig");
const MsgSender = internal.MsgSender;
