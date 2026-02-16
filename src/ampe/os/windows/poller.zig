// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

pub const poll_INFINITE_TIMEOUT: u32 = std.math.maxInt(i32);
pub const poll_SEC_TIMEOUT: i32 = 1_000;

pub const Poller = union(enum) {
    poll: Poll,

    pub fn waitTriggers(self: *Poller, it: ?Reactor.Iterator, timeout: i32) AmpeError!Triggers {
        const ret: Triggers = switch (self.*) {
            .poll => try self.*.poll.waitTriggers(it, timeout),
        };

        if (DBG) {
            const utrgrs: internal.triggeredSkts.UnpackedTriggers = internal.triggeredSkts.UnpackedTriggers.fromTriggers(ret);
            _ = utrgrs;
        }

        return ret;
    }

    pub fn deinit(self: *const Poller) void {
        switch (self.*) {
            .poll => @constCast(&self.*.poll).deinit(),
        }
        return;
    }
};

pub const PinnedState = struct {
    io_status: windows.IO_STATUS_BLOCK = undefined,
    poll_info: ntdllx.AFD_POLL_INFO = undefined,
    is_pending: bool = false,
    expected_events: u32 = 0,
};

pub const Poll = struct {
    allocator: Allocator = undefined,
    afd_poller: AfdPoller = undefined,
    it: ?Reactor.Iterator = null,
    entries: std.ArrayList(ntdllx.FILE_COMPLETION_INFORMATION) = undefined,
    pinned_states: std.AutoArrayHashMap(ChannelNumber, *PinnedState) = undefined,

    pub fn init(allocator: Allocator) !Poll {
        return Poll{
            .allocator = allocator,
            .afd_poller = try AfdPoller.init(allocator),
            .it = null,
            .entries = try std.ArrayList(ntdllx.FILE_COMPLETION_INFORMATION).initCapacity(allocator, 256),
            .pinned_states = std.AutoArrayHashMap(ChannelNumber, *PinnedState).init(allocator),
        };
    }

    pub fn deinit(pl: *Poll) void {
        for (pl.*.pinned_states.values()) |state| {
            pl.*.allocator.destroy(state);
        }
        pl.*.pinned_states.deinit();
        pl.*.afd_poller.deinit();
        pl.*.entries.deinit(pl.*.allocator);
        return;
    }

    pub fn waitTriggers(pl: *Poll, it: ?Reactor.Iterator, timeout: i32) AmpeError!Triggers {
        if ((pl.*.it == null) and (it == null)) {
            return AmpeError.NotAllowed;
        }

        if (it != null) {
            pl.*.it = it;
        }

        pl.*.it.?.reset();

        // Step 1: Clean up orphaned PinnedStates, then arm/re-arm AFD_POLL
        pl.*.armFds() catch |err| {
            log.err("armFds failed with error {any}", .{err});
            return AmpeError.CommunicationFailed;
        };

        // Step 2: Poll IOCP
        const removed: u32 = pl.*.poll(timeout) catch |err| {
            log.err("poll failed with error {any}", .{err});
            return AmpeError.CommunicationFailed;
        };

        if (removed == 0) {
            const tmouttrgs: Triggers = .{
                .timeout = .on,
            };
            return tmouttrgs;
        }

        // Step 3: Process completions and return triggers
        return try pl.*.processCompletions(removed);
    }

    fn armFds(pl: *Poll) !void {
        pl.*.cleanupOrphans();

        var tcptr: ?*TriggeredChannel = pl.*.it.?.next();

        while (tcptr != null) {
            const tc: *TriggeredChannel = tcptr.?;
            tcptr = pl.*.it.?.next();

            tc.*.disableDelete();

            const exp: Triggers = try tc.*.tskt.triggers();
            tc.*.exp = exp;
            tc.*.act = .{};

            if (exp.off()) continue;

            const skt: *Skt = switch (tc.*.tskt) {
                .notification => tc.*.tskt.notification.skt,
                .accept => &tc.*.tskt.accept.skt,
                .io => &tc.*.tskt.io.skt,
                .dumb => continue,
            };

            // Register if not already registered
            if (skt.*.base_handle == windows.INVALID_HANDLE_VALUE) {
                _ = try pl.*.afd_poller.register(skt);
            }

            const chn: ChannelNumber = tc.*.acn.chn;
            const events: u32 = afd.toAfdEvents(exp);

            // Get or create PinnedState
            const gop = try pl.*.pinned_states.getOrPut(chn);
            if (!gop.found_existing) {
                gop.value_ptr.* = try pl.*.allocator.create(PinnedState);
                gop.value_ptr.*.* = PinnedState{};
            }
            const state: *PinnedState = gop.value_ptr.*;

            // Arm if not pending or if interest changed
            if (!state.*.is_pending or state.*.expected_events != events) {
                try pl.*.armSkt(skt, events, chn, state);
            }
        }
    }

    fn armSkt(pl: *Poll, skt: *Skt, events: u32, chn: ChannelNumber, state: *PinnedState) !void {
        _ = pl;
        state.*.poll_info = ntdllx.AFD_POLL_INFO{
            .Timeout = @as(windows.LARGE_INTEGER, @bitCast(@as(u64, 0x7FFFFFFFFFFFFFFF))),
            .NumberOfHandles = 1,
            .Exclusive = 0,
            .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                .{ .Handle = skt.*.base_handle, .Events = events, .Status = .SUCCESS },
            },
        };

        const status: ntdllx.NTSTATUS = windows.ntdll.NtDeviceIoControlFile(
            skt.*.base_handle,
            null,
            null,
            @ptrFromInt(@as(usize, chn)),
            &state.*.io_status,
            ntdllx.IOCTL_AFD_POLL,
            &state.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
            &state.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
        );

        if (status != .SUCCESS and status != .PENDING) {
            return AmpeError.CommunicationFailed;
        }
        state.*.is_pending = true;
        state.*.expected_events = events;
    }

    fn poll(pl: *Poll, timeout_ms: i32) !u32 {
        return pl.*.afd_poller.poll(timeout_ms, pl.*.entries.allocatedSlice());
    }

    fn processCompletions(pl: *Poll, removed: u32) !Triggers {
        var ret: Triggers = .{};

        for (pl.*.entries.allocatedSlice()[0..removed]) |entry| {
            if (entry.ApcContext == null) continue;

            const chn: ChannelNumber = @intCast(@intFromPtr(entry.ApcContext.?));

            // Look up PinnedState (stable heap memory)
            const state: *PinnedState = pl.*.pinned_states.get(chn) orelse continue;
            state.*.is_pending = false;

            // Look up TriggeredChannel by ID (safe — gets current address)
            const tc: *TriggeredChannel = pl.*.it.?.getPtr(chn) orelse {
                // Channel was removed — free orphaned PinnedState
                pl.*.allocator.destroy(state);
                _ = pl.*.pinned_states.swapRemove(chn);
                continue;
            };

            if (tc.*.tskt == .dumb) continue;

            if (entry.IoStatus.u.Status != .SUCCESS) {
                tc.*.act = Triggers{ .err = .on };
                ret = ret.lor(tc.*.act);
                continue;
            }

            const events: u32 = state.*.poll_info.Handles[0].Events;
            const act: Triggers = afd.fromAfdEvents(events, tc.*.exp);

            tc.*.act = act.lor(.{ .pool = tc.*.exp.pool });
            ret = ret.lor(tc.*.act);
        }

        return ret;
    }

    fn cleanupOrphans(pl: *Poll) void {
        var i: usize = 0;
        const keys = pl.*.pinned_states.keys();
        const vals = pl.*.pinned_states.values();
        while (i < pl.*.pinned_states.count()) {
            if (!vals[i].*.is_pending and pl.*.it.?.getPtr(keys[i]) == null) {
                pl.*.allocator.destroy(vals[i]);
                pl.*.pinned_states.swapRemoveAt(i);
            } else {
                i += 1;
            }
        }
    }
};

pub const afd = @import("afd.zig");
pub const ntdllx = @import("ntdllx.zig");
pub const AfdPoller = afd.AfdPoller;

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const log = std.log;

const tofu = @import("../../../tofu.zig");
const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;
const message = tofu.message;
const ChannelNumber = message.ChannelNumber;
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;

const internal = @import("../../internal.zig");
const Skt = internal.Skt;
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;
const Triggers = internal.triggeredSkts.Triggers;
