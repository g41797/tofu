// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "ampe just create/destroy" {
    try recipes.createDestroyMainStruct(gpa);
    try recipes.createDestroyMsgEngine(gpa);
    try recipes.createDestroyMessageChannelGroup(gpa);
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

const tofu = @import("tofu");

const recipes = @import("recipes");

const engine = tofu.engine;
const Ampe = engine.Ampe;
const MessageChannelGroup = engine.MessageChannelGroup;

const message = tofu.message;
const MessageType = message.MessageType;
const MessageMode = message.MessageMode;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = message.TextHeaderIterator;
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageID = message.MessageID;
const VC = message.ValidCombination;

const status = tofu.status;
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;

const Distributor = tofu.Distributor;

const std = @import("std");
const testing = std.testing;
const gpa = std.testing.allocator;
