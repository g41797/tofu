// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

pub const Skt = @This();

socket: ?ws2_32.SOCKET = null,
address: std.net.Address = undefined,
server: bool = false,
connecting: bool = false,

// Windows-specific state for AFD polling
base_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
io_status: windows.IO_STATUS_BLOCK = undefined,

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
    if (skt.connecting) {
        // Connection already initiated — check completion via WSAPoll (0ms non-blocking)
        var pfd: ws2_32.pollfd = .{
            .fd = skt.socket.?,
            .events = ws2_32.POLL.WRNORM,
            .revents = 0,
        };
        const poll_rc = ws2_32.WSAPoll(@ptrCast(&pfd), 1, 0);
        if (poll_rc < 0) {
            skt.connecting = false;
            return AmpeError.CommunicationFailed;
        }
        if (poll_rc == 0) return false; // still connecting
        if ((pfd.revents & (ws2_32.POLL.ERR | ws2_32.POLL.HUP)) != 0) {
            skt.connecting = false;
            return AmpeError.PeerDisconnected;
        }
        if ((pfd.revents & ws2_32.POLL.WRNORM) != 0) {
            skt.connecting = false;
            return true;
        }
        return false; // unexpected, treat as still connecting
    }

    const rc: i32 = ws2_32.connect(skt.socket.?, &skt.address.any, @intCast(skt.address.getOsSockLen()));
    if (rc == 0) return true;

    const err: ws2_32.WinsockError = ws2_32.WSAGetLastError();
    switch (err) {
        .WSAEISCONN => return true,
        .WSAEWOULDBLOCK => {
            skt.connecting = true;
            return false;
        },
        .WSAECONNREFUSED, .WSAECONNRESET, .WSAETIMEDOUT => return AmpeError.PeerDisconnected,
        else => {
            log.warn("<{d}> connect error {any}", .{ getCurrentTid(), err });
            return AmpeError.PeerDisconnected;
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
    _ = skt;
    // UDS on Windows is not supported via std.net.Address in Zig 0.15.2
    return;
}

pub fn deinit(skt: *Skt) void {
    skt.*.deleteUDSPath();
    skt.*.close();
}

pub fn close(skt: *Skt) void {
    skt.connecting = false;
    if (skt.*.socket) |socket| {
        _ = ws2_32.closesocket(socket);
        skt.*.socket = null;
    }
}

pub fn knock(socket: ws2_32.SOCKET) bool {
    _ = socket;
    // Knock is used for readiness check in some POSIX implementations.
    // In our Windows AFD/IOCP model, we rely on the poller events.
    return true; 
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
