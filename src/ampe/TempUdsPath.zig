// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const TempUdsPath = @This();
tempFile: temp.TempFile = undefined,
socket_path: [108:0]u8 = undefined,

pub fn buildPath(tup: *TempUdsPath, allocator: Allocator) ![]u8 {
    tup.tempFile = try temp.create_file(allocator, "yaaamp*.port");
    tup.tempFile.retain = false;
    defer tup.tempFile.deinit();

    const socket_file = tup.tempFile.parent_dir.realpath(tup.tempFile.basename, tup.socket_path[0..108]) catch {
        return AmpeError.UnknownError;
    };

    // Remove socket file if it exists
    tup.tempFile.parent_dir.deleteFile(tup.tempFile.basename) catch {};
    return socket_file;
}

const status = @import("../status.zig");
const AmpeError = status.AmpeError;

const temp = @import("temp");

const std = @import("std");
const Allocator = std.mem.Allocator;
