// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "sequential message id" {
    const mid = message.Message.next_mid();
    const nextmid = message.Message.next_mid();
    try testing.expectEqual(mid + 1, nextmid);
}

test "BinaryHeader marshalling and demarshalling" {
    var header = message.BinaryHeader{
        .channel_number = 0x1234,
        .proto = .{
            .mtype = .hello,
            .mode = .request,
            .origin = .application,
            .more = .last,
            .cb = .zero, // Protocol sets this; application must not modify
        },
        .status = 0xFF,
        .message_id = 0xAABBCCDDEEFF0011,
        .text_headers_len = 0x5678,
        .body_len = 0x9ABC,
    };

    var buf: [message.BinaryHeader.BHSIZE]u8 = undefined;
    header.toBytes(&buf);

    var demarshaled: message.BinaryHeader = undefined;
    demarshaled.fromBytes(&buf);

    try std.testing.expectEqual(header.channel_number, demarshaled.channel_number);
    try std.testing.expectEqual(header.proto.mtype, demarshaled.proto.mtype);
    try std.testing.expectEqual(header.proto.mode, demarshaled.proto.mode);
    try std.testing.expectEqual(header.status, demarshaled.status);
    try std.testing.expectEqual(header.message_id, demarshaled.message_id);
    try std.testing.expectEqual(header.text_headers_len, demarshaled.text_headers_len);
    try std.testing.expectEqual(header.body_len, demarshaled.body_len);
}

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

pub const message = @import("message.zig");
pub const TextHeaderIterator = message.TextHeaderIterator;

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
