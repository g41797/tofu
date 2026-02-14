// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const builtin = @import("builtin");

pub const backend = switch (builtin.os.tag) {
    .windows => @import("os/windows/poller.zig"),
    else => @import("os/linux/poller.zig"),
};

pub const Poller = backend.Poller;
pub const Poll = if (@hasDecl(backend, "Poll")) backend.Poll else struct {};
pub const poll_INFINITE_TIMEOUT = backend.poll_INFINITE_TIMEOUT;
pub const poll_SEC_TIMEOUT = backend.poll_SEC_TIMEOUT;
