// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Windows wepoll-based backend implementation.
//! Complete wepoll implementation with no comptime branches inside functions.
//! Includes FFI declarations for wepoll at the bottom.

/// Wepoll-specific backend implementation.
const WepollBackend = struct {
    handle: *anyopaque,
    event_buffer: std.ArrayList(WepollEvent),
    allocator: Allocator,

    pub fn init(alktr: Allocator) AmpeError!WepollBackend {
        const handle = epoll_create1(0) orelse return AmpeError.AllocationFailed;
        return .{
            .handle = handle,
            .event_buffer = std.ArrayList(WepollEvent).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
            .allocator = alktr,
        };
    }

    pub fn deinit(self: *WepollBackend) void {
        self.event_buffer.deinit(self.allocator);
        _ = epoll_close(self.handle);
    }

    pub fn register(self: *WepollBackend, fd: usize, seq: SeqN, exp: Triggers) AmpeError!void {
        var ev = WepollEvent{
            .events = triggers_mod.epoll.toMask(exp),
            .data = seq,
        };
        const res = epoll_ctl(self.handle, EPOLL_CTL_ADD, fd, &ev);
        if (res != 0) {
            const err = std.os.windows.kernel32.GetLastError();
            if (@intFromEnum(err) == 1168) { // ERROR_NOT_FOUND - try MOD
                if (epoll_ctl(self.handle, EPOLL_CTL_MOD, fd, &ev) == 0) return;
            }
            log.warn("wepoll register failed: fd={d} err={any}", .{ fd, err });
            return AmpeError.CommunicationFailed;
        }
    }

    pub fn modify(self: *WepollBackend, fd: usize, seq: SeqN, exp: Triggers) AmpeError!void {
        var ev = WepollEvent{
            .events = triggers_mod.epoll.toMask(exp),
            .data = seq,
        };
        const res = epoll_ctl(self.handle, EPOLL_CTL_MOD, fd, &ev);
        if (res != 0) {
            const err = std.os.windows.kernel32.GetLastError();
            if (@intFromEnum(err) == 1168) { // ERROR_NOT_FOUND - try ADD
                if (epoll_ctl(self.handle, EPOLL_CTL_ADD, fd, &ev) == 0) return;
            }
            log.warn("wepoll modify failed: fd={d} err={any}", .{ fd, err });
            return AmpeError.CommunicationFailed;
        }
    }

    pub fn unregister(self: *WepollBackend, fd: usize) void {
        var ev = WepollEvent{ .events = 0, .data = 0 };
        _ = epoll_ctl(self.handle, EPOLL_CTL_DEL, fd, &ev);
        // Ignore errors on unregister
    }

    pub fn wait(self: *WepollBackend, timeout: i32, seqn_trc_map: *core.SeqnTrcMap) AmpeError!Triggers {
        var total_act = Triggers{};

        self.event_buffer.ensureTotalCapacity(self.allocator, seqn_trc_map.count()) catch return AmpeError.AllocationFailed;

        const n: usize = @intCast(epoll_wait(
            self.handle,
            @ptrCast(self.event_buffer.unusedCapacitySlice().ptr),
            @intCast(self.event_buffer.unusedCapacitySlice().len),
            timeout,
        ));

        if (n == 0) {
            total_act.timeout = .on;
        } else {
            for (self.event_buffer.unusedCapacitySlice()[0..n]) |ev| {
                if (seqn_trc_map.get(ev.data)) |tc| {
                    const os_act = triggers_mod.epoll.fromMask(ev.events, tc.exp);
                    tc.act = tc.act.lor(os_act);
                    total_act = total_act.lor(tc.act);
                }
            }
        }

        return total_act;
    }
};

/// Complete wepoll-based Poller type using PollerCore.
pub const Poller = core.PollerCore(WepollBackend);

// ============================================================================
// Wepoll FFI Declarations
// ============================================================================

pub const WepollEvent = extern struct {
    events: u32,
    data: u64,
};

// EPOLL_CTL constants (same values as Linux)
const EPOLL_CTL_ADD: i32 = 1;
const EPOLL_CTL_MOD: i32 = 2;
const EPOLL_CTL_DEL: i32 = 3;

extern fn epoll_create1(flags: i32) ?*anyopaque;
extern fn epoll_close(ephnd: *anyopaque) i32;
extern fn epoll_ctl(ephnd: *anyopaque, op: i32, sock: usize, event: *WepollEvent) i32;
extern fn epoll_wait(ephnd: *anyopaque, events: [*]WepollEvent, maxevents: i32, timeout: i32) i32;

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
const log = std.log;
