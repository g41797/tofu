// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Poller facade: comptime selects the appropriate backend based on OS.
//! Provides unified interface for epoll (Linux), wepoll (Windows), kqueue (macOS/BSD).

// Re-exports from common module
pub const common = @import("poller/common.zig");
pub const triggers = @import("poller/triggers.zig");

pub const poll_INFINITE_TIMEOUT = common.poll_INFINITE_TIMEOUT;
pub const poll_SEC_TIMEOUT = common.poll_SEC_TIMEOUT;
pub const SeqN = common.SeqN;
pub const TcIterator = common.TcIterator;

/// Comptime backend selection based on target OS.
/// Zero-overhead: only the relevant backend code is compiled.
pub const Poller = switch (builtin.os.tag) {
    .windows => @import("poller/wepoll_backend.zig").Poller,
    .linux => @import("poller/epoll_backend.zig").Poller,
    .macos, .freebsd, .openbsd, .netbsd => @import("poller/kqueue_backend.zig").Poller,
    else => @import("poller/poll_backend.zig").Poller,
};

/// Legacy PollType enum (kept for backward compatibility, will be removed).
pub const PollType = enum {
    poll,
    epoll,
    wepoll,
    kqueue,
};

/// Backward compatibility wrapper.
/// Maps legacy PollerOs(backend) calls to the new unified Poller.
/// Can be removed once all consumers are updated.
pub fn PollerOs(comptime backend: PollType) type {
    _ = backend;
    return Poller;
}

const builtin = @import("builtin");
