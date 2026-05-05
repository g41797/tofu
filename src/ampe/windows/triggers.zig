// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Trigger mapping functions for different polling backends.
//! Converts between application-level Triggers and OS-level event masks.

/// Epoll/wepoll-specific trigger mappings (Linux and Windows).
pub const epoll = struct {
    pub fn toMask(exp: Triggers) u32 {
        var ev: u32 = 0;
        if (exp.recv == .on or exp.accept == .on or exp.notify == .on) ev |= std.os.linux.EPOLL.IN;
        if (exp.send == .on or exp.connect == .on) ev |= std.os.linux.EPOLL.OUT;
        ev |= (std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.PRI);
        return ev;
    }

    pub fn fromMask(rev: u32, exp: Triggers) Triggers {
        var act = Triggers{ .pool = exp.pool };
        if ((rev & (std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.RDHUP)) != 0) act.err = .on;
        if ((rev & std.os.linux.EPOLL.IN) != 0) {
            if (exp.recv == .on) act.recv = .on else if (exp.notify == .on) act.notify = .on else if (exp.accept == .on) act.accept = .on;
        }
        if ((rev & std.os.linux.EPOLL.OUT) != 0) {
            if (exp.send == .on) act.send = .on else if (exp.connect == .on) act.connect = .on;
        }
        return act;
    }
};

const common = @import("../common.zig");

const internal = @import("../internal.zig");
const Triggers = internal.triggeredSkts.Triggers;

const std = @import("std");
