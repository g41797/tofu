// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const isPosixNet: bool = (build_options.network == .posixnet);

const skt_backend = if (isPosixNet)
    switch (builtin.os.tag) {
        .linux => @import("../platform/posixnet/linux/Skt.zig").Skt,
        .macos => @import("../platform/posixnet/mac/Skt.zig").Skt,
        .windows => @import("../platform/posixnet/windows/Skt.zig").Skt,
        else => @compileError("posixnet backend: unsupported OS"),
    }
else switch (builtin.os.tag) {
    .windows => @import("../platform/stdposix/windows/Skt.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("../platform/stdposix/mac/Skt.zig"),
    else => @import("../platform/stdposix/linux/Skt.zig"),
};

pub const Skt = skt_backend.Skt;

// For posixnet: Socket = LIBUS_SOCKET_DESCRIPTOR equivalent (i32 on POSIX, usize on Windows).
// Inlined to avoid circular import with common.zig (which imports internal.zig for Socket).
pub const Socket = if (isPosixNet)
    if (builtin.os.tag == .windows) usize else std.posix.fd_t
else switch (builtin.os.tag) {
    .windows => @import("std").os.windows.ws2_32.SOCKET,
    else => @import("std").posix.socket_t,
};

const sc_backend = if (isPosixNet)
    switch (builtin.os.tag) {
        .linux => @import("../platform/posixnet/linux/SocketCreator.zig").SocketCreator,
        .macos => @import("../platform/posixnet/mac/SocketCreator.zig").SocketCreator,
        .windows => @import("../platform/posixnet/windows/SocketCreator.zig").SocketCreator,
        else => @compileError("posixnet backend: unsupported OS"),
    }
else switch (builtin.os.tag) {
    .windows => @import("../platform/stdposix/windows/SocketCreator.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("../platform/stdposix/mac/SocketCreator.zig"),
    else => @import("../platform/stdposix/linux/SocketCreator.zig"),
};
pub const SocketCreator = sc_backend.SocketCreator;
pub const triggeredSkts = @import("triggeredSkts.zig");


pub fn initPlatform() AmpeError!void {
    if (!isPosixNet) {
        if (builtin.os.tag == .windows) {
            const ws2_32 = std.os.windows.ws2_32;
            var wsa_data: ws2_32.WSADATA = undefined;
            if (ws2_32.WSAStartup(0x0202, &wsa_data) != 0) return AmpeError.CommunicationFailed;
        }
    }
    else {
        if (pn.startup_sockets() != 0){
            return AmpeError.CommunicationFailed;
        }
    }
}

pub fn deinitPlatform() void {
    if (!isPosixNet) {
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.ws2_32.WSACleanup();
        }
    }
    else {
       pn.cleanup_sockets();
    }
}

pub const RunCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
};

const AmpeError = @import("../status.zig").AmpeError;

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const pn = @import("posix_net");

pub const channels = @import("channels.zig");
pub const Notifier = @import("Notifier.zig");
pub const poller = @import("poller.zig");
pub const Poller = poller.Poller;
pub const Pool = @import("Pool.zig");
pub const Appendable = @import("Appendable.zig");
