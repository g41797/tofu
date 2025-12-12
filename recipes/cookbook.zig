const cookbook = @This();

const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const testing = std.testing;
const alctr = std.testing.allocator;

// Import of module 'tofu'
pub const tofu = @import("tofu");

// Reactor: The single-threaded, event-driven implementation
// of the Ampe interface. It utilizes the Reactor pattern to multiplex
// non-blocking socket I/O via an internal poll-style loop.
pub const Reactor = tofu.Reactor;

pub const Ampe = tofu.Ampe;

// Contains settings for the internal message pool.
pub const Options = tofu.Options;

// The default configuration options for the pool.
pub const DefaultOptions = tofu.DefaultOptions;

// A grouping mechanism for managing a collection of related channels.
pub const ChannelGroup = tofu.ChannelGroup;

pub const message = tofu.message;

// The core Message structure processed by the engine.
pub const Message = tofu.Message;

// Meta-data for the Message.
// Used internally by the engine for routing and by the application for context.
pub const BinaryHeader = message.BinaryHeader;

pub const status = tofu.status;
// An enum representation of the status byte
// (part of BinaryHeader) for clear status tracking.
pub const AmpeStatus = status.AmpeStatus;
// An error type corresponding to the status above,
// used for conveying failure states.
pub const AmpeError = status.AmpeError;

// Helpers - for convenient injection of socket addresses
// to the message.
pub const configurator = tofu.configurator;
pub const Configurator = configurator.Configurator;

pub const services = @import("services.zig");

pub fn createDestroyMain(gpa: Allocator) !void {
    var rtr = try Reactor.Create(gpa, DefaultOptions);
    defer rtr.Destroy();
}

pub fn createDestroyAmpe(gpa: Allocator) !void {
    // Create engine implementation object
    const rtr: *Reactor = try Reactor.Create(gpa, DefaultOptions);

    // Destroy it after return or on error
    defer rtr.*.Destroy();

    // Create ampe interface
    const ampe: Ampe = try rtr.*.ampe();

    _ = ampe;

    // No need to destroy ampe itself.
    // It is an interface provided by Reactor.
    // It will be destroyed via  rtr.*.Destroy().
}

pub fn createDestroyChannelGroup(gpa: Allocator) !void {
    const rtr: *Reactor = try Reactor.Create(gpa, DefaultOptions);
    defer rtr.*.Destroy();

    const ampe: Ampe = try rtr.*.ampe();

    const chnls: ChannelGroup = try ampe.create();

    defer {
        _ = ampe.destroy(chnls) catch |err| {
            std.log.err("destroy channel group failed with error {any}", .{err});
        };
    }
}

pub fn getMsgsFromSmallestPool(gpa: Allocator) !void {
    // If options have invalid values (0 or maxPoolMsgs < initialPoolMsgs),
    // DefaultOptions will be used.
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    var rtr = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe = try rtr.ampe();

    const chnls = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    var msg1: ?*Message = try ampe.get(tofu.AllocationStrategy.always);

    // If msg1 is not null, return it to the pool.
    // Pool is cleaned during rtr.Destroy().
    defer ampe.put(&msg1);

    if (msg1 == null) {
        return error.FirstMesssageShouldBeNotNull;
    }

    var msg2 = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg2);
    if (msg2 != null) {
        return error.SecondMesssageShouldBeNull;
    }

    // Pool is empty, but a message will be allocated.
    var msg3 = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&msg3);
    if (msg3 == null) {
        return error.THirdMesssageShouldBeNotNull;
    }

    return;
}

pub fn sendMessageFromThePool(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    const rtr: *tofu.Reactor = try tofu.Reactor.Create(gpa, options);
    defer rtr.*.Destroy();
    const ampe = try rtr.*.ampe();

    const chnls: ChannelGroup = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // Ignore errors for this example.
    };

    var msg: ?*tofu.Message = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&msg);

    // Message from the pool is not ready for sending.
    // It needs setup first.
    // It will be returned to the pool by defer.
    _ = try chnls.enqueueToPeer(&msg);

    return;
}

pub fn handleMessageWithWrongChannelNumber(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    var rtr = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe = try rtr.ampe();

    const chnls = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // Ignore errors for this example.
    };

    var msg = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&msg);

    // Only MessageType.hello and MessageType.welcome can use channel number 0.
    // Other messages need a valid, non-zero channel number.

    // Invalid Bye Request.
    msg.?.*.bhdr.proto.mtype = .bye;
    msg.?.*.bhdr.proto.role = .request;

    _ = try chnls.enqueueToPeer(&msg);

    return;
}

pub fn handleHelloWithoutConfiguration(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    var rtr = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe = try rtr.ampe();

    const chnls = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // Ignore errors for this example.
    };

    var msg = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&msg);

    // A valid channel number is not enough.
    // MessageType.hello needs the peer (server) address.
    // MessageType.welcome needs the server address for listening.

    // Hello Request without server address (configuration).
    msg.?.*.bhdr.proto.mtype = .hello;
    msg.?.*.bhdr.proto.role = .request;

    _ = try chnls.enqueueToPeer(&msg);

    return;
}

pub fn handleHelloWithWrongAddress(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    var rtr = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe = try rtr.ampe();

    const chnls = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&msg);

    // MessageType.hello needs a valid, resolvable peer (server) address.
    // For IP addresses, it must be valid.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server address is "tofu.server.zig", port 3298.
    // Use helpers to create the configuration for a hello request.

    var cnfg: Configurator = .{ .tcp_client = configurator.TCPClientConfigurator.init("tofu.server.zig", try tofu.FindFreeTcpPort()) };

    // Adds configuration to the message's TextHeaders.
    try cnfg.prepareRequest(msg.?);

    _ = try chnls.enqueueToPeer(&msg);

    var recvMsg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    const st = recvMsg.?.*.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleHelloToNonListeningServer(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 64, // Example value.
    };

    var rtr = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe = try rtr.ampe();

    const chnls = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&msg);

    // MessageType.hello needs a valid, resolvable peer (server) address.
    // For IP addresses, it must be valid.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server address is "127.0.0.1", port 32987.
    // Use helpers to create the configuration for a hello request.

    var cnfg: Configurator = .{ .tcp_client = configurator.TCPClientConfigurator.init("127.0.0.1", try tofu.FindFreeTcpPort()) };

    // Adds configuration to the message's TextHeaders.
    try cnfg.prepareRequest(msg.?);

    // Store information for further processing.
    const bhdr = try chnls.enqueueToPeer(&msg);
    _ = bhdr;

    var recvMsg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    const st = recvMsg.?.*.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleWelcomeWithWrongAddress(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 10, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var rtr = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe = try rtr.ampe();

    const chnls = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&msg);

    // MessageType.welcome needs the IP address and port of the listening server.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server has an invalid IP address "192.128.4.5", port 3298.
    // Use helpers to create the configuration for a welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("192.128.4.5", 3298) };

    // Adds configuration to the message's TextHeaders.
    try cnfg.prepareRequest(msg.?);

    _ = try chnls.enqueueToPeer(&msg);

    var recvMsg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    const st = recvMsg.?.*.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleStartOfTcpServerAkaListener(gpa: Allocator) !AmpeStatus {
    // WelcomeRequest for a TCP server needs the IP address and port of the listening server.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server listens on all interfaces (IPv4 "0.0.0.0"), port 32984.
    // Use helpers to create the configuration for a welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("0.0.0.0", try tofu.FindFreeTcpPort()) };

    return handleStartOfListener(gpa, &cnfg, false);
}

pub fn handleStartOfUdsServerAkaListener(gpa: Allocator) !AmpeStatus {
    // UDS (Unix Domain Socket) uses a file path for communication on the same machine,
    // unlike network sockets that use IP addresses and ports.

    // WelcomeRequest for a UDS server needs a file path.
    // Tofu provides a helper to create a temporary file path for testing.

    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    // Create configurator for UDS server.
    var cnfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };

    return handleStartOfListener(gpa, &cnfg, false);
}

pub fn handleStartOfTcpListeners(gpa: Allocator) !AmpeStatus {
    // WelcomeRequest for a TCP server needs the IP address and port of the listening server.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server listens on all interfaces (IPv4 "0.0.0.0"), port 32984.
    // Use helpers to create the configuration for a welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("0.0.0.0", try tofu.FindFreeTcpPort()) };

    return handleStartOfListener(gpa, &cnfg, true);
}

pub fn handleStartOfUdsListeners(gpa: Allocator) !AmpeStatus {
    // UDS (Unix Domain Socket) uses a file path for communication on the same machine,
    // unlike network sockets that use IP addresses and ports.

    // WelcomeRequest for a UDS server needs a file path.
    // Tofu provides a helper to create a temporary file path for testing.

    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    // Create configurator for UDS server.
    var cnfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };

    return handleStartOfListener(gpa, &cnfg, true);
}

pub fn handleStartOfListener(gpa: Allocator, cnfg: *Configurator, runTheSame: bool) !AmpeStatus {
    // Same code for TCP and UDS servers, only configuration differs.

    const options: tofu.Options = .{
        .initialPoolMsgs = 2, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var rtr: *Reactor = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe: Ampe = try rtr.ampe();

    const chnls: ChannelGroup = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // Adds configuration to the message's TextHeaders.
    try cnfg.prepareRequest(msg.?);

    const corrInfo: BinaryHeader = try chnls.enqueueToPeer(&msg);

    var recvMsg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    // Return message to the pool.
    defer ampe.put(&recvMsg);

    const st = recvMsg.?.*.bhdr.status;

    // Received message should have the same channel number.
    assert(corrInfo.channel_number == recvMsg.?.*.bhdr.channel_number);

    // Since we sent a WelcomeRequest, the received message should be a WelcomeResponse
    // with the listen status (success or failure).
    // A WelcomeSignal would return a Signal with an error status for failed listen.
    assert(recvMsg.?.*.bhdr.proto.mtype == .welcome);
    assert(recvMsg.?.*.bhdr.proto.role == .response);

    // Run of the same listener should fail with status TBD
    if (runTheSame) {
        const lst: AmpeStatus = try handleStartOfListener(gpa, cnfg, false);
        return lst;
    }

    // Channel is not closed explicitly.
    // It closes during ChannelGroup destruction (see defer above).

    // Convert status byte to AmpeStatus enum for convenience.
    return status.raw_to_status(st);
}

pub fn handleConnnectOfTcpClientServer(gpa: Allocator) anyerror!AmpeStatus {
    // Both server and client are on localhost.
    const port = try tofu.FindFreeTcpPort();

    var srvCfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("127.0.0.1", port) };
    var cltCfg: Configurator = .{ .tcp_client = configurator.TCPClientConfigurator.init("127.0.0.1", port) };

    return handleConnect(gpa, &srvCfg, &cltCfg);
}

pub fn handleConnnectOfUdsClientServer(gpa: Allocator) anyerror!AmpeStatus {
    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    var srvCfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };
    var cltCfg: Configurator = .{ .uds_client = configurator.UDSClientConfigurator.init(filePath) };

    return handleConnect(gpa, &srvCfg, &cltCfg);
}

pub fn handleConnect(gpa: Allocator, srvCfg: *Configurator, cltCfg: *Configurator) anyerror!AmpeStatus {
    // Same code for TCP and UDS client/server, only configurations differ.
    // Configurations must match (both TCP or both UDS).

    const options: tofu.Options = .{
        // Set to relative high value in order to not handle
        // pool_empty status.
        // But be ready to handle it in the field
        .initialPoolMsgs = 24, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var rtr: *Reactor = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe: Ampe = try rtr.ampe();

    // For simplicity, use the same ChannelGroup for client and server.
    // In production, you can use separate ChannelGroup for each.

    const chnls: ChannelGroup = try ampe.create();

    // Channel closes during ChannelGroup destruction.
    defer tofu.DestroyChannels(ampe, chnls);

    var welcomeRequest: ?*Message = try ampe.get(tofu.AllocationStrategy.poolOnly);

    // If pool is empty, poolOnly strategy returns null.
    if (welcomeRequest == null) {
        // Create a message directly using the same allocator as Reactor.Create.
        welcomeRequest = Message.create(gpa) catch unreachable;
    }

    // After sending, welcomeRequest is set to null.
    // Safe to put null message in the pool.
    // If sending fails, return message to the pool.
    defer ampe.put(&welcomeRequest);

    // Add configuration to the message's TextHeaders.
    try srvCfg.prepareRequest(welcomeRequest.?);

    const srvCorrInfo: BinaryHeader = try chnls.enqueueToPeer(&welcomeRequest);

    var welcomeResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    // Return message to the pool.
    defer ampe.put(&welcomeResp);

    var st: u8 = welcomeResp.?.*.bhdr.status;

    // Convert u8 status to AmpeError.
    status.raw_to_error(st) catch |err| {
        log.info(">><< welcomeResp error {s} ", .{@errorName(err)});
    };

    // Received message should have the same channel number.
    assert(srvCorrInfo.channel_number == welcomeResp.?.*.bhdr.channel_number);

    assert(st == 0); // Don't expect pool_empty in this recipe

    // Received message should have the same message ID.
    // If not set before sending, tofu assigns a sequential number.
    assert(srvCorrInfo.message_id == welcomeResp.?.*.bhdr.message_id);

    // Since we sent a WelcomeRequest, the received message should be a WelcomeResponse
    // with listen status (success or failure).
    // A WelcomeSignal would return a Signal with an error status for failed listen.
    assert(welcomeResp.?.*.bhdr.proto.mtype == .welcome);
    assert(welcomeResp.?.*.bhdr.proto.role == .response);

    // Listener is started before connect for simplicity.
    // In production, check connect status and retry if needed.
    // Tofu does not support automatic reconnection.

    // To connect, repeat similar steps as for the listener.
    var helloRequest: ?*Message = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&helloRequest);

    // Add configuration to the message's TextHeaders.
    try cltCfg.prepareRequest(helloRequest.?);

    const cltCorrInfo: BinaryHeader = try chnls.enqueueToPeer(&helloRequest);

    // Client and server channels must be different.
    assert(cltCorrInfo.channel_number != srvCorrInfo.channel_number);

    // Since ChannelGroup handles both client and server,
    // we receive a HelloRequest from the client side.
    // A successful HelloRequest involves:
    // - Connecting to the server.
    // - Sending the HelloRequest message.
    // Network/socket operations run on a dedicated thread.
    // enqueueToPeer and waitReceive work with internal message queues.

    var helloRequestOnServerSide: ?*Message = try chnls.waitReceive(tofu.waitReceive_SEC_TIMEOUT * 20);
    defer ampe.put(&helloRequestOnServerSide);

    assert(helloRequestOnServerSide != null);

    st = helloRequestOnServerSide.?.*.bhdr.status;
    const chN: message.ChannelNumber = helloRequestOnServerSide.?.*.bhdr.channel_number;
    status.raw_to_error(st) catch |err| {
        log.info(">><< helloRequestOnServerSide channel {d} error {s} ", .{ chN, @errorName(err) });
    };
    assert(st == 0);

    // Store info about the connected client.
    const connectedClientInfo: BinaryHeader = helloRequestOnServerSide.?.*.bhdr;

    // Three different channels exist:
    // - Listener channel (srvCorrInfo.channel_number).
    // - Client channel on client side (cltCorrInfo.channel_number).
    // - Client channel on server side (connectedClientInfo.channel_number).
    // Each channel is a stream-oriented socket (TCP or UDS).
    // A new socket is created on the server for each connected client.
    assert(connectedClientInfo.channel_number != srvCorrInfo.channel_number);
    assert(connectedClientInfo.channel_number != cltCorrInfo.channel_number);

    // Message ID should match, as helloRequestOnServerSide is a copy of helloRequest.
    assert(connectedClientInfo.message_id == cltCorrInfo.message_id);

    // Use the same message to send HelloResponse back.
    // Set role to .response for HelloResponse.
    helloRequestOnServerSide.?.*.bhdr.proto.role = .response;
    _ = try chnls.enqueueToPeer(&helloRequestOnServerSide);

    // On the client side:
    var helloResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    // Return message to the pool.
    defer ampe.put(&helloResp);

    st = helloResp.?.*.bhdr.status;

    // Received message should have the same channel number and message ID.
    assert(cltCorrInfo.channel_number == helloResp.?.*.bhdr.channel_number);
    assert(cltCorrInfo.message_id == helloResp.?.*.bhdr.message_id);

    // Since we sent a HelloRequest, the received message should be a HelloResponse
    // - From engine with error status if failed.
    // - From server if connect and HelloRequest succeeded.
    // A HelloSignal would return a Signal with an error status for failed connect.
    assert(welcomeResp.?.*.bhdr.proto.mtype == .welcome);
    assert(welcomeResp.?.*.bhdr.proto.role == .response);

    // Close all three channels in 'force' mode using ByeSignal with oob = on.
    var closeListener: ?*Message = try ampe.get(tofu.AllocationStrategy.always);

    // Prepare ByeSignal for the listener channel.
    closeListener.?.*.bhdr.proto.mtype = .bye;
    closeListener.?.*.bhdr.proto.role = .signal;
    closeListener.?.*.bhdr.proto.oob = .on;

    // Set channel number to close this channel.
    closeListener.?.*.bhdr.channel_number = srvCorrInfo.channel_number;

    _ = try chnls.enqueueToPeer(&closeListener);

    var closeListenerResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&closeListenerResp);

    assert(closeListenerResp.?.*.bhdr.status == status.status_to_raw(AmpeStatus.channel_closed));

    // Close one of the client channels.
    var closeClient: ?*Message = try ampe.get(tofu.AllocationStrategy.always);

    // Prepare ByeSignal for the client channel.
    closeClient.?.*.bhdr.proto.mtype = .bye;
    closeClient.?.*.bhdr.proto.role = .signal;
    closeClient.?.*.bhdr.proto.oob = .on;

    // Set channel number to close this channel.
    closeClient.?.*.bhdr.channel_number = cltCorrInfo.channel_number; // Client channel on client side.

    _ = try chnls.enqueueToPeer(&closeClient);

    // Expect two messages with status, as closing one socket
    // also closes the corresponding server-side socket.
    for (0..2) |_| {
        var closeClientResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
        defer ampe.put(&closeClientResp);
        assert(closeClientResp.?.*.bhdr.status == status.status_to_raw(AmpeStatus.channel_closed));
    }

    // Tofu programming mainly involves setting message data.
    // Only three communication APIs exist.
    // Two are used here:
    // - enqueueToPeer
    // - waitReceive

    // Convert status byte to AmpeStatus enum for convenience.
    return status.raw_to_status(st);
}

pub fn handleUpdateWaiter(gpa: Allocator) anyerror!AmpeStatus {
    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var rtr: *Reactor = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe: Ampe = try rtr.ampe();
    const chnls: ChannelGroup = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    var attention: ?*Message = try chnls.waitReceive(100);
    defer ampe.put(&attention);

    // No message expected.
    assert(attention == null);

    // Send attention signal to itself.
    try chnls.updateWaiter(&attention);

    attention = try chnls.waitReceive(100);

    assert(attention.?.*.bhdr.message_id == 0);
    assert(attention.?.*.bhdr.channel_number == 0);
    assert(attention.?.*.bhdr.proto.origin == .engine);
    assert(attention.?.*.bhdr.proto.role == .signal);
    assert(status.raw_to_status(attention.?.*.bhdr.status) == .waiter_update);

    // Create update message from existing signal.
    attention.?.*.bhdr.proto.role = .request;
    attention.?.*.bhdr.status = 0;
    attention.?.*.bhdr.message_id = 1;

    try chnls.updateWaiter(&attention);

    attention = try chnls.waitReceive(100);

    assert(attention.?.*.bhdr.message_id == 1);
    assert(attention.?.*.bhdr.channel_number == 0);
    assert(attention.?.*.bhdr.proto.origin == .application);
    assert(attention.?.*.bhdr.proto.role == .request);
    assert(status.raw_to_status(attention.?.*.bhdr.status) == .waiter_update);

    return status.raw_to_status(attention.?.*.bhdr.status);
}

pub fn handleReConnnectOfTcpClientServerMT(gpa: Allocator) anyerror!AmpeStatus {
    // Both server and client are on localhost.
    const port = try tofu.FindFreeTcpPort();
    var srvCfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("127.0.0.1", port) };
    var cltCfg: Configurator = .{ .tcp_client = configurator.TCPClientConfigurator.init("127.0.0.1", port) };

    return handleReConnectMT(gpa, &srvCfg, &cltCfg);
}

pub fn handleReConnnectOfUdsClientServerMT(gpa: Allocator) anyerror!AmpeStatus {
    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    var srvCfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };
    var cltCfg: Configurator = .{ .uds_client = configurator.UDSClientConfigurator.init(filePath) };

    return handleReConnectMT(gpa, &srvCfg, &cltCfg);
}

pub fn handleReConnectMT(gpa: Allocator, srvCfg: *Configurator, cltCfg: *Configurator) anyerror!AmpeStatus {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1024, // Example value.
        .maxPoolMsgs = 1024, // Example value.
    };

    var rtr: *Reactor = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe: Ampe = try rtr.ampe();

    const TofuClient = struct {
        const Self = @This();
        gpa: Allocator = undefined,
        ampe: Ampe = undefined,
        chnls: ?ChannelGroup = undefined,
        cfg: Configurator = undefined,
        result: ?AmpeStatus = undefined,

        fn runOnThread(self: *Self) void {
            while (true) {
                var helloRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
                defer self.*.ampe.put(&helloRequest);

                self.*.cfg.prepareRequest(helloRequest.?) catch unreachable;

                _ = self.*.chnls.?.enqueueToPeer(&helloRequest) catch unreachable;

                var recvMsg: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                    log.info("On client thread - waitReceive error {s}", .{@errorName(err)});
                    return;
                };
                defer self.ampe.put(&recvMsg);

                if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .connect_failed) {
                    // Connection failed - reconnect
                    continue;
                }

                if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                    log.info("Pool is empy - return message to the pool", .{});
                    continue;
                }

                if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .waiter_update) {
                    log.info("On client thread - exit required", .{});
                    return;
                }

                if (recvMsg.?.*.bhdr.proto.mtype == .hello) {
                    assert(recvMsg.?.*.bhdr.proto.role == .response);

                    // Connected to server
                    self.*.result = .success;

                    // Disconnect from server
                    recvMsg.?.*.bhdr.proto.mtype = .bye;
                    recvMsg.?.*.bhdr.proto.origin = .application;
                    recvMsg.?.*.bhdr.proto.role = .signal;
                    recvMsg.?.*.bhdr.proto.oob = .on;
                    _ = self.*.chnls.?.enqueueToPeer(&recvMsg) catch unreachable;
                    return;
                }
            }

            while (true) {
                var recvMsg: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_SEC_TIMEOUT) catch |err| {
                    log.info("On client thread - waitReceive error {s}", .{@errorName(err)});
                    return;
                };
                defer self.ampe.put(&recvMsg);

                if (recvMsg == null) {
                    continue;
                }

                if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                    log.info("Pool is empy - return message to the pool", .{});
                    continue;
                }

                if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .waiter_update) {
                    log.info("On client thread - exit required", .{});
                    return;
                }
                if (recvMsg.?.*.bhdr.status != 0) {
                    status.raw_to_error(recvMsg.?.*.bhdr.status) catch |err| {
                        log.info("On client thread - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        continue;
                    };
                }
            }

            return;
        }

        pub fn Create(allocator: Allocator, engine: Ampe, cfg: *Configurator) !*Self {
            const result: *Self = allocator.create(Self) catch {
                return AmpeError.AllocationFailed;
            };
            errdefer allocator.destroy(result);

            result.* = .{
                .gpa = allocator,
                .ampe = engine,
                .cfg = cfg.*,
                .chnls = try engine.create(),
                .result = AmpeStatus.success,
            };
            return result;
        }

        pub fn deinit(self: *Self) void {
            if (self.chnls != null) {
                self.ampe.destroy(self.chnls.?) catch {};
                self.chnls = null;
            }
            return;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.gpa;
            defer allocator.destroy(self);
            self.deinit();
            return;
        }
    };

    const TofuServer = struct {
        const Self = @This();
        gpa: Allocator = undefined,
        ampe: Ampe = undefined,
        chnls: ?ChannelGroup = undefined,
        cfg: Configurator = undefined,
        result: ?AmpeStatus = .unknown_error,

        fn runOnThread(self: *Self) void {
            while (true) { // Create listener

                var welcomeRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
                defer self.*.ampe.put(&welcomeRequest);

                self.*.cfg.prepareRequest(welcomeRequest.?) catch unreachable;

                _ = self.*.chnls.?.enqueueToPeer(&welcomeRequest) catch unreachable;

                var welcomeResponse: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                    log.info("On server thread - waitReceive error {s}", .{@errorName(err)});
                    return;
                };
                defer self.ampe.put(&welcomeResponse);

                if (welcomeResponse.?.*.bhdr.status != 0) {
                    if (status.raw_to_status(welcomeResponse.?.*.bhdr.status) == .pool_empty) {
                        log.info("Pool is empy - return message to the pool", .{});
                        continue;
                    }
                    if (status.raw_to_status(welcomeResponse.?.*.bhdr.status) == .channel_closed) {
                        log.info("On server thread - closed channel {d}", .{welcomeResponse.?.*.bhdr.channel_number});
                        continue;
                    }

                    status.raw_to_error(welcomeResponse.?.*.bhdr.status) catch |err| {
                        log.info("On server thread - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        return;
                    };
                }
                break;
            }

            while (true) {
                var recvMsg: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                    log.info("On server thread - waitReceive error {s}", .{@errorName(err)});
                    return;
                };
                defer self.ampe.put(&recvMsg);

                if (recvMsg == null) {
                    continue;
                }
                if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .waiter_update) {
                    log.info("On server thread - exit required", .{});
                    return;
                }
                if (recvMsg.?.*.bhdr.status != 0) {
                    if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                        log.info("On server thread - Pool is empy - return message to the pool", .{});
                        continue;
                    }

                    if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .channel_closed) {
                        log.info("On server thread - closed channel {d}", .{recvMsg.?.*.bhdr.channel_number});
                        continue;
                    }

                    status.raw_to_error(recvMsg.?.*.bhdr.status) catch |err| {
                        log.info("On server thread - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        return;
                    };
                }

                assert(recvMsg.?.*.bhdr.proto.role == .request);

                if (recvMsg.?.*.bhdr.proto.mtype == .hello) {
                    self.*.result = .success;
                }
                // Echo
                recvMsg.?.*.bhdr.proto.role = .response;
                recvMsg.?.*.bhdr.proto.origin = .application; // For sure

                _ = self.*.chnls.?.enqueueToPeer(&recvMsg) catch |err| {
                    log.info("On server thread - enqueueToPeer error {s}", .{@errorName(err)});
                    return;
                };
            }

            return;
        }

        pub fn Create(allocator: Allocator, engine: Ampe, cfg: *Configurator) !*Self {
            const result: *Self = allocator.create(Self) catch {
                return AmpeError.AllocationFailed;
            };
            errdefer allocator.destroy(result);

            const srv: Self = .{
                .gpa = allocator,
                .ampe = engine,
                .cfg = cfg.*,
                .chnls = try engine.create(),
                .result = AmpeStatus.unknown_error,
            };

            result.* = srv;

            return result;
        }

        pub fn deinit(self: *Self) void {
            if (self.chnls != null) {
                self.ampe.destroy(self.chnls.?) catch {};
                self.chnls = null;
            }
            return;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.gpa;
            defer allocator.destroy(self);
            self.deinit();
            return;
        }
    };

    var clnt: *TofuClient = try TofuClient.Create(gpa, ampe, cltCfg);
    defer clnt.destroy();

    const clntThread: std.Thread =
        try std.Thread.spawn(.{}, TofuClient.runOnThread, .{clnt});
    defer clntThread.join();

    sleep10MlSec();
    sleep10MlSec();

    var srvr: *TofuServer = try TofuServer.Create(gpa, ampe, srvCfg);
    defer srvr.destroy();

    const srvrThread: std.Thread =
        try std.Thread.spawn(.{}, TofuServer.runOnThread, .{srvr});
    defer srvrThread.join();

    while (true) {
        sleep1MlSec();

        if (clnt.*.result == null) {
            continue;
        }
        if (srvr.*.result == null) {
            continue;
        }
        break;
    }

    var nullMsg: ?*Message = null;

    clnt.*.chnls.?.updateWaiter(&nullMsg) catch {};

    srvr.*.chnls.?.updateWaiter(&nullMsg) catch {};

    return .success;
}

pub fn handleReConnnectOfTcpClientServerST(gpa: Allocator) anyerror!AmpeStatus {
    // Both server and client are on localhost.
    const port = try tofu.FindFreeTcpPort();
    var srvCfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("127.0.0.1", port) };
    var cltCfg: Configurator = .{ .tcp_client = configurator.TCPClientConfigurator.init("127.0.0.1", port) };

    return handleReConnectST(gpa, &srvCfg, &cltCfg);
}

pub fn handleReConnnectOfUdsClientServerST(gpa: Allocator) anyerror!AmpeStatus {
    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    var srvCfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };
    var cltCfg: Configurator = .{ .uds_client = configurator.UDSClientConfigurator.init(filePath) };

    return handleReConnectST(gpa, &srvCfg, &cltCfg);
}

pub fn handleReConnectST(gpa: Allocator, srvCfg: *Configurator, cltCfg: *Configurator) anyerror!AmpeStatus {
    // Same code for TCP and UDS client/server, only configurations differ.
    // Configurations must match (both TCP or both UDS).

    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    // Just for example - let's create two engines :-)

    var engA: *Reactor = try Reactor.Create(gpa, options);
    defer engA.Destroy();
    const ampeA: Ampe = try engA.ampe();

    var engB: *Reactor = try Reactor.Create(gpa, options);
    defer engB.Destroy();
    const ampeB: Ampe = try engB.ampe();

    const TofuServer = struct {
        const Self = @This();
        ampe: Ampe = undefined,
        chnls: ?ChannelGroup = undefined,
        cfg: Configurator = undefined,
        helloBh: BinaryHeader = undefined,
        connected: bool = undefined,

        pub fn create(engine: Ampe, cfg: *Configurator) !*Self {
            const allocator = engine.getAllocator();
            const result: *Self = allocator.create(Self) catch {
                return AmpeError.AllocationFailed;
            };
            errdefer allocator.destroy(result);

            result.* = try Self.init(engine, cfg);
            errdefer result.*.deinit();

            try result.createListener();

            return result;
        }

        pub fn init(engine: Ampe, cfg: *Configurator) !Self {
            return .{
                .ampe = engine,
                .cfg = cfg.*,
                .chnls = try engine.create(),
                .helloBh = .{},
                .connected = false,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.chnls != null) {
                self.ampe.destroy(self.chnls.?) catch {};
                self.chnls = null;
            }
            return;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.ampe.getAllocator();
            defer allocator.destroy(self);
            self.deinit();
            return;
        }

        fn createListener(server: *Self) !void {
            var welcomeRequest: ?*Message = server.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
            defer server.*.ampe.put(&welcomeRequest);

            server.*.cfg.prepareRequest(welcomeRequest.?) catch unreachable;

            var initialBh = server.*.chnls.?.enqueueToPeer(&welcomeRequest) catch unreachable;

            initialBh.dumpMeta("listener send ");

            var welcomeResponse: ?*Message = server.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                log.info("server - waitReceive error {s}", .{@errorName(err)});
                return err;
            };
            defer server.ampe.put(&welcomeResponse);

            welcomeResponse.?.*.bhdr.dumpMeta("listener recv ");

            if (welcomeResponse.?.*.bhdr.status == 0) {
                return;
            }
            status.raw_to_error(welcomeResponse.?.*.bhdr.status) catch |err| {
                log.info("server - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                return err;
            };
        }

        pub fn waitConnect(server: *Self, timeOut: u64) !bool {
            if (server.connected) {
                return true;
            }

            server.connected = try server.waitRequestSendResponse(.hello, timeOut);
            return server.connected;
        }

        pub fn recvByeRequest_sendByeResponse(server: *Self, timeOut: u64) !bool {
            if (!server.connected) {
                return true;
            }

            return server.waitRequestSendResponse(.bye, timeOut);
        }

        fn waitRequestSendResponse(server: *Self, mtype: message.MessageType, timeOut: u64) !bool {
            while (true) {
                var recvMsg: ?*Message = server.*.chnls.?.waitReceive(timeOut) catch |err| {
                    log.info("server - waitReceive error {s}", .{@errorName(err)});
                    return err;
                };
                defer server.ampe.put(&recvMsg);

                if (recvMsg == null) {
                    continue;
                }

                server.helloBh = (recvMsg.?).*.bhdr;

                server.helloBh.dumpMeta("server recv");

                if (recvMsg.?.*.bhdr.status != 0) {
                    if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                        log.info("server - Pool is empy - add messages to the pool", .{});
                        try server.*.addMessagesToPool(2);
                        continue;
                    }

                    status.raw_to_error(recvMsg.?.*.bhdr.status) catch |err| {
                        log.info("server -  - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        return err;
                    };
                }

                assert(recvMsg.?.*.bhdr.proto.role == .request);
                assert(recvMsg.?.*.bhdr.proto.mtype == mtype);

                recvMsg.?.*.bhdr.proto.role = .response;
                recvMsg.?.*.bhdr.proto.origin = .application; // For sure

                _ = server.*.chnls.?.enqueueToPeer(&recvMsg) catch |err| {
                    log.info("server - enqueueToPeer error {s}", .{@errorName(err)});
                    return err;
                };

                return true;
            }
        }

        fn addMessagesToPool(self: *Self, count: u8) !void {
            const allocator: Allocator = self.*.ampe.getAllocator();
            var i: usize = 0;
            while (i < count) : (i += 1) {
                var newMsg: ?*Message = try Message.create(allocator);
                self.*.ampe.put(&newMsg);
            }
            return;
        }
    };

    const TofuClient = struct {
        const Self = @This();
        ampe: Ampe = undefined,
        chnls: ?ChannelGroup = undefined,
        cfg: Configurator = undefined,
        helloBh: BinaryHeader = undefined,
        connected: bool = undefined,

        pub fn create(engine: Ampe, cfg: *Configurator) !*Self {
            const allocator = engine.getAllocator();
            const result: *Self = allocator.create(Self) catch {
                return AmpeError.AllocationFailed;
            };
            errdefer allocator.destroy(result);

            result.* = try Self.init(engine, cfg);
            errdefer result.*.deinit();
            return result;
        }

        pub fn init(engine: Ampe, cfg: *Configurator) !Self {
            return .{
                .ampe = engine,
                .cfg = cfg.*,
                .chnls = try engine.create(),
                .helloBh = .{},
                .connected = false,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.chnls != null) {
                self.ampe.destroy(self.chnls.?) catch {};
                self.chnls = null;
            }
            return;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.ampe.getAllocator();
            defer allocator.destroy(self);
            self.deinit();
            return;
        }

        pub fn sendHelloRequestRequest_recvHelloResponse(client: *Self, tries: usize, sleepBetweenNS: u64, srv: ?*TofuServer) !void {
            if (client.connected) {
                return;
            }

            var buildAndSendHelloRequest: bool = true;

            for (0..tries) |i| {
                while (true) {
                    if (buildAndSendHelloRequest) {
                        // Prepare and send HelloRequest
                        var helloRequest: ?*Message = client.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
                        defer client.*.ampe.put(&helloRequest);
                        client.*.cfg.prepareRequest(helloRequest.?) catch unreachable;
                        client.*.helloBh = client.*.chnls.?.enqueueToPeer(&helloRequest) catch unreachable;

                        assert(client.*.helloBh.channel_number != 0);

                        client.*.helloBh.dumpMeta("client send ");

                        buildAndSendHelloRequest = false;
                    }

                    if (srv != null) {
                        _ = try srv.?.waitConnect(sleepBetweenNS);
                    }

                    // Wait result:
                    // - failed connection (HelloResponse.status == connect_failed)
                    // - connected (HelloResponse.status == 0)
                    // - null - timeout
                    // - ..........................
                    var recvMsg: ?*Message = client.*.chnls.?.waitReceive(tofu.waitReceive_SEC_TIMEOUT) catch |err| {
                        log.info("Client - waitReceive error {s}", .{@errorName(err)});
                        return err;
                    };
                    defer client.ampe.put(&recvMsg);

                    if (recvMsg == null) { // timeout
                        break;
                    }

                    recvMsg.?.*.bhdr.dumpMeta("client recv");

                    // Ignore messages for already closed channel
                    if ((status.raw_to_status(recvMsg.?.*.bhdr.status) == .channel_closed) and (recvMsg.?.*.bhdr.channel_number != client.helloBh.channel_number)) {
                        continue;
                    }

                    switch (status.raw_to_status(recvMsg.?.*.bhdr.status)) {
                        .success => {
                            // Client connected
                            client.connected = true;
                            return;
                        },
                        .pool_empty => {
                            log.info("Client - empty pool", .{});
                            try client.*.addMessagesToPool(3);
                            continue;
                        },
                        .connect_failed,
                        .communication_failed,
                        .peer_disconnected,
                        .send_failed,
                        .recv_failed,
                        => {
                            break; // connect should be repeated
                        },

                        .invalid_address => {
                            return AmpeError.InvalidAddress;
                        },

                        .uds_path_not_found => { // Up to developer, possibly uds listener was not started
                            break; // connect should be repeated - my decision for the test
                            // or return AmpeError.UdsPathNotFound
                        },

                        .channel_closed => { // ????
                            buildAndSendHelloRequest = true;
                            continue;
                        },
                        else => {
                            status.raw_to_error(recvMsg.?.*.bhdr.status) catch |err| {
                                // For other errors - propagate up
                                log.info("Client - recived message with non expected error {s}", .{@errorName(err)});
                                return err;
                            };
                        },
                    }
                }
                if (i != tries) {
                    std.time.sleep(sleepBetweenNS);
                }
            }

            return;
        }

        pub fn sendByeRequest(client: *Self) !void {
            std.testing.log_level = .debug;

            if (!client.connected) {
                return;
            }

            // Prepare and send ByeRequest
            var byeRequest: ?*Message = client.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
            defer client.*.ampe.put(&byeRequest);

            // Don't forget set the same channel # returned after send HelloRequest
            byeRequest.?.*.bhdr.channel_number = client.*.helloBh.channel_number;
            byeRequest.?.*.bhdr.proto.mtype = .bye;
            byeRequest.?.*.bhdr.proto.role = .request;
            byeRequest.?.*.bhdr.proto.origin = .application;

            _ = byeRequest.?.check_and_prepare() catch |err| {
                byeRequest.?.*.bhdr.dumpMeta("wrong message ");
                return err;
            };

            var brBhdr: BinaryHeader = client.*.chnls.?.enqueueToPeer(&byeRequest) catch |err| {
                byeRequest.?.*.bhdr.dumpMeta("wrong message was send to peer");
                return err;
            };

            brBhdr.dumpMeta("client send ");

            // client.*.helloBh = client.*.chnls.?.enqueueToPeer(&byeRequest) catch unreachable;
            // client.*.helloBh.dumpMeta("client send ");

            return;
        }

        pub fn recvByeResponse(client: *Self, timeOut: u64) !bool {
            if (!client.connected) {
                return true;
            }

            return client.recvResponse(.bye, timeOut);
        }

        fn recvResponse(client: *Self, mtype: message.MessageType, timeOut: u64) !bool {
            while (true) {
                var recvMsg: ?*Message = client.*.chnls.?.waitReceive(timeOut) catch |err| {
                    log.info("client - waitReceive error {s}", .{@errorName(err)});
                    return err;
                };
                defer client.ampe.put(&recvMsg);

                if (recvMsg == null) {
                    continue;
                }

                if (client.helloBh.channel_number != recvMsg.?.*.bhdr.channel_number) {
                    client.helloBh.dumpMeta("expected recv");
                    recvMsg.?.*.bhdr.dumpMeta("actual recv");
                } else {
                    recvMsg.?.*.bhdr.dumpMeta("client recv");
                }

                assert(client.helloBh.channel_number == recvMsg.?.*.bhdr.channel_number);

                if (recvMsg.?.*.bhdr.status != 0) {
                    if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                        log.info("client - Pool is empy - return message to the pool", .{});
                        continue;
                    }

                    status.raw_to_error(recvMsg.?.*.bhdr.status) catch |err| {
                        log.info("client -  - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        return err;
                    };
                }

                assert(recvMsg.?.*.bhdr.proto.role == .response);
                assert(recvMsg.?.*.bhdr.proto.mtype == mtype);

                return true;
            }
        }

        fn addMessagesToPool(self: *Self, count: u8) !void {
            const allocator: Allocator = self.*.ampe.getAllocator();
            var i: usize = 0;
            while (i < count) : (i += 1) {
                var newMsg: ?*Message = try Message.create(allocator);
                self.*.ampe.put(&newMsg);
            }
            return;
        }
    };

    var tCl: *TofuClient = try TofuClient.create(ampeA, cltCfg);
    defer tCl.destroy();

    try tCl.sendHelloRequestRequest_recvHelloResponse(1000, std.time.ns_per_ms * 1, null);

    var tSr: *TofuServer = try TofuServer.create(ampeB, srvCfg);
    defer tSr.destroy();

    try tCl.sendHelloRequestRequest_recvHelloResponse(1, std.time.ns_per_ms * 10, tSr);

    try tCl.sendByeRequest();

    // wait ByeRequest on server and ByeResponse on client
    if ((try tSr.recvByeRequest_sendByeResponse(std.time.ns_per_ms * 100)) and (try tCl.recvByeResponse(std.time.ns_per_ms * 100))) {
        return AmpeStatus.success;
    }

    return AmpeStatus.communication_failed;
}

pub fn handleReConnnectOfUdsClientServerSTViaConnector(gpa: Allocator) anyerror!AmpeStatus {
    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    var srvCfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };
    var cltCfg: Configurator = .{ .uds_client = configurator.UDSClientConfigurator.init(filePath) };

    return handleReConnectViaConnector(gpa, &srvCfg, &cltCfg);
}

pub fn handleReConnectViaConnector(gpa: Allocator, srvCfg: *Configurator, cltCfg: *Configurator) anyerror!AmpeStatus {
    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var rtr: *Reactor = try Reactor.Create(gpa, options);
    defer rtr.Destroy();
    const ampe: Ampe = try rtr.ampe();
    defer tofu.DestroyChannels(rtr, ampe);

    // Helper object - for re-connect logic
    const ClientConnector = struct {
        const Self = @This();
        ampe: Ampe = undefined,
        chnls: ?ChannelGroup = undefined,
        helloRequest: ?*Message = undefined,
        helloBh: ?BinaryHeader = undefined,
        connected: bool = undefined,

        pub fn init(engine: Ampe, chnls: ChannelGroup, cfg: *Configurator) !Self {
            var helloRequest: ?*Message = try engine.get(tofu.AllocationStrategy.always);
            errdefer engine.put(&helloRequest);

            try cfg.*.prepareRequest(helloRequest.?);

            return .{
                .ampe = engine,
                .chnls = chnls,
                .helloBh = null,
                .helloRequest = helloRequest,
                .connected = false,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.*.helloRequest != null) {
                self.*.ampe.put(&self.*.helloRequest);
            }
            return;
        }

        pub fn tryToConnect(cc: *Self, recvd: *?*Message) !bool {
            defer cc.*.ampe.put(recvd);

            if (cc.*.connected) {
                return true;
            }

            if ((cc.helloBh == null) and (recvd.* != null)) {
                return error.ReceivedMessageForAnotherChannel;
            }

            if (cc.helloBh == null) { // Send helloRequest
                var helloClone: ?*Message = try cc.*.helloRequest.?.clone();
                cc.*.helloBh = cc.*.chnls.?.enqueueToPeer(&helloClone) catch |err| {
                    cc.*.ampe.put(&helloClone);
                    return err;
                };
            }

            if (recvd.* == null) {
                return false;
            }

            if ((cc.helloBh.?.channel_number != (*recvd.*.?).bhdr.channel_number)) {
                if (status.raw_to_status((*recvd.*.?).bhdr.status) == .channel_closed) {
                    return false;
                }
                return error.ReceivedMessageForAnotherChannel;
            }

            if ((*recvd.*.?).bhdr.proto.mtype != .hello) {
                // HelloResponse expected
                // Possibly this message was send ahead of success
                // of connect => return to pool;
                return false;
            }

            switch (status.raw_to_status((*recvd.*.?).bhdr.status)) {
                .invalid_address => return AmpeError.InvalidAddress,
                .uds_path_not_found => return AmpeError.UDSPathNotFound,
                .recv_failed, .send_failed => {
                    cc.*.helloBh = null;
                    return false;
                },

                .success => {
                    // Client connected
                    cc.*.connected = true;
                    return true;
                },
                .pool_empty => {
                    return false; // defer above will return received signal message to the pool
                },
                .connect_failed, .channel_closed => {
                    cc.*.helloBh = null;
                    return false; // connect should be repeated
                },

                else => {},
            }

            status.raw_to_error((*recvd.*.?).bhdr.status) catch |err| {
                // For other errors - propagate up
                log.info("Client - recived message with non expected error {s}", .{@errorName(err)});
                return err;
            };

            // For compiler silence
            cc.*.connected = true;
            return true;
        }
    };

    const TofuClient = struct {
        const Self = @This();
        ampe: Ampe = undefined,
        chnls: ?ChannelGroup = null,
        cfg: Configurator = undefined,
        cc: ?ClientConnector = null,
        helloBh: BinaryHeader = undefined,
        connected: bool = undefined,

        pub fn create(engine: Ampe, cfg: *Configurator) !*Self {
            const allocator = engine.getAllocator();
            const result: *Self = allocator.create(Self) catch {
                return AmpeError.AllocationFailed;
            };
            result.* = .{};

            errdefer allocator.destroy(result);

            result.* = try Self.init(engine, cfg);
            errdefer result.*.deinit();
            return result;
        }

        pub fn init(engine: Ampe, cfg: *Configurator) !Self {
            const chnls: ChannelGroup = try engine.create();
            errdefer tofu.DestroyChannels(engine, chnls);
            const cc: ClientConnector = try ClientConnector.init(engine, chnls, cfg);
            errdefer cc.deinit();

            return .{
                .ampe = engine,
                .cfg = cfg.*,
                .chnls = chnls,
                .cc = cc,
                .helloBh = .{},
                .connected = false,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.*.cc != null) {
                self.*.cc.?.deinit();
                self.*.cc = null;
            }

            if (self.*.chnls != null) {
                self.*.ampe.destroy(self.chnls.?) catch {};
                self.*.chnls = null;
            }
            return;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.ampe.getAllocator();
            defer allocator.destroy(self);
            self.deinit();
            return;
        }

        pub fn sendHelloRequestRequest_recvHelloResponse(client: *Self, tries: usize, sleepBetweenNS: u64, srv: ?*TofuEchoServer) !void {
            if (client.*.connected) {
                return;
            }

            var receivedMsg: ?*Message = null;

            for (0..tries) |i| {
                while (true) {
                    client.*.connected = try client.*.cc.?.tryToConnect(&receivedMsg);
                    if (client.*.connected) {
                        return;
                    }

                    if (srv != null) {
                        _ = try srv.?.waitConnect(sleepBetweenNS);
                    }

                    receivedMsg = client.*.chnls.?.waitReceive(tofu.waitReceive_SEC_TIMEOUT) catch |err| {
                        log.info("Client - waitReceive error {s}", .{@errorName(err)});
                        return err;
                    };
                    defer client.ampe.put(&receivedMsg);

                    if (receivedMsg == null) { // timeout
                        break;
                    }
                }

                if (i != tries) {
                    std.time.sleep(sleepBetweenNS);
                }
            }

            return;
        }

        pub fn sendByeRequest(client: *Self) !void {
            if (!client.connected) {
                return;
            }

            // Prepare and send ByeRequest
            var byeRequest: ?*Message = client.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
            defer client.*.ampe.put(&byeRequest);

            // Don't forget set the same channel # returned after send HelloRequest
            byeRequest.?.*.bhdr.channel_number = client.*.helloBh.channel_number;
            byeRequest.?.*.bhdr.proto.mtype = .bye;
            byeRequest.?.*.bhdr.proto.role = .request;
            byeRequest.?.*.bhdr.proto.origin = .application;

            client.*.helloBh = client.*.chnls.?.enqueueToPeer(&byeRequest) catch unreachable;

            client.*.helloBh.dumpMeta("client send ");

            return;
        }

        pub fn recvByeResponse(client: *Self, timeOut: u64) !bool {
            if (!client.connected) {
                return true;
            }

            return client.recvResponse(.bye, timeOut);
        }

        fn recvResponse(client: *Self, mtype: message.MessageType, timeOut: u64) !bool {
            while (true) {
                var recvMsg: ?*Message = client.*.chnls.?.waitReceive(timeOut) catch |err| {
                    log.info("client - waitReceive error {s}", .{@errorName(err)});
                    return err;
                };
                defer client.ampe.put(&recvMsg);

                if (recvMsg == null) {
                    continue;
                }

                recvMsg.?.*.bhdr.dumpMeta("client recv");

                assert(client.helloBh.channel_number == recvMsg.?.*.bhdr.channel_number);

                if (recvMsg.?.*.bhdr.status != 0) {
                    if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                        log.info("client - Pool is empy - return message to the pool", .{});
                        continue;
                    }

                    status.raw_to_error(recvMsg.?.*.bhdr.status) catch |err| {
                        log.info("client -  - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        return err;
                    };
                }

                assert(recvMsg.?.*.bhdr.proto.role == .response);
                assert(recvMsg.?.*.bhdr.proto.mtype == mtype);

                return true;
            }
        }
    };

    var tCl: *TofuClient = try TofuClient.create(ampe, cltCfg);
    defer tCl.destroy();

    try tCl.sendHelloRequestRequest_recvHelloResponse(1, std.time.ns_per_ms * 10, null);

    var tSr: *TofuEchoServer = try TofuEchoServer.create(ampe, srvCfg);
    defer tSr.destroy();

    try tCl.sendHelloRequestRequest_recvHelloResponse(1, std.time.ns_per_ms * 10, tSr);

    try tCl.sendByeRequest();

    // wait ByeRequest on server and ByeResponse on client
    if ((try tSr.recvByeRequest_sendByeResponse(std.time.ns_per_ms * 100)) and (try tCl.recvByeResponse(std.time.ns_per_ms * 100))) {
        return AmpeStatus.success;
    }

    return AmpeStatus.communication_failed;
}

pub const TofuEchoServer = struct {
    const Self = @This();
    ampe: Ampe = undefined,
    chnls: ?ChannelGroup = undefined,
    cfg: Configurator = undefined,
    listenerBh: BinaryHeader = undefined,
    helloBh: BinaryHeader = undefined,
    connected: bool = undefined,

    pub fn create(engine: Ampe, cfg: *Configurator) !*Self {
        const allocator = engine.getAllocator();
        const result: *Self = allocator.create(Self) catch {
            return AmpeError.AllocationFailed;
        };
        errdefer allocator.destroy(result);

        result.* = try Self.init(engine, cfg);
        errdefer result.*.deinit();

        try result.createListener();

        return result;
    }

    pub fn init(engine: Ampe, cfg: *Configurator) !Self {
        return .{
            .ampe = engine,
            .cfg = cfg.*,
            .chnls = try engine.create(),
            .listenerBh = .{},
            .helloBh = .{},
            .connected = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.chnls != null) {
            self.ampe.destroy(self.chnls.?) catch {};
            self.chnls = null;
        }
        return;
    }

    pub fn destroy(self: *Self) void {
        const allocator = self.ampe.getAllocator();
        defer allocator.destroy(self);
        self.deinit();
        return;
    }

    fn createListener(server: *Self) !void {
        var welcomeRequest: ?*Message = server.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
        defer server.*.ampe.put(&welcomeRequest);

        server.*.cfg.prepareRequest(welcomeRequest.?) catch unreachable;

        var initialBh = server.*.chnls.?.enqueueToPeer(&welcomeRequest) catch unreachable;

        initialBh.dumpMeta("listener send ");

        var welcomeResponse: ?*Message = server.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
            log.info("server - waitReceive error {s}", .{@errorName(err)});
            return err;
        };
        defer server.ampe.put(&welcomeResponse);

        (*welcomeResponse.?).bhdr.dumpMeta("listener recv ");

        if ((*welcomeResponse.?).bhdr.status == 0) {
            server.*.listenerBh = initialBh;
            return;
        }
        status.raw_to_error((*welcomeResponse.?).bhdr.status) catch |err| {
            log.info("server - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
            return err;
        };
    }

    pub fn waitConnect(server: *Self, timeOut: u64) !bool {
        if (server.connected) {
            return true;
        }

        server.connected = try server.waitRequestSendResponse(.hello, timeOut);
        return server.connected;
    }

    pub fn recvByeRequest_sendByeResponse(server: *Self, timeOut: u64) !bool {
        if (!server.connected) {
            return true;
        }

        return server.waitRequestSendResponse(.bye, timeOut);
    }

    fn waitRequestSendResponse(server: *Self, mtype: message.MessageType, timeOut: u64) !bool {
        while (true) {
            var recvMsg: ?*Message = server.*.chnls.?.waitReceive(timeOut) catch |err| {
                log.info("server - waitReceive error {s}", .{@errorName(err)});
                return err;
            };
            defer server.ampe.put(&recvMsg);

            if (recvMsg == null) {
                continue;
            }

            server.helloBh = recvMsg.?.*.bhdr;

            server.helloBh.dumpMeta("server recv");

            if (recvMsg.?.*.bhdr.status != 0) {
                if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                    log.info("server - Pool is empy - return message to the pool", .{});
                    continue;
                }

                status.raw_to_error(recvMsg.?.*.bhdr.status) catch |err| {
                    log.info("server -  - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                    return err;
                };
            }

            assert(recvMsg.?.*.bhdr.proto.role == .request);
            assert(recvMsg.?.*.bhdr.proto.mtype == mtype);

            recvMsg.?.*.bhdr.proto.role = .response;
            recvMsg.?.*.bhdr.proto.origin = .application; // For sure

            _ = server.*.chnls.?.enqueueToPeer(&recvMsg) catch |err| {
                log.info("server - enqueueToPeer error {s}", .{@errorName(err)});
                return err;
            };

            return true;
        }
    }
};

pub inline fn sleepSec() void {
    std.time.sleep(1_000_000_000);
}

pub inline fn sleep1MlSec() void {
    std.time.sleep(1_000_000);
}

pub inline fn sleep10MlSec() void {
    std.time.sleep(1_000_000_0);
}

pub fn handleEchoClientServer(allocator: Allocator) !AmpeStatus {

    // Prepare configurators: TCP client/server, UDS client/server
    const tcpPort: u16 = try tofu.FindFreeTcpPort();

    var tup: tofu.TempUdsPath = .{};
    const udsPath: []u8 = try tup.buildPath(allocator);

    var mhCnfg = [_]Configurator{
        .{ .tcp_server = configurator.TCPServerConfigurator.init("127.0.0.1", tcpPort) },
        .{ .uds_server = configurator.UDSServerConfigurator.init(udsPath) },
    };

    var clntCnfgs = [_]Configurator{
        .{ .tcp_client = configurator.TCPClientConfigurator.init("127.0.0.1", tcpPort) },
        .{ .uds_client = configurator.UDSClientConfigurator.init(udsPath) },
    };

    var echoClSrv: services.EchoClientServer = try .init(allocator, mhCnfg[0..]);

    return echoClSrv.run(clntCnfgs[0..]);
}
