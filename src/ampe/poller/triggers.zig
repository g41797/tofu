// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Trigger mapping functions for different polling backends.
//! Converts between application-level Triggers and OS-level event masks.

/// Poll-specific trigger mappings (legacy, will be obsolete).
pub const poll = struct {
    pub fn toMask(exp: Triggers) i16 {
        var ev: i16 = 0;
        if (exp.recv == .on or exp.accept == .on or exp.notify == .on) ev |= std.posix.POLL.IN;
        if (exp.send == .on or exp.connect == .on) ev |= std.posix.POLL.OUT;
        return ev;
    }

    pub fn fromMask(rev: i16, exp: Triggers) Triggers {
        var act = Triggers{ .pool = exp.pool };
        if ((rev & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) act.err = .on;
        if ((rev & std.posix.POLL.IN) != 0) {
            if (exp.recv == .on) act.recv = .on else if (exp.notify == .on) act.notify = .on else if (exp.accept == .on) act.accept = .on;
        }
        if ((rev & std.posix.POLL.OUT) != 0) {
            if (exp.send == .on) act.send = .on else if (exp.connect == .on) act.connect = .on;
        }
        return act;
    }
};

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
        if (ev.flags & EV.ERROR != 0) act.err = .on;
        if (ev.filter == std.posix.system.EVFILT.READ) {
            if (exp.recv == .on) act.recv = .on else if (exp.notify == .on) act.notify = .on else if (exp.accept == .on) act.accept = .on;
        }
        if (ev.filter == std.posix.system.EVFILT.WRITE) {
            if (exp.send == .on) act.send = .on else if (exp.connect == .on) act.connect = .on;
        }
        return act;
    }
};

const common = @import("common.zig");

const internal = @import("../internal.zig");
const Triggers = internal.triggeredSkts.Triggers;

const std = @import("std");
