// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const channels = @import("channels.zig");
pub const Notifier = if (build_options.network == .usockets)
    @import("usockets/Notifier.zig")
else switch (builtin.os.tag) {
    .windows => @import("windows/Notifier.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("mac/Notifier.zig"),
    else => @import("linux/Notifier.zig"),
};
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

pub const Socket = if (build_options.network == .usockets)
    std.posix.fd_t // placeholder; will be replaced in Phase 2
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
