// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const builtin = @import("builtin");

pub const channels = @import("channels.zig");
pub const Notifier = @import("Notifier.zig");
pub const poller = @import("poller.zig");
pub const Poller = poller.PollerOs(if (builtin.os.tag == .windows) .wepoll else .epoll);
pub const Pool = @import("Pool.zig");

const skt_backend = switch (builtin.os.tag) {
    .windows => @import("os/windows/Skt.zig"),
    else => @import("os/linux/Skt.zig"),
};

pub const Skt = skt_backend.Skt;

pub const Socket = switch (builtin.os.tag) {
    .windows => @import("std").os.windows.ws2_32.SOCKET,
    else => @import("std").posix.socket_t,
};

pub const SocketCreator = @import("SocketCreator.zig").SocketCreator;
pub const triggeredSkts = @import("triggeredSkts.zig");
