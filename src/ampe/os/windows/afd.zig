// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

pub const AfdPoller = struct {
    iocp: windows.HANDLE,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !AfdPoller {
        var iocp: windows.HANDLE = undefined;
        const status: ntdllx.NTSTATUS = ntdllx.NtCreateIoCompletion(&iocp, windows.GENERIC_READ | windows.GENERIC_WRITE, null, 0);
        if (status != .SUCCESS) return error.IocpCreateFailed;

        return AfdPoller{
            .iocp = iocp,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const AfdPoller) void {
        _ = windows.CloseHandle(self.*.iocp);
    }

    pub fn register(self: *AfdPoller, skt: *Skt) !windows.HANDLE {
        var base_handle: windows.HANDLE = undefined;
        var bytes_returned: u32 = undefined;
        const ioctl_res: i32 = ws2_32.WSAIoctl(
            skt.*.socket.?,
            ws2_32.SIO_BASE_HANDLE,
            null,
            0,
            @ptrCast(&base_handle),
            @sizeOf(windows.HANDLE),
            &bytes_returned,
            null,
            null,
        );
        if (ioctl_res != 0) return error.GetBaseHandleFailed;

        _ = try windows.CreateIoCompletionPort(base_handle, self.*.iocp, 0, 0);
        skt.*.base_handle = base_handle;
        return base_handle;
    }

    pub fn poll(self: *AfdPoller, timeout_ms: i32, out_entries: []ntdllx.FILE_COMPLETION_INFORMATION) !u32 {
        var removed: u32 = 0;
        var timeout: windows.LARGE_INTEGER = if (timeout_ms < 0) undefined else @as(i64, timeout_ms) * -10_000;

        const status: ntdllx.NTSTATUS = ntdllx.NtRemoveIoCompletionEx(
            self.*.iocp,
            out_entries.ptr,
            @intCast(out_entries.len),
            &removed,
            if (timeout_ms < 0) null else &timeout,
            0,
        );

        if (status == .TIMEOUT) return 0;
        if (status != .SUCCESS) return error.PollCompletionFailed;

        return removed;
    }

    pub fn toAfdEvents(trgs: Triggers) u32 {
        return @import("afd.zig").toAfdEvents(trgs);
    }

    pub fn fromAfdEvents(events: u32, expected: Triggers) Triggers {
        return @import("afd.zig").fromAfdEvents(events, expected);
    }
};

pub const SocketContext = struct {
    skt: *Skt,
    poll_info: ntdllx.AFD_POLL_INFO,
    io_status: windows.IO_STATUS_BLOCK = undefined,
    is_pending: bool = false,

    pub fn init(skt: *Skt) SocketContext {
        return SocketContext{
            .skt = skt,
            .poll_info = undefined,
        };
    }

    pub fn arm(self: *SocketContext, events: u32, apc_context: ?*anyopaque) !void {
        self.*.poll_info = ntdllx.AFD_POLL_INFO{
            .Timeout = @as(windows.LARGE_INTEGER, @bitCast(@as(u64, 0x7FFFFFFFFFFFFFFF))),
            .NumberOfHandles = 1,
            .Exclusive = 0,
            .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                .{ .Handle = self.*.skt.*.base_handle, .Events = events, .Status = .SUCCESS },
            },
        };

        const status: ntdllx.NTSTATUS = windows.ntdll.NtDeviceIoControlFile(
            self.*.skt.*.base_handle,
            null,
            null,
            apc_context,
            &self.*.io_status,
            ntdllx.IOCTL_AFD_POLL,
            &self.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
            &self.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
        );

        if (status != .SUCCESS and status != .PENDING) return error.AfdPollFailed;
        self.*.is_pending = true;
    }
};

const Skt = @import("Skt.zig");
const ws2_32 = windows.ws2_32;

pub fn toAfdEvents(trgs: Triggers) u32 {
    var events: u32 = 0;
    if (trgs.accept == .on) events |= ntdllx.AFD_POLL_ACCEPT;
    if (trgs.recv == .on or trgs.notify == .on) events |= ntdllx.AFD_POLL_RECEIVE;
    if (trgs.send == .on or trgs.connect == .on) events |= ntdllx.AFD_POLL_SEND | ntdllx.AFD_POLL_CONNECT;
    events |= ntdllx.AFD_POLL_ABORT | ntdllx.AFD_POLL_CONNECT_FAIL | ntdllx.AFD_POLL_LOCAL_CLOSE;
    return events;
}

pub fn fromAfdEvents(events: u32, expected: Triggers) Triggers {
    var trgs: Triggers = Triggers{};
    if ((events & ntdllx.AFD_POLL_ACCEPT) != 0) trgs.accept = .on;
    if ((events & ntdllx.AFD_POLL_RECEIVE) != 0) {
        if (expected.recv == .on) trgs.recv = .on;
        if (expected.notify == .on) trgs.notify = .on;
    }
    if ((events & (ntdllx.AFD_POLL_SEND | ntdllx.AFD_POLL_CONNECT)) != 0) {
        if (expected.send == .on) trgs.send = .on;
        if (expected.connect == .on) trgs.connect = .on;
    }
    if ((events & (ntdllx.AFD_POLL_ABORT | ntdllx.AFD_POLL_CONNECT_FAIL | ntdllx.AFD_POLL_LOCAL_CLOSE)) != 0) {
        trgs.err = .on;
        // Map error back to specific operation if expected
        if (expected.connect == .on) trgs.connect = .on;
        if (expected.accept == .on) trgs.accept = .on;
    }
    return trgs;
}

const std = @import("std");
const windows = std.os.windows;
const ntdllx = @import("ntdllx.zig");
const tofu = @import("../../../tofu.zig");
const Triggers = tofu.@"internal usage".triggeredSkts.Triggers;
