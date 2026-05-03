// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Platform-specific Poller implementation.
/// Selected at compile time based on network backend and OS.
pub const Poller = if (build_options.network == .usockets)
    @import("poller/usockets_backend.zig").Poller
else switch (builtin.os.tag) {
    .windows => @import("poller/wepoll_backend.zig").Poller,
    .linux => @import("poller/epoll_backend.zig").Poller,
    .macos, .freebsd, .openbsd, .netbsd => @import("poller/kqueue_backend.zig").Poller,
    else => @import("poller/poll_backend.zig").Poller,
};

/// Backward compatibility wrapper.
pub fn PollerOs(comptime backend: type) type {
    _ = backend;
    return Poller;
}

pub const common = @import("poller/common.zig");
pub const poll_INFINITE_TIMEOUT = common.poll_INFINITE_TIMEOUT;
pub const poll_SEC_TIMEOUT = common.poll_SEC_TIMEOUT;
pub const TcIterator = common.TcIterator;

pub const core = @import("poller/core.zig");
pub const triggers = @import("poller/triggers.zig");
