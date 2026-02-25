// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! OBSOLETE: Legacy poll-based backend.
//! This is a self-contained island that will be removed when poll support is dropped.
//! Used as fallback on platforms without epoll/wepoll/kqueue.

/// Poll-specific backend implementation.
const PollBackend = struct {
    event_buffer: std.ArrayList(std.posix.pollfd),
    allocator: Allocator,

    pub fn init(alktr: Allocator) AmpeError!PollBackend {
        return .{
            .event_buffer = std.ArrayList(std.posix.pollfd).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
            .allocator = alktr,
        };
    }

    pub fn deinit(self: *PollBackend) void {
        self.event_buffer.deinit(self.allocator);
    }

    pub fn register(self: *PollBackend, fd: anytype, seq: SeqN, exp: Triggers) AmpeError!void {
        // Poll doesn't require pre-registration; handled in wait
        _ = self;
        _ = fd;
        _ = seq;
        _ = exp;
    }

    pub fn modify(self: *PollBackend, fd: anytype, seq: SeqN, exp: Triggers) AmpeError!void {
        // Poll doesn't require modification; rebuilt each wait
        _ = self;
        _ = fd;
        _ = seq;
        _ = exp;
    }

    pub fn unregister(self: *PollBackend, fd: anytype) void {
        // Poll doesn't require unregistration
        _ = self;
        _ = fd;
    }

    pub fn wait(self: *PollBackend, timeout: i32, seqn_trc_map: *core.SeqnTrcMap) AmpeError!Triggers {
        self.event_buffer.clearRetainingCapacity();

        var total_act = Triggers{};

        // Build pollfd array from all channels
        const values = seqn_trc_map.values();
        for (values) |tc| {
            const socket = tc.tskt.getSocket();
            self.event_buffer.append(self.allocator, .{
                .fd = if (common.isSocketSet(socket)) @as(std.posix.fd_t, @intCast(socket.?)) else -1,
                .events = triggers_mod.poll.toMask(tc.exp),
                .revents = 0,
            }) catch return AmpeError.AllocationFailed;
        }

        const n = std.posix.poll(self.event_buffer.items, timeout) catch return AmpeError.CommunicationFailed;
        if (n == 0) {
            total_act.timeout = .on;
        } else {
            for (self.event_buffer.items, seqn_trc_map.values()) |pfd, tc| {
                const os_act = triggers_mod.poll.fromMask(pfd.revents, tc.exp);
                tc.act = tc.act.lor(os_act);
                total_act = total_act.lor(tc.act);
            }
        }

        return total_act;
    }
};

/// Complete poll-based Poller type using PollerCore.
pub const Poller = core.PollerCore(PollBackend);

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
