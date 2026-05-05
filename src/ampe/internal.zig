// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const channels = @import("channels.zig");
pub const Notifier = if (build_options.network == .usockets)
    @import("usockets/Notifier.zig")
else
    @import("Notifier.zig");
pub const poller = @import("poller.zig");
pub const Poller = poller.Poller;
pub const Pool = @import("Pool.zig");

const skt_backend = if (build_options.network == .usockets)
    @import("usockets/Skt.zig")
else switch (builtin.os.tag) {
    .windows => @import("windows/Skt.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("mac/Skt.zig"),
    else => @import("linux/Skt.zig"),
};

pub const Skt = skt_backend.Skt;

// For usockets: Socket = LIBUS_SOCKET_DESCRIPTOR equivalent (i32 on POSIX, usize on Windows).
// Inlined to avoid circular import with common.zig (which imports internal.zig for Socket).
pub const Socket = if (build_options.network == .usockets)
    if (builtin.os.tag == .windows) usize else std.posix.fd_t
else switch (builtin.os.tag) {
    .windows => @import("std").os.windows.ws2_32.SOCKET,
    else => @import("std").posix.socket_t,
};

const sc_backend = if (build_options.network == .usockets)
    @import("usockets/SocketCreator.zig")
else switch (builtin.os.tag) {
    .windows => @import("windows/SocketCreator.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("mac/SocketCreator.zig"),
    else => @import("linux/SocketCreator.zig"),
};
pub const SocketCreator = sc_backend.SocketCreator;
pub const triggeredSkts = @import("triggeredSkts.zig");

pub fn initPlatform() AmpeError!void {
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        var wsa_data: ws2_32.WSADATA = undefined;
        if (ws2_32.WSAStartup(0x0202, &wsa_data) != 0) return AmpeError.CommunicationFailed;
    }
}

pub fn deinitPlatform() void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.WSACleanup();
    }
}

const AmpeError = @import("../status.zig").AmpeError;
