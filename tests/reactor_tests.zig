// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

fn test_handle_reconnect_single_threaded() !void {
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

fn test_handle_reconnect_multithreaded() !void {
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

fn test_connect_disconnect() !void {
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

fn test_ampe_just_create_destroy() !void {
    std.testing.log_level = .debug;
    try recipes.createDestroyMain(gpa);
    try recipes.createDestroyAmpe(gpa);
    try recipes.createDestroyChannelGroup(gpa);
}

fn simm_tests() void {
    std.testing.log_level = .debug;

    const tests = &[_]*const fn () void{
        &try_ampe_just_create_destroy,
        &try_connect_disconnect,
        &try_handle_reconnect_single_threaded,
        &try_handle_reconnect_multithreaded,

        &try_ampe_just_create_destroy,
        &try_connect_disconnect,
        &try_handle_reconnect_single_threaded,
        &try_handle_reconnect_multithreaded,
    };
    tofu.RunTasks(gpa, tests) catch unreachable;
}

fn try_ampe_just_create_destroy() void {
    test_ampe_just_create_destroy() catch unreachable;
}

fn try_connect_disconnect() void {
    // test_connect_disconnect() catch unreachable;
}

fn try_handle_reconnect_single_threaded() void {
    test_handle_reconnect_single_threaded() catch unreachable;
}

fn try_handle_reconnect_multithreaded() void {
    test_handle_reconnect_multithreaded() catch unreachable;
}

test {
    std.testing.log_level = .debug;
    std.log.debug("engine_tests\r\n", .{});
}

test "send illegal messages" {
    wsaInit();
    defer wsaCleanup();
    try send_illegal_messages();
}

fn send_illegal_messages() !void {
    std.testing.log_level = .debug;
    recipes.sendMessageFromThePool(gpa) catch |err| {
        try testing.expect(err == AmpeError.InvalidChannelNumber);
    };

    recipes.handleMessageWithWrongChannelNumber(gpa) catch |err| {
        try testing.expect(err == AmpeError.InvalidChannelNumber);
    };

    recipes.handleHelloWithoutAddress(gpa) catch |err| {
        try testing.expect(err == AmpeError.WrongAddress);
    };

    recipes.handleHelloWithWrongAddress(gpa) catch |err| {
        try testing.expect(err == AmpeError.InvalidAddress);
    };

    log.info("start handleHelloToNonListeningServer ", .{});
    recipes.handleHelloToNonListeningServer(gpa) catch |err| {
        log.info("handleHelloToNonListeningServer {any}", .{
            err,
        });
        // On Windows, connect to non-listening port may report CommunicationFailed
        // (via AFD_POLL_CONNECT_FAIL → err trigger) instead of ConnectFailed.
        try testing.expect(err == AmpeError.ConnectFailed or err == AmpeError.CommunicationFailed);
    };

    log.info("<{d}> start handleWelcomeWithWrongAddress ", .{getCurrentTid()});
    recipes.handleWelcomeWithWrongAddress(gpa) catch |err| {
        log.info("handleWelcomeWithWrongAddress {any}", .{
            err,
        });
        try testing.expect((err == AmpeError.InvalidAddress) or (err == AmpeError.ListenFailed));
    };
}

test "find free TCP/IP port" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;

    log.info("start find free TCP/IP port ", .{});

    const port = try tofu.FindFreeTcpPort();

    log.debug("free TCP/IP port {d}", .{port});

    try std.testing.expect(port > 0); // Ensure a valid port is returned
}

test "update receiver" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;

    log.info("start handleUpdateReceiver ", .{});

    const updateStatus = recipes.handleUpdateReceiver(gpa) catch |err| {
        log.info("handleUpdateReceiver {any}", .{
            err,
        });
        return err;
    };
    try testing.expect(updateStatus == .receiver_update);
}

test "ampe just create/destroy" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;
    try test_ampe_just_create_destroy();
}

test "connect_disconnect" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;
    try test_connect_disconnect();
}

test "handle reconnect single threaded" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;
    try test_handle_reconnect_single_threaded();
}

test "handle reconnect multithreaded" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;
    try test_handle_reconnect_multithreaded();
}

test "loop tests" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;

    for (0..5) |i| {
        {
            log.debug("test_ampe_just_create_destroy {d}", .{i});
            try test_ampe_just_create_destroy();
        }
        {
            log.debug("test_connect_disconnect {d}", .{i});
            try test_connect_disconnect();
        }
        {
            log.debug("test_handle_reconnect_single_threaded {d}", .{i});
            try test_handle_reconnect_single_threaded();
        }
        {
            log.debug("test_handle_reconnect_multithreaded {d}", .{i});
            try test_handle_reconnect_multithreaded();
        }
    }
}

test "simm test" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;

    const tests = &[_]*const fn () void{
        &simm_tests,
        &simm_tests,
        &simm_tests,
        &simm_tests,
    };

    tofu.RunTasks(gpa, tests) catch unreachable;

    std.debug.print("All tests completed\n", .{});
}

test "echo client/server test" {
    wsaInit();
    defer wsaCleanup();
    std.testing.log_level = .debug;

    const est: status.AmpeStatus = try recipes.handleEchoClientServer(std.testing.allocator);

    try testing.expect(est == .success);
}

const tofu = @import("tofu");

const recipes_mod = @import("recipes");
const recipes = recipes_mod.cookbook;

const Ampe = tofu.Ampe;
const ChannelGroup = tofu.ChannelGroup;

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
const VC = message.ValidForSend;

const status = tofu.status;
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;

const Reactor = tofu.Reactor;

const std = @import("std");
const builtin = @import("builtin");
const Thread = std.Thread;
const getCurrentTid = Thread.getCurrentId;

const testing = std.testing;
const gpa = std.testing.allocator;
const log = std.log;

fn wsaInit() void {
    if (builtin.os.tag == .windows) {
        var wsa_data: std.os.windows.ws2_32.WSADATA = undefined;
        _ = std.os.windows.ws2_32.WSAStartup(0x0202, &wsa_data);
    }
}

fn wsaCleanup() void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.WSACleanup();
    }
}
