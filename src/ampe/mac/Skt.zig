// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Skt = @This();

socket: ?std.posix.socket_t = null,
address: pn.Addr = std.mem.zeroes(pn.Addr),
server: bool = false,

pub fn isSet(skt: *const Skt) bool {
    return skt.socket != null;
}

pub fn rawFd(skt: *const Skt) i32 {
    return skt.socket orelse -1;
}

pub fn socketHandle(skt: *const Skt) ?std.posix.socket_t {
    return skt.socket;
}

pub fn getPort(skt: *const Skt) ?u16 {
    return pn.addrPort(&skt.address);
}

pub fn listen(skt: *Skt) !void {
    skt.*.server = true;
    skt.*.deleteUDSPath();

    const kernel_backlog: u31 = 1024;
    try skt.*.setREUSE();
    try posix.bind(skt.*.socket.?, @ptrCast(&skt.*.address.mem[0]), @intCast(skt.*.address.len));
    try posix.listen(skt.*.socket.?, kernel_backlog);

    // set address to the OS-chosen information - check for UDS!!!.
    var slen: posix.socklen_t = @intCast(skt.*.address.len);
    try posix.getsockname(skt.*.socket.?, @ptrCast(&skt.*.address.mem[0]), &slen);
    skt.*.address.len = @intCast(slen);

    return;
}

pub fn accept(askt: *Skt) AmpeError!?Skt {
    var skt: Skt = .{};

    var addr: pn.Addr = std.mem.zeroes(pn.Addr);
    addr.len = askt.*.address.len;
    var addr_len: posix.socklen_t = @intCast(askt.*.address.len);

    const flags: u32 = std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;

    skt.socket = acceptOs(
        askt.*.socket.?,
        @ptrCast(&addr.mem[0]),
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

    addr.len = @intCast(addr_len);
    skt.address = addr;

    return skt;
}

pub fn connect(skt: *Skt) AmpeError!bool {
    var connected: bool = true;

    connectOs(
        skt.*.socket.?,
        @ptrCast(&skt.*.address.mem[0]),
        @intCast(skt.*.address.len),
    ) catch |e| switch (e) {
        error.WouldBlock => {
            connected = false;
        },
        error.ConnectionPending => {
            connected = false;
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
    switch (pn.addrFamily(&skt.*.address)) {
        @as(u16, @intCast(std.posix.AF.INET)), @as(u16, @intCast(std.posix.AF.INET6)) => {
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
    // NOTE: Cannot use std.posix.setsockopt because it treats EINVAL as unreachable.
    // On macOS, setsockopt(SO_LINGER) can return EINVAL for certain socket states.
    // Use raw syscall to handle this gracefully.
    const linger_config: Linger = Linger{
        .l_onoff = 1, // Enable linger
        .l_linger = 0, // Set timeout to 0 (immediate abort)
    };

    const rc = system.setsockopt(
        skt.*.socket.?,
        posix.SOL.SOCKET,
        posix.SO.LINGER,
        &std.mem.toBytes(linger_config),
        @sizeOf(Linger),
    );

    if (rc != 0) {
        return AmpeError.SetsockoptFailed;
    }
    return;
}

pub fn disableNagle(skt: *Skt) !void {
    switch (pn.addrFamily(&skt.*.address)) {
        @as(u16, @intCast(std.posix.AF.INET)), @as(u16, @intCast(std.posix.AF.INET6)) => {
            try disable_nagle(skt.*.socket.?);
        },
        else => return,
    }
}

fn deleteUDSPath(skt: *Skt) void {
    if (skt.*.server) {
        if (pn.addrFamily(&skt.*.address) == @as(u16, @intCast(std.posix.AF.UNIX))) {
            const udsPath: []const u8 = pn.addrUnixPath(&skt.*.address);
            if (udsPath.len > 0) {
                std.fs.deleteFileAbsolute(udsPath) catch {};
            }
        }
    }
    return;
}

pub fn findFreeTcpPort() !u16 {
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sockfd);

    if (builtin.os.tag == .linux) {
        try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    var addr: posix.sockaddr.in = .{ .family = posix.AF.INET, .port = 0, .addr = 0 };
    try posix.bind(sockfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(sockfd, @ptrCast(&addr), &addr_len);

    return std.mem.bigToNative(u16, addr.port);
}

pub fn sendBufFd(socket: posix.socket_t, buf: []const u8) AmpeError!?usize {
    var wasSend: usize = 0;
    wasSend = std.posix.send(socket, buf, 0) catch |e| {
        switch (e) {
            std.posix.SendError.WouldBlock => return null,
            std.posix.SendError.ConnectionResetByPeer, std.posix.SendError.BrokenPipe => return AmpeError.PeerDisconnected,
            else => return AmpeError.CommunicationFailed,
        }
    };
    if (wasSend == 0) return null;
    return wasSend;
}

pub fn recvToBufFd(socket: posix.socket_t, buf: []u8) AmpeError!?usize {
    const wasRecv = std.posix.recv(socket, buf, 0) catch |e| {
        switch (e) {
            std.posix.RecvFromError.WouldBlock => return null,
            std.posix.RecvFromError.ConnectionResetByPeer, std.posix.RecvFromError.ConnectionRefused => return AmpeError.PeerDisconnected,
            else => return AmpeError.CommunicationFailed,
        }
    };
    return wasRecv;
}

pub fn sendBuf(skt: *Skt, buf: []const u8) AmpeError!?usize {
    return sendBufFd(skt.socket.?, buf);
}

pub fn recvToBuf(skt: *Skt, buf: []u8) AmpeError!?usize {
    return recvToBufFd(skt.socket.?, buf);
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
        // On Darwin, accept returns c_int; on Linux with accept4, returns usize
        const rc = if (have_accept4)
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
        // Manually set socket flags on Darwin (setSockFlags is not public)
        // O_NONBLOCK value: use @bitCast since posix.O is a packed struct on macOS
        const O_NONBLOCK: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        if (flags & posix.SOCK.NONBLOCK != 0) {
            const current = posix.fcntl(accepted_sock, posix.F.GETFL, 0) catch return error.Unexpected;
            _ = posix.fcntl(accepted_sock, posix.F.SETFL, current | O_NONBLOCK) catch return error.Unexpected;
        }
        if (flags & posix.SOCK.CLOEXEC != 0) {
            const current = posix.fcntl(accepted_sock, posix.F.GETFD, 0) catch return error.Unexpected;
            _ = posix.fcntl(accepted_sock, posix.F.SETFD, current | posix.FD_CLOEXEC) catch return error.Unexpected;
        }
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

const tofu = @import("../../tofu.zig");
const message = tofu.message;
const AmpeError = tofu.status.AmpeError;

const internal = @import("../internal.zig");
const MsgSender = internal.MsgSender;

const pn = @import("posix_net");
