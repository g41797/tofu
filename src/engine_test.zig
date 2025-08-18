// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "sequential message id" {
    const mid = engine.next_mid();
    const nextmid = engine.next_mid();
    try testing.expectEqual(mid + 1, nextmid);
}

test "BinaryHeader marshalling and demarshalling" {
    var header = BinaryHeader{
        .channel_number = 0x1234,
        .proto = .{
            .mtype = .control,
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

    var buf: [BinaryHeader.BHSIZE]u8 = undefined;
    header.toBytes(&buf);

    var demarshaled: BinaryHeader = undefined;
    demarshaled.fromBytes(&buf);

    try std.testing.expectEqual(header.channel_number, demarshaled.channel_number);
    try std.testing.expectEqual(header.proto.mtype, demarshaled.proto.mtype);
    try std.testing.expectEqual(header.proto.mode, demarshaled.proto.mode);
    try std.testing.expectEqual(header.status, demarshaled.status);
    try std.testing.expectEqual(header.message_id, demarshaled.message_id);
    try std.testing.expectEqual(header.text_headers_len, demarshaled.text_headers_len);
    try std.testing.expectEqual(header.body_len, demarshaled.body_len);
}

test "get first dumb AMP" {
    const amp = try engine.start(std.testing.allocator, .{});
    defer destroyDefer(amp);
}

const force_get = true;

test "send wrong message" {
    const amp = try engine.start(std.testing.allocator, .{});
    defer destroyDefer(amp);

    var msg = amp.get(force_get);
    try std.testing.expectEqual(true, msg != null);
    amp.put(msg.?);

    msg = amp.get(force_get);
    try std.testing.expectEqual(true, msg != null);

    try std.testing.expectError(AmpeError.InvalidMessageMode, amp.start_send(msg.?));
    amp.put(msg.?);

    msg = amp.get(force_get);
    var msgv = msg.?;
    msgv.bhdr.proto.mtype = .welcome;
    msgv.bhdr.proto.mode = .response;

    try std.testing.expectError(AmpeError.InvalidMessageId, amp.start_send(msgv));

    msgv.bhdr.message_id = 1234;

    try std.testing.expectError(AmpeError.NotAllowed, amp.start_send(msgv));

    msgv.reset();
    msgv.bhdr.proto.mtype = .welcome;
    msgv.bhdr.proto.mode = .request;
    try std.testing.expectError(AmpeError.InvalidAddress, amp.start_send(msgv));

    amp.put(msgv);
}

fn destroyDefer(amp: *AMP) void {
    amp.destroy() catch unreachable;
}

// test "random from u16" {
//     const rand = std.crypto.random;
//
//     _ = rand.int(u16);
// }

test "Ampe create/destroy" {
    var dtr = Distributor.init(std.testing.allocator, .{}) catch unreachable;
    defer dtr.deinit();

    const ampe = try dtr.ampe();

    const sr = try ampe.create();

    try ampe.destroy(sr);
}

const std = @import("std");
const testing = std.testing;

const engine = @import("engine.zig");
const Ampe = engine.Ampe;
const Sr = engine.Sr;

const AMP = engine.AMP;

pub const message = @import("message.zig");
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = @import("TextHeaderIterator.zig");
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const VC = message.ValidCombination;

pub const status = @import("status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;

pub const Distributor = @import("engine/Distributor.zig");
