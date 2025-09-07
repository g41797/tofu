// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "ampe just create/destroy" {
    var dtr = Distributor.Create(std.testing.allocator, engine.DefaultOptions) catch unreachable;
    defer dtr.Destroy();

    const ampe = try dtr.ampe();

    const mcg = try ampe.acquire();

    defer ampe.release(mcg) catch @panic("ampe.release(mcg) failed");
}

test "ampe illegal messages" {
    var dtr = Distributor.Create(std.testing.allocator, engine.DefaultOptions) catch unreachable;
    defer dtr.Destroy();

    const ampe = try dtr.ampe();

    const mcg = try ampe.acquire();
    defer ampe.release(mcg) catch @panic("ampe.release(mcg) failed");

    var msg: ?*Message = try Message.create(gpa);
    defer Message.DestroySendMsg(&msg);

    // Send app. signal to channel 0
    msg.?.bhdr.proto.mode = .signal;

    _ = mcg.asyncSend(&msg) catch |err| {
        try testing.expect(err == AmpeError.InvalidChannelNumber);
    };
}

const engine = @import("engine.zig");
const Ampe = engine.Ampe;
const MessageChannelGroup = engine.MessageChannelGroup;

pub const message = @import("message.zig");
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = message.TextHeaderIterator;
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const VC = message.ValidCombination;

pub const status = @import("status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;

pub const Distributor = @import("engine/Distributor.zig");

const std = @import("std");
const testing = std.testing;
const gpa = std.testing.allocator;
