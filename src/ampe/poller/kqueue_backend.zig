// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! macOS/BSD kqueue-based backend implementation.
//! Complete kqueue implementation with no comptime branches inside functions.

/// Kqueue event type (platform-specific struct).
const Kevent = std.posix.system.Kevent;

/// Kqueue-specific backend implementation.
const KqueueBackend = struct {
    kqfd: std.posix.fd_t,
    event_buffer: std.ArrayList(Kevent),
    allocator: Allocator,

    pub fn init(alktr: Allocator) AmpeError!KqueueBackend {
        const kqfd = std.posix.kqueue() catch return AmpeError.AllocationFailed;
        return .{
            .kqfd = kqfd,
            .event_buffer = std.ArrayList(Kevent).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
            .allocator = alktr,
        };
    }

    pub fn deinit(self: *KqueueBackend) void {
        self.event_buffer.deinit(self.allocator);
        std.posix.close(self.kqfd);
    }

    pub fn register(self: *KqueueBackend, fd: std.posix.fd_t, seq: SeqN, exp: Triggers) AmpeError!void {
        var evs: [2]Kevent = undefined;
        const count = triggers_mod.kqueue.toEvents(exp, seq, fd, &evs, false);
        if (count > 0) {
            _ = std.posix.kevent(self.kqfd, evs[0..count], &.{}, null) catch return AmpeError.CommunicationFailed;
        }
    }

    pub fn modify(self: *KqueueBackend, fd: std.posix.fd_t, seq: SeqN, exp: Triggers) AmpeError!void {
        var evs: [2]Kevent = undefined;

        // READ filter
        const r_on = (exp.recv == .on or exp.accept == .on or exp.notify == .on);
        evs[0] = .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT.READ,
            .flags = if (r_on) std.posix.system.EV.ADD | std.posix.system.EV.ENABLE else std.posix.system.EV.ADD | std.posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = @intCast(seq),
        };

        // WRITE filter
        const w_on = (exp.send == .on or exp.connect == .on);
        evs[1] = .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT.WRITE,
            .flags = if (w_on) std.posix.system.EV.ADD | std.posix.system.EV.ENABLE else std.posix.system.EV.ADD | std.posix.system.EV.DISABLE,
            .fflags = 0,
            .data = 0,
            .udata = @intCast(seq),
        };

        _ = std.posix.kevent(self.kqfd, &evs, &.{}, null) catch return AmpeError.CommunicationFailed;
    }

    pub fn unregister(self: *KqueueBackend, fd: std.posix.fd_t) void {
        var evs: [2]Kevent = undefined;
        // Delete both READ and WRITE filters
        evs[0] = .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT.READ,
            .flags = std.posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        evs[1] = .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT.WRITE,
            .flags = std.posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        // Ignore errors on unregister (fd may already be closed)
        _ = std.posix.kevent(self.kqfd, evs[0..2], &.{}, null) catch {};
    }

    pub fn wait(self: *KqueueBackend, timeout: i32, seqn_trc_map: *core.SeqnTrcMap) AmpeError!Triggers {
        var total_act = Triggers{};

        self.event_buffer.clearRetainingCapacity();
        self.event_buffer.ensureTotalCapacity(self.allocator, seqn_trc_map.count()) catch return AmpeError.AllocationFailed;

        const ts: ?std.posix.system.timespec = if (timeout < 0) null else .{
            .sec = @intCast(@divTrunc(timeout, 1000)),
            .nsec = @intCast(@mod(timeout, 1000) * 1_000_000),
        };

        const n = std.posix.kevent(self.kqfd, &.{}, self.event_buffer.unusedCapacitySlice(), if (ts) |*t| t else null) catch return AmpeError.CommunicationFailed;

        if (n == 0) {
            total_act.timeout = .on;
        } else {
            for (self.event_buffer.unusedCapacitySlice()[0..n]) |ev| {
                if (seqn_trc_map.get(@intCast(ev.udata))) |tc| {
                    const os_act = triggers_mod.kqueue.fromEvent(ev, tc.exp);
                    tc.act = tc.act.lor(os_act);
                    total_act = total_act.lor(tc.act);
                }
            }
        }

        return total_act;
    }
};

/// Complete kqueue-based Poller type using PollerCore.
pub const Poller = core.PollerCore(KqueueBackend);

const common = @import("common.zig");
const SeqN = common.SeqN;
const core = @import("core.zig");
const triggers_mod = @import("triggers.zig");

const internal = @import("../internal.zig");
const Triggers = internal.triggeredSkts.Triggers;

const tofu = @import("../../tofu.zig");
const AmpeError = tofu.status.AmpeError;

const std = @import("std");
const Allocator = std.mem.Allocator;
