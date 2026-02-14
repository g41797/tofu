// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const windows = std.os.windows;
const ntdllx = @import("ntdllx.zig");

/// Manual completion key for shutdown
pub const SHUTDOWN_KEY: usize = 0xDEADBEEF;

pub const Stage0Wake = struct {
    iocp: windows.HANDLE,

    pub fn init() !Stage0Wake {
        var h: windows.HANDLE = undefined;
        // NtCreateIoCompletion(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, ULONG)
        const status: ntdllx.NTSTATUS = ntdllx.NtCreateIoCompletion(
            &h,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            null,
            0,
        );
        if (status != .SUCCESS) return error.IocpCreateFailed;
        return Stage0Wake{ .iocp = h };
    }

    pub fn deinit(self: *Stage0Wake) void {
        windows.CloseHandle(self.iocp);
    }

    pub fn runLoop(self: *Stage0Wake) !void {
        var entries: [1]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var removed: u32 = 0;

        while (true) {
            // NtRemoveIoCompletionEx(HANDLE, PFILE_COMPLETION_INFORMATION, ULONG, PULONG, PLARGE_INTEGER, BOOLEAN)
            const status: ntdllx.NTSTATUS = ntdllx.NtRemoveIoCompletionEx(
                self.iocp,
                &entries,
                1,
                &removed,
                null, // Infinite timeout
                0,
            );

            if (status != .SUCCESS) {
                std.debug.print("NtRemoveIoCompletionEx failed: {any}\n", .{status});
                return error.PollFailed;
            }

            if (removed > 0) {
                const key_as_int: usize = @intFromPtr(entries[0].Key);
                if (key_as_int == SHUTDOWN_KEY) {
                    std.debug.print("Received shutdown signal. Exiting loop.\n", .{});
                    break;
                } else {
                    std.debug.print("Received unknown completion key: 0x{X}\n", .{key_as_int});
                }
            }
        }
    }

    pub fn sendWakeup(self: *Stage0Wake, key: usize) !void {
        // NtSetIoCompletion(HANDLE, PVOID, PVOID, NTSTATUS, ULONG_PTR)
        const status: ntdllx.NTSTATUS = ntdllx.NtSetIoCompletion(
            self.iocp,
            key,
            null,
            .SUCCESS,
            0,
        );
        if (status != .SUCCESS) return error.SignalFailed;
    }
};

pub fn runTest() !void {
    var stage: Stage0Wake = try Stage0Wake.init();
    defer stage.deinit();

    const thread: std.Thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Stage0Wake) void {
            std.Thread.sleep(std.time.ns_per_ms * 100);
            std.debug.print("Sending wakeup signal...\n", .{});
            s.sendWakeup(SHUTDOWN_KEY) catch |err| {
                std.debug.print("Failed to send wakeup: {any}\n", .{err});
            };
        }
    }.run, .{&stage});

    std.debug.print("Starting IOCP loop...\n", .{});
    try stage.runLoop();
    thread.join();
    std.debug.print("Stage 0 POC successful.\n", .{});
}
