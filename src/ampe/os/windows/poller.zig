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

pub const Poll = struct {
    allocator: Allocator = undefined,
    afd_poller: AfdPoller = undefined,
    it: ?Reactor.Iterator = null,
    entries: [256]ntdllx.FILE_COMPLETION_INFORMATION = undefined,

    pub fn init(allocator: Allocator) !Poll {
        return Poll{
            .allocator = allocator,
            .afd_poller = try AfdPoller.init(allocator),
            .it = null,
        };
    }

    pub fn deinit(pl: *Poll) void {
        pl.*.afd_poller.deinit();
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

        // Step 1: Arm/Re-arm AFD_POLL for all channels with interest
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
        var tcptr: ?*TriggeredChannel = pl.*.it.?.next();

        while (tcptr != null) {
            const tc: *TriggeredChannel = tcptr.?;
            tcptr = pl.*.it.?.next();

            tc.*.disableDelete();

            const exp: Triggers = try tc.*.tskt.triggers();
            tc.*.exp = exp;
            tc.*.act = .{};

            if (exp.off()) continue;

            const events: u32 = AfdPoller.toAfdEvents(exp);
            const skt: *Skt = switch (tc.*.tskt) {
                .notification => tc.*.tskt.notification.skt,
                .accept => &tc.*.tskt.accept.skt,
                .io => &tc.*.tskt.io.skt,
                .dumb => continue,
            };

            // Register if not already registered (base_handle is INVALID_HANDLE_VALUE initially)
            if (skt.*.base_handle == windows.INVALID_HANDLE_VALUE) {
                _ = try pl.*.afd_poller.register(skt);
                skt.*.is_pending = false;
                skt.*.expected_events = 0;
            }

            // Arm if not pending or if interest changed
            if (!skt.*.is_pending or skt.*.expected_events != events) {
                // If interest changed but we have a pending poll, we ideally should cancel it.
                // For now, following the v6.1 spec: "immediately re-issue a new AFD_POLL... before processing I/O events"
                // and "Never leave a socket without a pending AFD_POLL unless intentionally removed."
                
                // If it's already pending, arming again for the same handle with the same IO_STATUS_BLOCK
                // might be problematic or it might just update the request.
                // POCs showed we arm when we need to.
                
                // If interest is disabled (exp.off()), we don't arm.
                // If interest is changed, we re-arm.

                // In Windows Reactor implementation, if we arm again, AFD might return STATUS_PORT_UNREACHABLE or similar if already pending?
                // Actually, NtDeviceIoControlFile with AFD_POLL usually replaces or fails if already pending.
                // Stage 3 stress re-arms after every event.

                try pl.*.armSkt(skt, events, tc);
            }
        }
    }

    fn armSkt(pl: *Poll, skt: *Skt, events: u32, tc: *TriggeredChannel) !void {
        _ = pl;
        skt.*.poll_info = ntdllx.AFD_POLL_INFO{
            .Timeout = @as(windows.LARGE_INTEGER, @bitCast(@as(u64, 0x7FFFFFFFFFFFFFFF))), // Infinite wait at AFD level
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
            tc, // ApcContext = TriggeredChannel pointer
            &skt.*.io_status,
            ntdllx.IOCTL_AFD_POLL,
            &skt.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
            &skt.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
        );

        if (status != .SUCCESS and status != .PENDING) {
            return AmpeError.CommunicationFailed;
        }
        skt.*.is_pending = true;
        skt.*.expected_events = events;
    }

    fn poll(pl: *Poll, timeout_ms: i32) !u32 {
        return pl.*.afd_poller.poll(timeout_ms, &pl.*.entries);
    }

    fn processCompletions(pl: *Poll, removed: u32) !Triggers {
        var ret: Triggers = .{};

        for (pl.*.entries[0..removed]) |entry| {
            if (entry.ApcContext == null) continue;

            const tc: *TriggeredChannel = @ptrCast(@alignCast(entry.ApcContext.?));
            const skt: *Skt = switch (tc.*.tskt) {
                .notification => tc.*.tskt.notification.skt,
                .accept => &tc.*.tskt.accept.skt,
                .io => &tc.*.tskt.io.skt,
                else => unreachable,
            };

            skt.*.is_pending = false;

            const events: u32 = skt.*.poll_info.Handles[0].Events;
            const act: Triggers = AfdPoller.fromAfdEvents(events, tc.*.exp);
            
            tc.*.act = act.lor(.{ .pool = tc.*.exp.pool });
            ret = ret.lor(tc.*.act);
        }

        return ret;
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
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;

const internal = @import("../../internal.zig");
const Skt = internal.Skt;
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;
const Triggers = internal.triggeredSkts.Triggers;
