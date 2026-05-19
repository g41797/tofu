// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Trigger mapping functions for different polling backends.
//! Converts between application-level Triggers and OS-level event masks.

/// Kqueue-specific trigger mappings (macOS/BSD).
pub const kqueue = struct {
    /// Kqueue event type (platform-specific struct).
    pub const Kevent = std.posix.system.Kevent;

    /// EV flags as constants (macOS/BSD use integer constants, not packed struct)
    const EV = std.posix.system.EV;
    const EV_DELETE: u16 = EV.DELETE;
    const EV_ADD_ENABLE: u16 = EV.ADD | EV.ENABLE;

    pub fn toEvents(exp: Triggers, seq: common.SeqN, fd: std.posix.fd_t, evs: []Kevent, is_del: bool) usize {
        var i: usize = 0;
        const flags: u16 = if (is_del) EV_DELETE else EV_ADD_ENABLE;
        if (exp.recv == .on or exp.accept == .on or exp.notify == .on) {
            evs[i] = .{
                .ident = @intCast(fd),
                .filter = std.posix.system.EVFILT.READ,
                .flags = @bitCast(flags),
                .fflags = 0,
                .data = 0,
                .udata = @intCast(seq),
            };
            i += 1;
        }
        if (exp.send == .on or exp.connect == .on) {
            evs[i] = .{
                .ident = @intCast(fd),
                .filter = std.posix.system.EVFILT.WRITE,
                .flags = @bitCast(flags),
                .fflags = 0,
                .data = 0,
                .udata = @intCast(seq),
            };
            i += 1;
        }
        return i;
    }

    pub fn fromEvent(ev: Kevent, exp: Triggers) Triggers {
        var act = Triggers{ .pool = exp.pool };
        const is_err = (ev.flags & std.posix.system.EV.ERROR != 0);
        const is_eof = (ev.flags & std.posix.system.EV.EOF != 0);

        if (ev.filter == std.posix.system.EVFILT.READ) {
            if (is_err) {
                act.err = .on;
            } else if (is_eof) {
                // Peer closed. Trigger recv to drain remaining data.
                // tryRecv will handle the final 0-byte read and return PeerDisconnected.
                act.recv = .on;
            } else {
                if (exp.recv == .on) act.recv = .on else if (exp.notify == .on) act.notify = .on else if (exp.accept == .on) act.accept = .on;
            }
        } else if (ev.filter == std.posix.system.EVFILT.WRITE) {
            if (is_err or is_eof) {
                act.err = .on;
            }
            if (exp.send == .on) act.send = .on else if (exp.connect == .on) act.connect = .on;
        }
        return act;
    }
};

const common = @import("../../../ampe/common.zig");

const internal = @import("../../../ampe/internal.zig");
const Triggers = internal.triggeredSkts.Triggers;

const std = @import("std");
