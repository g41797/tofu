// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Skt = @This();

socket: ?std.posix.socket_t = null,
address: std.net.Address = undefined,
server: bool = false,

pub fn listen(skt: *Skt) !void {
    skt.server = true;
    skt.deleteUDSPath();

    const kernel_backlog = 1024;
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

    skt.socket = acceptOs(
        askt.socket.?,
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

    try skt.setLingerAbort();

    skt.address = addr;

    return skt;
}

pub fn connect(skt: *Skt) AmpeError!bool {
    var connected = true;

    connectOs(
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
        std.posix.ConnectError.FileNotFound => {
            return AmpeError.UDSPathNotFound;
        },
        else => {
            log.warn("<{d}> connectOs error {s}", .{ getCurrentTid(), @errorName(e) });
            return AmpeError.PeerDisconnected;
        },
    };

    if (connected) {
        // log.debug("CONNECTED FD {x}", .{skt.socket.?});
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

pub const Linger = extern struct {
    l_onoff: c_int, // Option on/off
    l_linger: c_int, // Linger time in seconds
};

pub fn setLingerAbort(skt: *Skt) AmpeError!void {
    if (builtin.os.tag == .windows) {
        // Windows-specific setsockopt for SO_LINGER
        const linger_config = Linger{
            .l_onoff = 1, // Enable linger
            .l_linger = 0, // Set timeout to 0 (immediate abort)
        };
        const optlen: i32 = @intCast(@sizeOf(Linger));
        const setsockopt_res: i32 = ws2_32.setsockopt(skt.socket.?, 0xffff, 0x0080, @ptrCast(&linger_config), optlen);
        if (setsockopt_res == ws2_32.SOCKET_ERROR) {
            std.debug.print("setsockopt(SO_LINGER) failed: {any}\n", .{ws2_32.WSAGetLastError()});
            return AmpeError.SetsockoptFailed;
        }
    } else {
        // POSIX-specific setsockopt (existing code)
        const linger_config = Linger{
            .l_onoff = 1, // Enable linger
            .l_linger = 0, // Set timeout to 0 (immediate abort)
        };

        _ = std.posix.setsockopt(skt.socket.?, std.posix.SOL.SOCKET, std.posix.SO.LINGER, &std.mem.toBytes(linger_config)) catch {
            return AmpeError.SetsockoptFailed;
        };
    }
    return;
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
            std.posix.AF.UNIX => {
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
        if (native_os == .windows) {
            windows.closesocket(socket) catch {};
        }
        else {
            posix.close(socket);
        }
        skt.socket = null;
    }}

pub fn knock(socket: std.posix.socket_t) bool {
    const slice: [1]u8 = .{0};

    _ = MsgSender.sendBufTo(socket, slice[0..0]) catch |err| {
        log.info("knock error {s}", .{@errorName(err)});
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

pub fn connectOs(sock: posix.socket_t, sock_addr: *const posix.sockaddr, len: posix.socklen_t) !void { //ConnectError

    if (native_os == .windows) {
        const rc = windows.ws2_32.connect(sock, sock_addr, @intCast(len));
        if (rc == 0) return;
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEWOULDBLOCK => return error.WouldBlock,
            .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
            .WSAECONNREFUSED => return error.ConnectionRefused,
            .WSAECONNRESET => return error.ConnectionRefused,
            .WSAETIMEDOUT => return error.ConnectionRefused,

            else => error.Unexpected,
        }
        return;
    }



    while (true) {
        const erStat = posix.errno(posix.system.connect(sock, sock_addr, len));

        const intErrStatus = @intFromEnum(erStat);

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

/// Modified std.posix.accept for Linux. Returns error.WouldBlock for non-blocking.
pub fn acceptOs(
    sock: posix.socket_t,
    addr: ?*posix.sockaddr,
    addr_size: ?*posix.socklen_t,
    flags: u32,
) posix.AcceptError!posix.socket_t {
    const have_accept4 = !(builtin.target.os.tag.isDarwin() or native_os == .windows or native_os == .haiku);
    std.debug.assert(0 == (flags & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC))); // Unsupported flag(s)

    const accepted_sock: posix.socket_t = while (true) {
        const rc = if (have_accept4)
            system.accept4(sock, addr, addr_size, flags)
        else if (native_os == .windows)
            windows.accept(sock, addr, addr_size)
        else
            system.accept(sock, addr, addr_size);

        if (native_os == .windows) {
            if (rc == windows.ws2_32.INVALID_SOCKET) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable, // not initialized WSA
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEFAULT => unreachable,
                    .WSAEINVAL => return error.SocketNotListening,
                    .WSAEMFILE => return error.ProcessFdQuotaExceeded,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOBUFS => return error.FileDescriptorNotASocket,
                    .WSAEOPNOTSUPP => return error.OperationNotSupported,
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                break rc;
            }
        } else {
            switch (posix.errno(rc)) {
                .SUCCESS => break @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                // .BADF => unreachable, // always a race condition
                .CONNABORTED => return error.ConnectionAborted,
                // .FAULT => unreachable,
                .INVAL => return error.SocketNotListening,
                // .NOTSOCK => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                // .OPNOTSUPP => unreachable,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    };

    errdefer switch (native_os) {
        .windows => windows.closesocket(accepted_sock) catch unreachable,
        else => close(accepted_sock),
    };
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
const ws2_32 = windows.ws2_32;
const wasi = std.os.wasi;
const system = posix.system;
const E = system.E;
const Allocator = std.mem.Allocator;
const Socket = std.posix.socket_t;
const Thread = std.Thread;
const getCurrentTid = Thread.getCurrentId;

const log = std.log;

// ... (existing code)

