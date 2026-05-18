// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Test utilities: UDS paths thread coordination.

/// Creates temp file path for UDS testing. Usage:
/// var tup: tofu.TempUdsPath = .{};
/// const filePath = try tup.buildPath();
/// var adrs: Address = .{ .uds_server_addr = UDSServerAddress.init(filePath) };
const pn = @import("posix_net");
const UDS_PATH_SIZE = pn.UDS_PATH_SIZE;

var uds_counter = std.atomic.Value(u64).init(0);

pub const TempUdsPath = struct {
    socket_path: [UDS_PATH_SIZE:0]u8 = undefined,

    pub fn buildPath(tup: *TempUdsPath) ![]u8 {
        const n = uds_counter.fetchAdd(1, .monotonic);
        @memset(&tup.socket_path, 0);
        const path = if (builtin.os.tag == .windows)
            buildPathWindows(&tup.socket_path, n)
        else
            buildPathUnix(&tup.socket_path, n);
        return path orelse AmpeError.UnknownError;
    }
};

// Unix: extern C declarations (libc already linked)
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getpid() c_int;

fn buildPathUnix(buf: *[UDS_PATH_SIZE:0]u8, n: u64) ?[]u8 {
    const tmp_dir: []const u8 = if (getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    const pid: c_int = getpid();
    return std.fmt.bufPrintZ(buf, "{s}/tofu_{d}_{d}.port", .{ tmp_dir, pid, n }) catch null;
}

// Windows: kernel32 declarations (always available)
extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) u32;
extern "kernel32" fn GetCurrentProcessId() u32;

fn buildPathWindows(buf: *[UDS_PATH_SIZE:0]u8, n: u64) ?[]u8 {
    var tmp_buf: [256]u8 = undefined;
    const len = GetTempPathA(@intCast(tmp_buf.len), &tmp_buf);
    if (len == 0) return null;
    const tmp_dir = tmp_buf[0..len]; // ends with backslash on Windows
    const pid = GetCurrentProcessId();
    return std.fmt.bufPrintZ(buf, "{s}tofu_{d}_{d}.port", .{ tmp_dir, pid, n }) catch null;
}

/// Avoids 'Address In Use' in repeated tests.
pub fn FindFreeTcpPort() !u16 {
    return Skt.findFreeTcpPort();
}

/// For tests only. Logs errors.
pub fn DestroyChannels(ampe: tofu.Ampe, chnls: tofu.ChannelGroup) void {
    ampe.destroy(chnls) catch |err| {
        log.info("DestroyChannels failed with error {any}", .{err});
        return;
    };
}

/// Waits for all to finish.
pub fn RunTasks(allocator: std.mem.Allocator, tasks: []const *const fn () void) !void {
    var threads: []std.Thread = try allocator.alloc(std.Thread, tasks.len);
    defer allocator.free(threads);

    for (tasks, 0..) |task, i| {
        threads[i] = try std.Thread.spawn(.{}, runTask, .{task});
    }

    for (threads, 0..) |*thread, i| {
        thread.join();
        log.debug("Thread {d} finished", .{i + 1});
    }
}

inline fn runTask(task: *const fn () void) void {
    task();
}

const tofu = @import("../tofu.zig");
const status = @import("../status.zig");
const AmpeError = status.AmpeError;

const build_options = @import("build_options");
const skt_backend = if (build_options.network == .portable)
    @import("internal.zig").Skt
else switch (builtin.os.tag) {
    .windows => @import("windows/Skt.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("mac/Skt.zig"),
    else => @import("linux/Skt.zig"),
};
const Skt = skt_backend.Skt;

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const builtin = @import("builtin");
