// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "BinaryHeader marshalling and demarshalling" {
    var header = BinaryHeader{
        .channel_number = 0x1234,
        .proto = .{
            .type = .control,
            .mode = .request,
            .origin = .application,
            .more = .last,
            .pcb = .zero, // Protocol sets this; application must not modify
        },
        .status = 0xFF,
        .message_id = 0xAABBCCDDEEFF0011,
        .text_headers_len = 0x5678,
        .body_len = 0x9ABC,
    };

    var buf: [BinaryHeader.BHSIZE]u8 = undefined;
    header.toBytes(&buf);

    var demarshaled: BinaryHeader = undefined;
    demarshaled.fromBytes(&buf);

    try std.testing.expectEqual(header.channel_number, demarshaled.channel_number);
    try std.testing.expectEqual(header.proto.type, demarshaled.proto.type);
    try std.testing.expectEqual(header.proto.mode, demarshaled.proto.mode);
    try std.testing.expectEqual(header.status, demarshaled.status);
    try std.testing.expectEqual(header.message_id, demarshaled.message_id);
    try std.testing.expectEqual(header.text_headers_len, demarshaled.text_headers_len);
    try std.testing.expectEqual(header.body_len, demarshaled.body_len);
}

test "get first dumb AMP" {
    var amp = try protocol.init(std.testing.allocator, .{});
    _ = try amp.deinit();
}

const std = @import("std");
const testing = std.testing;

const protocol = @import("protocol.zig");
const BinaryHeader = protocol.BinaryHeader;
const AMP = protocol.AMP;
