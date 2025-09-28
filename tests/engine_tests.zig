// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

// test {
//     std.testing.log_level = .debug;
//     std.log.debug("engine_tests\r\n", .{});
// }
//
// test "ampe just create/destroy" {
//     std.testing.log_level = .debug;
//     try recipes.createDestroyMain(gpa);
//     try recipes.createDestroyEngine(gpa);
//     try recipes.createDestroyMessageChannelGroup(gpa);
// }
//
// test "dealing with pool" {
//     std.testing.log_level = .debug;
//     try recipes.getMsgsFromSmallestPool(gpa);
// }

test "send illegal messages" {
    std.testing.log_level = .debug;
    // recipes.sendMessageFromThePool(gpa) catch |err| {
    //     try testing.expect(err == AmpeError.InvalidMessageMode);
    // };
    // recipes.handleMessageWithWrongChannelNumber(gpa) catch |err| {
    //     try testing.expect(err == AmpeError.InvalidChannelNumber);
    // };
    // recipes.handleHelloWithoutConfiguration(gpa) catch |err| {
    //     try testing.expect(err == AmpeError.WrongConfiguration);
    // };

    recipes.handleHelloWithWrongAddress(gpa) catch |err| {
        try testing.expect(err == AmpeError.InvalidAddress);
    };
}

const tofu = @import("tofu");

const recipes = @import("recipes");

const engine = tofu.engine;
const Ampe = engine.Ampe;
const MessageChannelGroup = engine.MessageChannelGroup;

const message = tofu.message;
const MessageType = message.MessageType;
const MessageRole = message.MessageRole;
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
