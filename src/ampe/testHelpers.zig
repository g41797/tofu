// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Test utilities: UDS paths, free TCP ports, thread coordination.

/// Creates temp file path for UDS testing. Usage:
/// var tup: tofu.TempUdsPath = .{};
/// const filePath = try tup.buildPath(allocator);
/// var adrs: Address = .{ .uds_server_addr = UDSServerAddress.init(filePath) };
pub const TempUdsPath = struct {
    tempFile: temp.TempFile = undefined,
    socket_path: [108:0]u8 = undefined,

    pub fn buildPath(tup: *TempUdsPath, allocator: Allocator) ![]u8 {
        tup.tempFile = try temp.create_file(allocator, "tofu*.port");
        tup.tempFile.retain = false;
        defer tup.tempFile.deinit();

        @memset(&tup.*.socket_path, 0);

        const socket_file = tup.tempFile.parent_dir.realpath(tup.tempFile.basename, tup.socket_path[0..108]) catch {
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
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer {
        if (builtin.os.tag == .windows) {
            // Abortive close for the probe socket
            const Linger = extern struct {
                l_onoff: u16,
                l_linger: u16,
            };
            const linger_cfg = Linger{ .l_onoff = 1, .l_linger = 0 };
            _ = std.os.windows.ws2_32.setsockopt(sockfd, 0xffff, 0x0080, @ptrCast(&linger_cfg), @sizeOf(Linger));
            _ = std.os.windows.ws2_32.closesocket(sockfd);
            std.Thread.sleep(20 * std.time.ns_per_ms);
        } else {
            posix.close(sockfd);
        }
    }

    if (builtin.os.tag == .linux) {
        try posix.setsockopt(sockfd, std.posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }

    try posix.setsockopt(sockfd, std.posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    // Set up sockaddr_in structure with port 0 (ephemeral port)
    var addr: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = 0, // Let the system assign a free port
        .addr = 0, // INADDR_ANY (0.0.0.0)
    };

    try posix.bind(sockfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(sockfd, @ptrCast(&addr), &addr_len);

    const port = std.mem.bigToNative(u16, addr.port);

    return port;
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

const temp = @import("temp");

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const log = std.log;

const builtin = @import("builtin");
