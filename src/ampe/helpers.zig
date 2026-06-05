// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Test utilities: UDS paths thread coordination.

/// Creates temp file path for UDS testing. Usage:
/// var tup: tofu.TempUdsPath = .{};
/// const filePath = try tup.buildPath();
/// var adrs: Address = .{ .uds_server_addr = UDSServerAddress.init(filePath) };
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

pub fn SleepMlsec(mlsec: u64) void {
    if (build_options.network == .posixnet) {
        pn.thread_sleep_ms(mlsec);
    } else {
        std.Thread.sleep(mlsec * std.time.ns_per_ms);
    }
}

pub fn AutoArrayHashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        alloc: Allocator = undefined,
        map: std.array_hash_map.Auto(K, V) = undefined,

        pub fn init(allocator: Allocator) Self {
            return .{
                .alloc = allocator,
                .map = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.*.map.deinit(self.*.alloc);
            self.* = .{};
        }

        pub inline fn ensureTotalCapacity(self: *Self, new_capacity: usize) !void {
            return self.*.map.ensureTotalCapacity(self.*.alloc, new_capacity);
        }

        pub inline fn put(self: *Self, key: K, value: V) !void {
            return self.*.map.put(self.*.alloc, key, value);
        }

        pub inline fn get(self: Self, key: K) ?V {
            return self.map.get(key);
        }

        pub inline fn keys(self: Self) []K {
            return self.map.keys();
        }

        pub inline fn values(self: Self) []V {
            return self.map.values();
        }

        pub inline fn contains(self: Self, key: K) bool {
            return self.map.contains(key);
        }

        pub inline fn swapRemove(self: *Self, key: K) bool {
            return self.map.swapRemove(key);
        }

        pub inline fn count(self: Self) usize {
            return self.map.count();
        }

        pub inline fn capacity(self: Self) usize {
            return self.map.capacity();
        }

        pub const Iterator = std.array_hash_map.Auto(K, V).Iterator;

        pub inline fn iterator(self: *const Self) Iterator {
            return self.map.iterator();
        }

        pub inline fn getPtr(self: Self, key: K) ?*V {
            return self.map.getPtr(key);
        }

        pub inline fn orderedRemove(self: *Self, key: K) bool {
            return self.map.orderedRemove(key);
        }

        pub fn fetchSwapRemove(self: *Self, key: K) ?std.array_hash_map.Auto(K, V).KV {
            return self.map.fetchSwapRemove(key);
        }
    };
}

const tofu = @import("../tofu.zig");
const status = @import("../status.zig");
const AmpeError = status.AmpeError;

const pn = @import("posix_net");
const build_options = @import("build_options");
const skt_backend = if (build_options.network == .posixnet)
    @import("internal.zig").Skt
else switch (builtin.os.tag) {
    .windows => @import("../platform/stdposix/windows/Skt.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("../platform/stdposix/mac/Skt.zig"),
    else => @import("../platform/stdposix/linux/Skt.zig"),
};
const Skt = skt_backend.Skt;

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const builtin = @import("builtin");

const mailbox = @import("mailbox");
const condition_waitTimeout = mailbox.condition_waitTimeout;

const Io = std.Io;

const Semaphore = Io.Semaphore;
const Condition = Io.Condition;
const Mutex = Io.Mutex;

// -------------------------------------------------------------------------------
// https://codeberg.org/ziglang/zig/src/branch/master/lib/std/Io/Semaphore.zig#L31
// -------------------------------------------------------------------------------
pub const WaitTimeoutError = Io.Cancelable || Io.Timeout.Error;

/// Blocks until a `permit` is available and consumes a single one.
/// Unblocks without consuming a `permit` when canceled or when the provided
/// timeout expires before a `permit` is available.
///
/// See also:
/// * `wait`
/// * `waitUncancelable`
pub fn semaphore_waitTimeout(s: *Semaphore, io: Io, timeout: Io.Timeout) WaitTimeoutError!void {
    const deadline = timeout.toDeadline(io);
    try s.mutex.lock(io);
    defer s.mutex.unlock(io);
    while (s.permits == 0) {
        try condition_waitTimeout(&s.cond, io, &s.mutex, deadline);
    }
    s.permits -= 1;
    if (s.permits > 0) s.cond.signal(io);
}
