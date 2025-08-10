// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "TextHeaderIterator no CRLF" {
    var it = TextHeaderIterator.init("a: b");
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("a", header.name);
        try std.testing.expectEqualStrings("b", header.value);
    }
    try std.testing.expectEqual(null, it.next());
}

test "TextHeaderIterator next" {
    var it = TextHeaderIterator.init("a: b\r\nc:  \r\nd:e\r\n\r\nf: g\r\n\r\n");
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("a", header.name);
        try std.testing.expectEqualStrings("b", header.value);
    }
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("c", header.name);
        try std.testing.expectEqualStrings("", header.value);
    }
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("d", header.name);
        try std.testing.expectEqualStrings("e", header.value);
    }
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("f", header.name);
        try std.testing.expectEqualStrings("g", header.value);
    }
    try std.testing.expectEqual(null, it.next());

    it = TextHeaderIterator.init(": ss\r\n\r\n");
    try std.testing.expectEqual(null, it.next());

    it = TextHeaderIterator.init("a:b\r\n\r\n: ss\r\n\r\n");
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("a", header.name);
        try std.testing.expectEqualStrings("b", header.value);
    }
    try std.testing.expectEqual(null, it.next());
}

test "TextHeaderIterator empty" {
    var it: TextHeaderIterator = .{};
    try std.testing.expectEqual(null, it.next());
}

const engine = @import("engine.zig");
pub const TextHeaderIterator = @import("TextHeaderIterator.zig");

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
