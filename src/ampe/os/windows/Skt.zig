// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

pub const Skt = @This();

socket: ?ws2_32.SOCKET = null,
address: std.net.Address = undefined,
server: bool = false,
base_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

pub fn listen(skt: *Skt) !void {
    skt.*.server = true;
    skt.*.deleteUDSPath();

    const kernel_backlog: c_int = 1024;
    try skt.*.setREUSE();

    const bind_res: i32 = ws2_32.bind(skt.*.socket.?, &skt.*.address.any, @intCast(skt.*.address.getOsSockLen()));
    if (bind_res == ws2_32.SOCKET_ERROR) {
        return error.BindFailed;
    }

    const listen_res: i32 = ws2_32.listen(skt.*.socket.?, kernel_backlog);
    if (listen_res == ws2_32.SOCKET_ERROR) {
        return error.ListenFailed;
    }

    // set address to the OS-chosen information
    var slen: i32 = @intCast(skt.*.address.getOsSockLen());
    const getsockname_res: i32 = ws2_32.getsockname(skt.*.socket.?, &skt.*.address.any, &slen);
    if (getsockname_res == ws2_32.SOCKET_ERROR) {
        return error.GetsocknameFailed;
    }

    return;
}

pub fn accept(askt: *Skt) AmpeError!?Skt {
    var skt: Skt = .{};

    var addr: std.net.Address = undefined;
    var addr_len: i32 = @intCast(askt.*.address.getOsSockLen());

    skt.socket = ws2_32.accept(askt.*.socket.?, &addr.any, &addr_len);

    if (skt.socket == ws2_32.INVALID_SOCKET) {
        const err: ws2_32.WinsockError = ws2_32.WSAGetLastError();
        switch (err) {
            .WSAEWOULDBLOCK => return null,
            .WSAECONNRESET, .WSAECONNABORTED => return AmpeError.PeerDisconnected,
            else => return AmpeError.CommunicationFailed,
        }
    }

    errdefer skt.close();

    try skt.setLingerAbort();

    skt.address = addr;

    return skt;
}

pub fn connect(skt: *Skt) AmpeError!bool {
    const rc: i32 = ws2_32.connect(skt.socket.?, &skt.address.any, @intCast(skt.address.getOsSockLen()));
    if (rc == 0) return true;

    const err: ws2_32.WinsockError = ws2_32.WSAGetLastError();
    switch (err) {
        .WSAEISCONN => return true,
        .WSAEWOULDBLOCK => return false,
        .WSAECONNREFUSED, .WSAECONNRESET, .WSAETIMEDOUT => return AmpeError.ConnectFailed,
        else => {
            log.warn("<{d}> connect error {any}", .{ getCurrentTid(), err });
            return AmpeError.ConnectFailed;
        },
    }
}

pub fn setREUSE(skt: *Skt) !void {
    switch (skt.*.address.any.family) {
        ws2_32.AF.INET, ws2_32.AF.INET6 => {
            const on: c_int = 1;
            _ = ws2_32.setsockopt(skt.*.socket.?, ws2_32.SOL.SOCKET, ws2_32.SO.REUSEADDR, @ptrCast(&on), @sizeOf(c_int));
        },
        else => return,
    }
}

pub const Linger = extern struct {
    l_onoff: u16,
    l_linger: u16,
};

pub fn setLingerAbort(skt: *Skt) AmpeError!void {
    const linger_config: Linger = Linger{
        .l_onoff = 1,
        .l_linger = 0,
    };
    const optlen: i32 = @intCast(@sizeOf(Linger));
    const res: i32 = ws2_32.setsockopt(skt.*.socket.?, 0xffff, 0x0080, @ptrCast(&linger_config), optlen); // 0xffff = SOL_SOCKET, 0x0080 = SO_LINGER
    if (res == ws2_32.SOCKET_ERROR) {
        return AmpeError.SetsockoptFailed;
    }
    return;
}

pub fn disableNagle(skt: *Skt) !void {
    switch (skt.*.address.any.family) {
        ws2_32.AF.INET, ws2_32.AF.INET6 => {
            const on: c_int = 1;
            _ = ws2_32.setsockopt(skt.*.socket.?, ws2_32.IPPROTO.TCP, ws2_32.TCP.NODELAY, @ptrCast(&on), @sizeOf(c_int));
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
        _ = ws2_32.closesocket(socket);
        skt.*.socket = null;
    }
}


pub fn send(skt: *Skt, buf: []const u8) AmpeError!usize {
    const rc: i32 = ws2_32.send(skt.socket.?, buf.ptr, @intCast(buf.len), 0);
    if (rc >= 0) return @intCast(rc);

    const err: ws2_32.WinsockError = ws2_32.WSAGetLastError();
    switch (err) {
        .WSAEWOULDBLOCK => return 0,
        .WSAECONNRESET, .WSAECONNABORTED, .WSAESHUTDOWN => return AmpeError.PeerDisconnected,
        else => {
            log.warn("<{d}> send error {any}", .{ getCurrentTid(), err });
            return AmpeError.CommunicationFailed;
        },
    }
}

pub fn recv(skt: *Skt, buf: []u8) AmpeError!usize {
    const rc: i32 = ws2_32.recv(skt.socket.?, buf.ptr, @intCast(buf.len), 0);
    if (rc > 0) return @intCast(rc);
    if (rc == 0) return AmpeError.PeerDisconnected;

    const err: ws2_32.WinsockError = ws2_32.WSAGetLastError();
    switch (err) {
        .WSAEWOULDBLOCK => return 0,
        .WSAECONNRESET, .WSAECONNABORTED, .WSAESHUTDOWN => return AmpeError.PeerDisconnected,
        else => {
            log.warn("<{d}> recv error {any}", .{ getCurrentTid(), err });
            return AmpeError.CommunicationFailed;
        },
    }
}

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const Thread = std.Thread;
const getCurrentTid = Thread.getCurrentId;
const log = std.log;

const tofu = @import("../../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
