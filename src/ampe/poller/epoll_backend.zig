// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Linux epoll-based backend implementation.
//! Complete epoll implementation with no comptime branches inside functions.

/// Epoll-specific backend implementation.
const EpollBackend = struct {
    epfd: std.posix.fd_t,
    event_buffer: std.ArrayList(std.os.linux.epoll_event),
    allocator: Allocator,

    pub fn init(alktr: Allocator) AmpeError!EpollBackend {
        const epfd = std.posix.epoll_create1(0) catch return AmpeError.AllocationFailed;
        return .{
            .epfd = epfd,
            .event_buffer = std.ArrayList(std.os.linux.epoll_event).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
            .allocator = alktr,
        };
    }

    pub fn deinit(self: *EpollBackend) void {
        self.event_buffer.deinit(self.allocator);
        std.posix.close(self.epfd);
    }

    pub fn register(self: *EpollBackend, fd: std.posix.fd_t, seq: SeqN, exp: Triggers) AmpeError!void {
        var ev = std.os.linux.epoll_event{
            .events = triggers_mod.epoll.toMask(exp),
            .data = .{ .u64 = seq },
        };
        std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_ADD, fd, &ev) catch |e| {
            switch (e) {
                error.FileDescriptorAlreadyPresentInSet => {
                    // Already registered, try MOD instead
                    std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_MOD, fd, &ev) catch return AmpeError.CommunicationFailed;
                },
                else => return AmpeError.CommunicationFailed,
            }
        };
    }

    pub fn modify(self: *EpollBackend, fd: std.posix.fd_t, seq: SeqN, exp: Triggers) AmpeError!void {
        var ev = std.os.linux.epoll_event{
            .events = triggers_mod.epoll.toMask(exp),
            .data = .{ .u64 = seq },
        };
        std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_MOD, fd, &ev) catch |e| {
            switch (e) {
                error.FileDescriptorNotRegistered => {
                    // Not yet registered, try ADD instead
                    std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_ADD, fd, &ev) catch return AmpeError.CommunicationFailed;
                },
                else => return AmpeError.CommunicationFailed,
            }
        };
    }

    pub fn unregister(self: *EpollBackend, fd: std.posix.fd_t) void {
        std.posix.epoll_ctl(self.epfd, std.os.linux.EPOLL.CTL_DEL, fd, null) catch {
            // Ignore errors on unregister (fd may already be closed)
        };
    }

    pub fn wait(self: *EpollBackend, timeout: i32, seqn_trc_map: *core.SeqnTrcMap) AmpeError!Triggers {
        var total_act = Triggers{};

        self.event_buffer.ensureTotalCapacity(self.allocator, seqn_trc_map.count()) catch return AmpeError.AllocationFailed;

        const n = std.posix.epoll_wait(self.epfd, self.event_buffer.unusedCapacitySlice(), timeout);
        if (n == 0) {
            total_act.timeout = .on;
        } else {
            for (self.event_buffer.unusedCapacitySlice()[0..n]) |ev| {
                if (seqn_trc_map.get(ev.data.u64)) |tc| {
                    const os_act = triggers_mod.epoll.fromMask(ev.events, tc.exp);
                    tc.act = tc.act.lor(os_act);
                    total_act = total_act.lor(tc.act);
                }
            }
        }

        return total_act;
    }
};

/// Complete epoll-based Poller type using PollerCore.
pub const Poller = core.PollerCore(EpollBackend);

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
