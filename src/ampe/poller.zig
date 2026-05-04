// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Platform-specific Poller implementation.
/// Selected at compile time based on network backend and OS.
pub const Poller = if (build_options.network == .usockets)
    @import("usockets/usockets_backend.zig").Poller
else switch (builtin.os.tag) {
    .windows => @import("windows/wepoll_backend.zig").Poller,
    .linux => @import("linux/epoll_backend.zig").Poller,
    .macos, .freebsd, .openbsd, .netbsd => @import("mac/kqueue_backend.zig").Poller,
    else => @compileError("unsupported platform"),
};

/// Backward compatibility wrapper.
pub fn PollerOs(comptime backend: type) type {
    _ = backend;
    return Poller;
}

pub const common = @import("common.zig");
pub const poll_INFINITE_TIMEOUT = common.poll_INFINITE_TIMEOUT;
pub const poll_SEC_TIMEOUT = common.poll_SEC_TIMEOUT;
pub const TcIterator = common.TcIterator;

pub const core = @import("core.zig");
pub const triggers = if (build_options.network == .usockets)
    @import("usockets/triggers.zig")
else switch (builtin.os.tag) {
    .windows => @import("windows/triggers.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("mac/triggers.zig"),
    else => @import("linux/triggers.zig"),
};
