// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

pub const poll_INFINITE_TIMEOUT: u32 = std.math.maxInt(i32);
pub const poll_SEC_TIMEOUT: i32 = 1_000;

pub const Poller = union(enum) {
    afd: AfdPoller,

    pub fn waitTriggers(self: *Poller, it: ?Reactor.Iterator, timeout: i32) AmpeError!Triggers {
        _ = self;
        _ = it;
        _ = timeout;
        // Production Poller implementation will go here
        return error.NotImplemented;
    }

    pub fn deinit(self: *const Poller) void {
        switch (self.*) {
            .afd => self.*.afd.deinit(),
        }
        return;
    }
};

pub const afd = @import("afd.zig");
pub const ntdllx = @import("ntdllx.zig");
pub const AfdPoller = afd.AfdPoller;

const std = @import("std");
const tofu = @import("../../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
const Reactor = tofu.Reactor;
const Triggers = tofu.@"internal usage".triggeredSkts.Triggers;
