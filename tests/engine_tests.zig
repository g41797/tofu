// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("engine_tests\r\n", .{});
}

// test "handle reconnect ST with connector helper" {
//     std.testing.log_level = .debug;
//
//     const reconnectStatus = recipes.handleReConnnectOfUdsClientServerSTViaConnector(gpa) catch |err| {
//         log.info("handleReConnnectOfUdsClientServerSTViaConnector {any}", .{
//             err,
//         });
//         return err;
//     };
//     try testing.expect(reconnectStatus == .success);
// }

test "handle reconnect single threaded" {
    std.testing.log_level = .debug;

    const reconnectUdsStatus = recipes.handleReConnnectOfUdsClientServerST(gpa) catch |err| {
        log.info("handleReConnnectOfUdsClientServerST {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(reconnectUdsStatus == .success);

    const reconnectTcpStatus = recipes.handleReConnnectOfTcpClientServerST(gpa) catch |err| {
        log.info("handleReConnnectOfTcpClientServerST {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(reconnectTcpStatus == .success);
}

test "handle reconnect multithreaded" {
    std.testing.log_level = .debug;

    const reconnectStatusTcp = recipes.handleReConnnectOfTcpClientServerMT(gpa) catch |err| {
        log.info("handleReConnnectOfTcpClientServerMT {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(reconnectStatusTcp == .success);

    const reconnectStatusUds = recipes.handleReConnnectOfUdsClientServerMT(gpa) catch |err| {
        log.info("handleReConnnectOfTcpClientServerMT {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(reconnectStatusUds == .success);
}
//
test "update waiter" {
    std.testing.log_level = .debug;

    const updateStatus = recipes.handleUpdateWaiter(gpa) catch |err| {
        log.info("handleUpdateWaiter {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(updateStatus == .waiter_update);
}
//
test "connect/disconnect" {
    std.testing.log_level = .debug;

    const listenTcpStatus = recipes.handleStartOfTcpServerAkaListener(gpa) catch |err| {
        log.info("handleStartOfTcpServerAkaListener {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(listenTcpStatus == .success);

    const listen2TcpStatus = recipes.handleStartOfTcpListeners(gpa) catch |err| {
        log.info("handleStartOfTcpServerAkaListener {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(listen2TcpStatus == .success);

    const listenUdsStatus = recipes.handleStartOfUdsServerAkaListener(gpa) catch |err| {
        log.info("handleStartOfUdsServerAkaListener {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(listenUdsStatus == .success);

    const listen2UdsStatus = recipes.handleStartOfUdsListeners(gpa) catch |err| {
        log.info("handleStartOfUdsServerAkaListener {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(listen2UdsStatus == .success);

    const connectTcpStatus = recipes.handleConnnectOfTcpClientServer(gpa) catch |err| {
        log.info("handleConnnectOfTcpClientServer {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(connectTcpStatus == .success);

    const connectUdsStatus = recipes.handleConnnectOfUdsClientServer(gpa) catch |err| {
        log.info("handleConnnectOfUdsClientServer {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(connectUdsStatus == .success);
}
//
test "ampe just create/destroy" {
    std.testing.log_level = .debug;
    try recipes.createDestroyMain(gpa);
    try recipes.createDestroyEngine(gpa);
    try recipes.createDestroyMessageChannelGroup(gpa);
}

test "send illegal messages" {
    std.testing.log_level = .debug;
    recipes.sendMessageFromThePool(gpa) catch |err| {
        try testing.expect(err == AmpeError.InvalidMessageMode);
    };
    recipes.handleMessageWithWrongChannelNumber(gpa) catch |err| {
        try testing.expect(err == AmpeError.InvalidChannelNumber);
    };
    recipes.handleHelloWithoutConfiguration(gpa) catch |err| {
        try testing.expect(err == AmpeError.WrongConfiguration);
    };

    recipes.handleHelloWithWrongAddress(gpa) catch |err| {
        try testing.expect(err == AmpeError.InvalidAddress);
    };

    recipes.handleHelloToNonListeningServer(gpa) catch |err| {
        log.info("handleHelloToNonListeningServer {any}", .{
            err,
        });
        try testing.expect(err == AmpeError.ConnectFailed);
    };

    recipes.handleWelcomeWithWrongAddress(gpa) catch |err| {
        log.info("handleWelcomeWithWrongAddress {any}", .{
            err,
        });
        try testing.expect(err == AmpeError.InvalidAddress);
    };
}

const tofu = @import("tofu");

const recipes = @import("recipes");

const Ampe = tofu.Ampe;
const Channels = tofu.Channels;

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

const Engine = tofu.Engine;

const std = @import("std");

const testing = std.testing;
const gpa = std.testing.allocator;
const log = std.log;
