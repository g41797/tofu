// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "TempUdsPath: buildPath returns non-empty path" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath();
    try std.testing.expect(path.len > 0);
}

test "TempUdsPath: buildPath path fits in UDS_PATH_SIZE" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath();
    try std.testing.expect(path.len < pn.UDS_PATH_SIZE);
}

test "TempUdsPath: buildPath returns null-terminated string" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath();
    try std.testing.expectEqual(@as(u8, 0), path.ptr[path.len]);
}

test "TempUdsPath: buildPath produces unique paths on consecutive calls" {
    var tup1: tofu.TempUdsPath = .{};
    var tup2: tofu.TempUdsPath = .{};
    const path1 = try tup1.buildPath();
    const path2 = try tup2.buildPath();
    try std.testing.expect(!std.mem.eql(u8, path1, path2));
}

test "TempUdsPath: buildPath path does not exist as file" {
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath();
    const result = std.fs.accessAbsolute(path, .{});
    try std.testing.expectError(error.FileNotFound, result);
}

const tofu = @import("tofu");
const pn = @import("posix_net");
const std = @import("std");
