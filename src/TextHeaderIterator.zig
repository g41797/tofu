// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

// Simplified version of Zig' HeaderIterator

const TextHeaderIterator = @This();

bytes: ?[]const u8 = null,
index: usize = 0,

pub fn init(bytes: ?[]const u8) TextHeaderIterator {
    return .{
        .bytes = bytes,
        .index = 0,
    };
}

pub fn rewind(it: *TextHeaderIterator) void {
    it.index = 0;
}

pub fn next(it: *TextHeaderIterator) ?TextHeader {
    if (it.bytes == null) {
        return null;
    }

    if (it.bytes.?.len == 0) {
        return null;
    }

    const buffer = it.bytes.?;

    while (true) {
        if (it.index >= it.bytes.?.len) {
            return null;
        }

        const crlfaddr = std.mem.indexOfPosLinear(u8, buffer, it.index, "\r\n");

        if (crlfaddr == null) { // Without CRLF at the end
            var kv_it = std.mem.splitScalar(u8, buffer[it.index..], ':');
            const name = kv_it.first();
            const value = kv_it.rest();

            it.index = it.bytes.?.len;
            if (name.len == 0) {
                return null;
            }

            return .{
                .name = name,
                .value = std.mem.trim(u8, value, " \t"),
            };
        }

        const end = crlfaddr.?;

        if (it.index == end) { // found empty field ????
            it.index = end + 2;
            continue;
        }

        // normal header
        var kv_it = std.mem.splitScalar(u8, buffer[it.index..end], ':');
        const name = kv_it.first();
        const value = kv_it.rest();

        it.index = end + 2;
        if (name.len == 0) {
            return null;
        }
        return .{
            .name = name,
            .value = std.mem.trim(u8, value, " \t"),
        };
    }
}

const protocol = @import("protocol.zig");
const TextHeader = protocol.TextHeader;

const std = @import("std");
