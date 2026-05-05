// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("../common.zig");
const SeqN = common.SeqN;
const core = @import("../core.zig");
const triggers_mod = @import("triggers.zig");

const internal = @import("../internal.zig");
const Triggers = internal.triggeredSkts.Triggers;

const tofu = @import("../../tofu.zig");
const AmpeError = tofu.status.AmpeError;

/// Usockets-specific backend implementation (stub).
const UsocketsBackend = struct {
    pub fn init(alktr: Allocator) AmpeError!UsocketsBackend {
        _ = alktr;
        return AmpeError.NotImplementedYet;
    }

    pub fn deinit(self: *UsocketsBackend) void {
        _ = self;
    }

    pub fn register(self: *UsocketsBackend, fd: common.FdType, seq: SeqN, exp: Triggers) AmpeError!void {
        _ = self;
        _ = fd;
        _ = seq;
        _ = exp;
        return AmpeError.NotImplementedYet;
    }

    pub fn modify(self: *UsocketsBackend, fd: common.FdType, seq: SeqN, exp: Triggers) AmpeError!void {
        _ = self;
        _ = fd;
        _ = seq;
        _ = exp;
        return AmpeError.NotImplementedYet;
    }

    pub fn unregister(self: *UsocketsBackend, fd: common.FdType) void {
        _ = self;
        _ = fd;
    }

    pub fn wait(self: *UsocketsBackend, timeout: i32, seqn_trc_map: *core.SeqnTrcMap) AmpeError!Triggers {
        _ = self;
        _ = timeout;
        _ = seqn_trc_map;
        return AmpeError.NotImplementedYet;
    }
};

/// Complete usockets-based Poller type using PollerCore.
pub const Poller = core.PollerCore(UsocketsBackend);
