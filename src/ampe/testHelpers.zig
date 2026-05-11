// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Test utilities: UDS paths thread coordination.

/// Creates temp file path for UDS testing. Usage:
/// var tup: tofu.TempUdsPath = .{};
/// const filePath = try tup.buildPath(allocator);
/// var adrs: Address = .{ .uds_server_addr = UDSServerAddress.init(filePath) };
const pn = @import("posix_net");
const UDS_PATH_SIZE = pn.UDS_PATH_SIZE;

pub const TempUdsPath = struct {
    tempFile: temp.TempFile = undefined,
    socket_path: [UDS_PATH_SIZE:0]u8 = undefined,

    pub fn buildPath(tup: *TempUdsPath, allocator: Allocator) ![]u8 {
        tup.tempFile = try temp.create_file(allocator, "tofu*.port");
        tup.tempFile.retain = false;
        defer tup.tempFile.deinit();

        @memset(&tup.*.socket_path, 0);

        const socket_file = tup.tempFile.parent_dir.realpath(tup.tempFile.basename, &tup.socket_path) catch {
            return AmpeError.UnknownError;
        };

        // Remove socket file if it exists - bind() will fail on Windows if it exists
        if (builtin.os.tag == .windows) {
            std.fs.deleteFileAbsolute(socket_file) catch {};
        } else {
            tup.tempFile.parent_dir.deleteFile(tup.tempFile.basename) catch {};
        }

        return socket_file;
    }
};

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
    @import("portable/Skt.zig")
else switch (builtin.os.tag) {
    .windows => @import("windows/Skt.zig"),
    .macos, .freebsd, .openbsd, .netbsd => @import("mac/Skt.zig"),
    else => @import("linux/Skt.zig"),
};
const Skt = skt_backend.Skt;

const temp = @import("temp");

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const builtin = @import("builtin");
