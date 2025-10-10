const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const assert = std.debug.assert;

pub const tofu = @import("tofu");
pub const Engine = tofu.Engine;
pub const Ampe = tofu.Ampe;
pub const Channels = tofu.Channels;
pub const Options = tofu.Options;
pub const DefaultOptions = tofu.DefaultOptions;
pub const configurator = tofu.configurator;
pub const Configurator = configurator.Configurator;
pub const TCPClientConfigurator = configurator.TCPClientConfigurator;
pub const status = tofu.status;
pub const message = tofu.message;
pub const BinaryHeader = message.BinaryHeader;
pub const Message = message.Message;

pub fn createDestroyMain(gpa: Allocator) !void {
    var eng = try Engine.Create(gpa, DefaultOptions);
    defer eng.Destroy();
}

pub fn createDestroyEngine(gpa: Allocator) !void {
    var eng = try Engine.Create(gpa, DefaultOptions);
    defer eng.Destroy();

    const ampe = try eng.ampe();

    // No need to destroy ampe. It is an interface provided by Engine.
    _ = ampe;
}

pub fn createDestroyMessageChannelGroup(gpa: Allocator) !void {
    var eng = try Engine.Create(gpa, DefaultOptions);
    defer eng.Destroy();

    const ampe = try eng.ampe();

    const chnls = try ampe.create();

    // Destroy Channels using ampe.
    try ampe.destroy(chnls);
}

pub fn getMsgsFromSmallestPool(gpa: Allocator) !void {
    // If options have invalid values (0 or maxPoolMsgs < initialPoolMsgs),
    // DefaultOptions will be used.
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg1 = try ampe.get(tofu.AllocationStrategy.poolOnly);

    // If msg1 is not null, return it to the pool.
    // Pool is cleaned during eng.Destroy().
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

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // Ignore errors for this example.
    };

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // Message from the pool is not ready for sending.
    // It needs setup first.
    // It will be returned to the pool by defer.
    _ = try chnls.sendToPeer(&msg);

    return;
}

pub fn handleMessageWithWrongChannelNumber(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // Ignore errors for this example.
    };

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // Only MessageType.hello and MessageType.welcome can use channel number 0.
    // Other messages need a valid, non-zero channel number.

    // Invalid Bye Request.
    var bhdr = &msg.?.bhdr;
    bhdr.proto.mtype = .bye;
    bhdr.proto.role = .request;

    _ = try chnls.sendToPeer(&msg);

    return;
}

pub fn handleHelloWithoutConfiguration(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // Ignore errors for this example.
    };

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // A valid channel number is not enough.
    // MessageType.hello needs the peer (server) address.
    // MessageType.welcome needs the server address for listening.

    var bhdr = &msg.?.bhdr;

    // Hello Request without server address (configuration).
    bhdr.proto.mtype = .hello;
    bhdr.proto.role = .request;

    _ = try chnls.sendToPeer(&msg);

    return;
}

pub fn handleHelloWithWrongAddress(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 1, // Example value.
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // MessageType.hello needs a valid, resolvable peer (server) address.
    // For IP addresses, it must be valid.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server address is "tofu.server.zig", port 3298.
    // Use helpers to create the configuration for a hello request.

    var cnfg: Configurator = .{ .tcp_client = TCPClientConfigurator.init("tofu.server.zig", 3298) };

    // Adds configuration to the message's TextHeaders.
    try cnfg.prepareRequest(msg.?);

    _ = try chnls.sendToPeer(&msg);

    var recvMsg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    const st = recvMsg.?.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleHelloToNonListeningServer(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 64, // Example value.
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // MessageType.hello needs a valid, resolvable peer (server) address.
    // For IP addresses, it must be valid.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server address is "127.0.0.1", port 32987.
    // Use helpers to create the configuration for a hello request.

    var cnfg: Configurator = .{ .tcp_client = TCPClientConfigurator.init("127.0.0.1", 32987) };

    // Adds configuration to the message's TextHeaders.
    try cnfg.prepareRequest(msg.?);

    // Store information for further processing.
    const bhdr = try chnls.sendToPeer(&msg);
    _ = bhdr;

    var recvMsg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    const st = recvMsg.?.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleWelcomeWithWrongAddress(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // Example value.
        .maxPoolMsgs = 16, // Example value.
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // MessageType.welcome needs the IP address and port of the listening server.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server has an invalid IP address "192.128.4.5", port 3298.
    // Use helpers to create the configuration for a welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("192.128.4.5", 3298) };

    // Adds configuration to the message's TextHeaders.
    try cnfg.prepareRequest(msg.?);

    _ = try chnls.sendToPeer(&msg);

    var recvMsg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    const st = recvMsg.?.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleStartOfTcpServerAkaListener(gpa: Allocator) !status.AmpeStatus {
    // WelcomeRequest for a TCP server needs the IP address and port of the listening server.

    // Configuration is a TextHeader added to the message's TextHeaders.
    // Tofu provides helper structs for creating configurations.
    // Example: TCP server listens on all interfaces (IPv4 "0.0.0.0"), port 32984.
    // Use helpers to create the configuration for a welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("0.0.0.0", 32984) };

    return handleStartOfListener(gpa, &cnfg);
}

pub fn handleStartOfUdsServerAkaListener(gpa: Allocator) !status.AmpeStatus {
    // UDS (Unix Domain Socket) uses a file path for communication on the same machine,
    // unlike network sockets that use IP addresses and ports.

    // WelcomeRequest for a UDS server needs a file path.
    // Tofu provides a helper to create a temporary file path for testing.

    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    // Create configurator for UDS server.
    var cnfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };

    // Use the same code as for TCP server.
    return handleStartOfListener(gpa, &cnfg);
}

pub fn handleStartOfListener(gpa: Allocator, cnfg: *Configurator) !status.AmpeStatus {
    // Same code for TCP and UDS servers, only configuration differs.

    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var eng: *Engine = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe: Ampe = try eng.ampe();

    const chnls: Channels = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // Adds configuration to the message's TextHeaders.
    try cnfg.prepareRequest(msg.?);

    const corrInfo: BinaryHeader = try chnls.sendToPeer(&msg);
    log.debug(">><< Listen will start on channel {d} ", .{corrInfo.channel_number});

    var recvMsg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    // Return message to the pool.
    defer ampe.put(&recvMsg);

    const st = recvMsg.?.bhdr.status;

    // Received message should have the same channel number.
    assert(corrInfo.channel_number == recvMsg.?.bhdr.channel_number);

    // Since we sent a WelcomeRequest, the received message should be a WelcomeResponse
    // with the listen status (success or failure).
    // A WelcomeSignal would return a Signal with an error status for failed listen.
    assert(recvMsg.?.bhdr.proto.mtype == .welcome);
    assert(recvMsg.?.bhdr.proto.role == .response);

    // Channel is not closed explicitly.
    // It closes during Channels destruction (see defer above).

    // Convert status byte to AmpeStatus enum for convenience.
    return status.raw_to_status(st);
}

pub fn handleConnnectOfTcpClientServer(gpa: Allocator) anyerror!status.AmpeStatus {
    // Both server and client are on localhost.
    var srvCfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("127.0.0.1", 32984) };
    var cltCfg: Configurator = .{ .tcp_client = configurator.TCPClientConfigurator.init("127.0.0.1", 32984) };

    return handleConnect(gpa, &srvCfg, &cltCfg);
}

pub fn handleConnnectOfUdsClientServer(gpa: Allocator) anyerror!status.AmpeStatus {
    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    var srvCfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };
    var cltCfg: Configurator = .{ .uds_client = configurator.UDSClientConfigurator.init(filePath) };

    return handleConnect(gpa, &srvCfg, &cltCfg);
}

pub fn handleConnect(gpa: Allocator, srvCfg: *Configurator, cltCfg: *Configurator) anyerror!status.AmpeStatus {
    // Same code for TCP and UDS client/server, only configurations differ.
    // Configurations must match (both TCP or both UDS).

    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var eng: *Engine = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe: Ampe = try eng.ampe();

    // For simplicity, use the same Channels for client and server.
    // In production, you can use separate Channels for each.

    const chnls: Channels = try ampe.create();

    // Channel closes during Channels destruction.
    defer destroyChannels(ampe, chnls);

    var welcomeRequest: ?*Message = try ampe.get(tofu.AllocationStrategy.poolOnly);

    // If pool is empty, poolOnly strategy returns null.
    if (welcomeRequest == null) {
        // Create a message directly using the same allocator as Engine.Create.
        welcomeRequest = Message.create(gpa) catch unreachable;
    }

    // After sending, welcomeRequest is set to null.
    // Safe to put null message in the pool.
    // If sending fails, return message to the pool.
    defer ampe.put(&welcomeRequest);

    // Add configuration to the message's TextHeaders.
    try srvCfg.prepareRequest(welcomeRequest.?);

    const srvCorrInfo: BinaryHeader = try chnls.sendToPeer(&welcomeRequest);
    log.debug(">><< Listen will start on channel {d} ", .{srvCorrInfo.channel_number});

    var welcomeResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    // Return message to the pool.
    defer ampe.put(&welcomeResp);

    var st: u8 = welcomeResp.?.bhdr.status;

    // Convert u8 status to AmpeError.
    status.raw_to_error(st) catch |err| {
        log.debug(">><< welcomeResp error {s} ", .{@errorName(err)});
    };
    assert(st == 0);

    // Received message should have the same channel number.
    assert(srvCorrInfo.channel_number == welcomeResp.?.bhdr.channel_number);

    // Received message should have the same message ID.
    // If not set before sending, tofu assigns a sequential number.
    assert(srvCorrInfo.message_id == welcomeResp.?.bhdr.message_id);

    // Since we sent a WelcomeRequest, the received message should be a WelcomeResponse
    // with listen status (success or failure).
    // A WelcomeSignal would return a Signal with an error status for failed listen.
    assert(welcomeResp.?.bhdr.proto.mtype == .welcome);
    assert(welcomeResp.?.bhdr.proto.role == .response);

    // Listener is started before connect for simplicity.
    // In production, check connect status and retry if needed.
    // Tofu does not support automatic reconnection.

    // To connect, repeat similar steps as for the listener.
    var helloRequest: ?*Message = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&helloRequest);

    // Add configuration to the message's TextHeaders.
    try cltCfg.prepareRequest(helloRequest.?);

    const cltCorrInfo: BinaryHeader = try chnls.sendToPeer(&helloRequest);
    log.debug(">><< Connect will start on channel {d} ", .{cltCorrInfo.channel_number});

    // Client and server channels must be different.
    assert(cltCorrInfo.channel_number != srvCorrInfo.channel_number);

    // Since Channels handles both client and server,
    // we receive a HelloRequest from the client side.
    // A successful HelloRequest involves:
    // - Connecting to the server.
    // - Sending the HelloRequest message.
    // Network/socket operations run on a dedicated thread.
    // sendToPeer and waitReceive work with internal message queues.

    var helloRequestOnServerSide: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&helloRequestOnServerSide);

    st = helloRequestOnServerSide.?.bhdr.status;
    const chN: message.ChannelNumber = helloRequestOnServerSide.?.bhdr.channel_number;
    status.raw_to_error(st) catch |err| {
        log.debug(">><< helloRequestOnServerSide channel {d} error {s} ", .{ chN, @errorName(err) });
    };
    assert(st == 0);

    // Store info about the connected client.
    const connectedClientInfo: BinaryHeader = helloRequestOnServerSide.?.bhdr;
    log.debug(">><< Channel of new connected client on the server side {d} ", .{connectedClientInfo.channel_number});

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
    helloRequestOnServerSide.?.bhdr.proto.role = .response;
    _ = try chnls.sendToPeer(&helloRequestOnServerSide);

    // On the client side:
    var helloResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

    // Return message to the pool.
    defer ampe.put(&helloResp);

    st = helloResp.?.bhdr.status;

    // Received message should have the same channel number and message ID.
    assert(cltCorrInfo.channel_number == helloResp.?.bhdr.channel_number);
    assert(cltCorrInfo.message_id == helloResp.?.bhdr.message_id);

    // Since we sent a HelloRequest, the received message should be a HelloResponse
    // - From engine with error status if failed.
    // - From server if connect and HelloRequest succeeded.
    // A HelloSignal would return a Signal with an error status for failed connect.
    assert(welcomeResp.?.bhdr.proto.mtype == .welcome);
    assert(welcomeResp.?.bhdr.proto.role == .response);

    // Close all three channels in 'force' mode using ByeSignal with oob = on.
    var closeListener: ?*Message = try ampe.get(tofu.AllocationStrategy.always);

    // Prepare ByeSignal for the listener channel.
    closeListener.?.bhdr.proto.mtype = .bye;
    closeListener.?.bhdr.proto.role = .signal;
    closeListener.?.bhdr.proto.oob = .on;

    // Set channel number to close this channel.
    closeListener.?.bhdr.channel_number = srvCorrInfo.channel_number;

    _ = try chnls.sendToPeer(&closeListener);

    var closeListenerResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&closeListenerResp);

    assert(closeListenerResp.?.bhdr.status == status.status_to_raw(status.AmpeStatus.channel_closed));

    // Close one of the client channels.
    var closeClient: ?*Message = try ampe.get(tofu.AllocationStrategy.always);

    // Prepare ByeSignal for the client channel.
    closeClient.?.bhdr.proto.mtype = .bye;
    closeClient.?.bhdr.proto.role = .signal;
    closeClient.?.bhdr.proto.oob = .on;

    // Set channel number to close this channel.
    closeClient.?.bhdr.channel_number = cltCorrInfo.channel_number; // Client channel on client side.

    _ = try chnls.sendToPeer(&closeClient);

    // Expect two messages with status, as closing one socket
    // also closes the corresponding server-side socket.
    for (0..2) |_| {
        var closeClientResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
        defer ampe.put(&closeClientResp);
        assert(closeClientResp.?.bhdr.status == status.status_to_raw(status.AmpeStatus.channel_closed));
    }

    // Tofu programming mainly involves setting message data.
    // Only three communication APIs exist.
    // Two are used here:
    // - sendToPeer
    // - waitReceive

    // Convert status byte to AmpeStatus enum for convenience.
    return status.raw_to_status(st);
}

pub fn handleUpdateWaiter(gpa: Allocator) anyerror!status.AmpeStatus {
    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var eng: *Engine = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe: Ampe = try eng.ampe();
    const chnls: Channels = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var attention: ?*Message = try chnls.waitReceive(100);
    defer ampe.put(&attention);

    // No message expected.
    assert(attention == null);

    // Send attention signal to itself.
    try chnls.updateWaiter(&attention);

    attention = try chnls.waitReceive(100);

    assert(attention.?.bhdr.message_id == 0);
    assert(attention.?.bhdr.channel_number == 0);
    assert(attention.?.bhdr.proto.origin == .engine);
    assert(attention.?.bhdr.proto.role == .signal);
    assert(status.raw_to_status(attention.?.bhdr.status) == .waiter_update);

    // Create update message from existing signal.
    attention.?.bhdr.proto.role = .request;
    attention.?.bhdr.status = 0;
    attention.?.bhdr.message_id = 1;

    try chnls.updateWaiter(&attention);

    attention = try chnls.waitReceive(100);

    assert(attention.?.bhdr.message_id == 1);
    assert(attention.?.bhdr.channel_number == 0);
    assert(attention.?.bhdr.proto.origin == .application);
    assert(attention.?.bhdr.proto.role == .request);
    assert(status.raw_to_status(attention.?.bhdr.status) == .waiter_update);

    return status.raw_to_status(attention.?.bhdr.status);
}

pub fn handleReConnnectOfTcpClientServerMT(gpa: Allocator) anyerror!status.AmpeStatus {
    // Both server and client are on localhost.
    var srvCfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("127.0.0.1", 32984) };
    var cltCfg: Configurator = .{ .tcp_client = configurator.TCPClientConfigurator.init("127.0.0.1", 32984) };

    return handleReConnectMT(gpa, &srvCfg, &cltCfg);
}

pub fn handleReConnectMT(gpa: Allocator, srvCfg: *Configurator, cltCfg: *Configurator) anyerror!status.AmpeStatus {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1024, // Example value.
        .maxPoolMsgs = 1024, // Example value.
    };

    var eng: *Engine = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe: Ampe = try eng.ampe();

    const TofuClient = struct {
        const Self = @This();
        gpa: Allocator = undefined,
        ampe: Ampe = undefined,
        chnls: ?tofu.Channels = undefined,
        cfg: Configurator = undefined,
        result: ?status.AmpeStatus = undefined,

        fn runOnThread(self: *Self) void {
            log.debug("---> On client thread", .{});
            defer log.debug("<--- On client thread", .{});

            while (true) {
                var helloRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
                defer self.*.ampe.put(&helloRequest);

                self.*.cfg.prepareRequest(helloRequest.?) catch unreachable;

                const hrbh: message.BinaryHeader = self.*.chnls.?.sendToPeer(&helloRequest) catch unreachable;
                const proto: u8 = @bitCast(hrbh.proto);

                log.info("HelloRequest channel {d} mid {d} proto {b}", .{ hrbh.channel_number, hrbh.message_id, proto });

                var recvMsg: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                    log.info("On client thread - waitReceive error {s}", .{@errorName(err)});
                    return;
                };
                defer self.ampe.put(&recvMsg);

                log.debug("On client thread msg received on channel {d} mid {d}", .{ recvMsg.?.bhdr.channel_number, recvMsg.?.bhdr.message_id });

                const mt: message.MessageType = recvMsg.?.bhdr.proto.mtype;
                const mr: message.MessageRole = recvMsg.?.bhdr.proto.role;
                const org: message.OriginFlag = recvMsg.?.bhdr.proto.origin;
                const st: u8 = recvMsg.?.bhdr.status;

                log.info("On client thread mt {s} mr {s} org {s} st {s}", .{ @tagName(mt), @tagName(mr), @tagName(org), @tagName(status.raw_to_status(st)) });

                if (status.raw_to_status(recvMsg.?.bhdr.status) == .connect_failed) {
                    log.info("On client thread - connection failed - reconnect", .{});
                    continue;
                }

                if (status.raw_to_status(recvMsg.?.bhdr.status) == .pool_empty) {
                    log.info("Pool is empy - return message to the pool", .{});
                    continue;
                }

                if (status.raw_to_status(recvMsg.?.bhdr.status) == .waiter_update) {
                    log.info("On client thread - exit required", .{});
                    return;
                }

                if (recvMsg.?.bhdr.proto.mtype == .hello) {
                    assert(recvMsg.?.bhdr.proto.role == .response);

                    log.info("On client thread - connected to server", .{});
                    self.*.result = .success;

                    log.info("On client thread - disconnect from server", .{});
                    recvMsg.?.bhdr.proto.mtype = .bye;
                    recvMsg.?.bhdr.proto.origin = .application;
                    recvMsg.?.bhdr.proto.role = .signal;
                    recvMsg.?.bhdr.proto.oob = .on;
                    _ = self.*.chnls.?.sendToPeer(&recvMsg) catch unreachable;
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

                log.debug("On client thread msg received on channel {d} mid {d}", .{ recvMsg.?.bhdr.channel_number, recvMsg.?.bhdr.message_id });

                if (status.raw_to_status(recvMsg.?.bhdr.status) == .pool_empty) {
                    log.info("Pool is empy - return message to the pool", .{});
                    continue;
                }

                if (status.raw_to_status(recvMsg.?.bhdr.status) == .waiter_update) {
                    log.info("On client thread - exit required", .{});
                    return;
                }
                if (recvMsg.?.bhdr.status != 0) {
                    status.raw_to_error(recvMsg.?.bhdr.status) catch |err| {
                        log.info("On client thread - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        continue;
                    };
                }
            }

            return;
        }

        pub fn Create(allocator: Allocator, engine: Ampe, cfg: *Configurator) status.AmpeError!*Self {
            const result: *Self = allocator.create(Self) catch {
                return status.AmpeError.AllocationFailed;
            };
            errdefer allocator.destroy(result);

            result.* = .{
                .gpa = allocator,
                .ampe = engine,
                .cfg = cfg.*,
                .chnls = try engine.create(),
                .result = status.AmpeStatus.success,
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
        chnls: ?tofu.Channels = undefined,
        cfg: Configurator = undefined,
        result: ?status.AmpeStatus = .unknown_error,

        fn runOnThread(self: *Self) void {
            log.debug("---> On server thread", .{});
            defer log.debug("<--- On server thread", .{});

            while (true) { // Create listener

                var welcomeRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
                defer self.*.ampe.put(&welcomeRequest);

                self.*.cfg.prepareRequest(welcomeRequest.?) catch unreachable;

                _ = self.*.chnls.?.sendToPeer(&welcomeRequest) catch unreachable;

                var welcomeResponse: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                    log.info("On server thread - waitReceive error {s}", .{@errorName(err)});
                    return;
                };
                defer self.ampe.put(&welcomeResponse);

                if (welcomeResponse.?.bhdr.status != 0) {
                    if (status.raw_to_status(welcomeResponse.?.bhdr.status) == .pool_empty) {
                        log.info("Pool is empy - return message to the pool", .{});
                        continue;
                    }
                    if (status.raw_to_status(welcomeResponse.?.bhdr.status) == .channel_closed) {
                        log.info("On server thread - closed channel {d}", .{welcomeResponse.?.bhdr.channel_number});
                        continue;
                    }

                    status.raw_to_error(welcomeResponse.?.bhdr.status) catch |err| {
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
                if (status.raw_to_status(recvMsg.?.bhdr.status) == .waiter_update) {
                    log.info("On server thread - exit required", .{});
                    return;
                }
                if (recvMsg.?.bhdr.status != 0) {
                    if (status.raw_to_status(recvMsg.?.bhdr.status) == .pool_empty) {
                        log.info("On server thread - Pool is empy - return message to the pool", .{});
                        continue;
                    }

                    if (status.raw_to_status(recvMsg.?.bhdr.status) == .channel_closed) {
                        log.info("On server thread - closed channel {d}", .{recvMsg.?.bhdr.channel_number});
                        continue;
                    }

                    status.raw_to_error(recvMsg.?.bhdr.status) catch |err| {
                        log.info("On server thread - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        return;
                    };
                }

                log.debug("On server thread msg received on channel {d} mid {d}", .{ recvMsg.?.bhdr.channel_number, recvMsg.?.bhdr.message_id });

                assert(recvMsg.?.bhdr.proto.role == .request);

                if (recvMsg.?.bhdr.proto.mtype == .hello) {
                    self.*.result = .success;
                }
                // Echo
                recvMsg.?.bhdr.proto.role = .response;
                recvMsg.?.bhdr.proto.origin = .application; // For sure

                const bh: message.BinaryHeader = self.*.chnls.?.sendToPeer(&recvMsg) catch |err| {
                    log.info("On server thread - sendToPeer error {s}", .{@errorName(err)});
                    return;
                };

                log.debug("On server thread send to channel {d} mid {d}", .{ bh.channel_number, bh.message_id });
            }

            return;
        }

        pub fn Create(allocator: Allocator, engine: Ampe, cfg: *Configurator) status.AmpeError!*Self {
            const result: *Self = allocator.create(Self) catch {
                return status.AmpeError.AllocationFailed;
            };
            errdefer allocator.destroy(result);

            const srv: Self = .{
                .gpa = allocator,
                .ampe = engine,
                .cfg = cfg.*,
                .chnls = try engine.create(),
                .result = status.AmpeStatus.unknown_error,
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

pub fn handleReConnnectOfTcpClientServerST(gpa: Allocator) anyerror!status.AmpeStatus {
    // Both server and client are on localhost.
    var srvCfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("127.0.0.1", 32984) };
    var cltCfg: Configurator = .{ .tcp_client = configurator.TCPClientConfigurator.init("127.0.0.1", 32984) };

    return handleReConnectST(gpa, &srvCfg, &cltCfg);
}

pub fn handleReConnectST(gpa: Allocator, srvCfg: *Configurator, cltCfg: *Configurator) anyerror!status.AmpeStatus {
    // Same code for TCP and UDS client/server, only configurations differ.
    // Configurations must match (both TCP or both UDS).

    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // Example value.
        .maxPoolMsgs = 32, // Example value.
    };

    var eng: *Engine = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe: Ampe = try eng.ampe();

    const TofuServer = struct {
        const Self = @This();
        gpa: Allocator = undefined,
        ampe: Ampe = undefined,
        chnls: ?tofu.Channels = undefined,
        cfg: Configurator = undefined,
        helloBh: message.BinaryHeader = undefined,
        connected: bool = undefined,

        pub fn create(allocator: Allocator, engine: Ampe, cfg: *Configurator) status.AmpeError!*Self {
            const result: *Self = allocator.create(Self) catch {
                return status.AmpeError.AllocationFailed;
            };
            errdefer allocator.destroy(result);

            result.* = try Self.init(allocator, engine, cfg);

            try result.createListener();

            return result;
        }

        pub fn init(allocator: Allocator, engine: Ampe, cfg: *Configurator) status.AmpeError!Self {
            return .{
                .gpa = allocator,
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
            const allocator = self.gpa;
            defer allocator.destroy(self);
            self.deinit();
            return;
        }

        fn createListener(server: *Self) status.AmpeError!void {
            var welcomeRequest: ?*Message = server.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
            defer server.*.ampe.put(&welcomeRequest);

            server.*.cfg.prepareRequest(welcomeRequest.?) catch unreachable;

            var initialBh = server.*.chnls.?.sendToPeer(&welcomeRequest) catch unreachable;

            initialBh.dumpProto("server send ");

            var welcomeResponse: ?*Message = server.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                log.info("server - waitReceive error {s}", .{@errorName(err)});
                return err;
            };
            defer server.ampe.put(&welcomeResponse);

            welcomeResponse.?.bhdr.dumpProto("server recv ");

            if (welcomeResponse.?.bhdr.status == 0) {
                return;
            }
            status.raw_to_error(welcomeResponse.?.bhdr.status) catch |err| {
                log.info("server - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                return err;
            };
        }

        pub fn waitConnect(server: *Self, timeOut: u64) status.AmpeError!bool {
            log.debug("server wait HelloRequest send HelloResponse =>", .{});
            defer log.debug("server wait HelloRequest send HelloResponse <=", .{});

            if (server.connected) {
                return true;
            }

            server.connected = try server.waitRequest(.hello, timeOut);
            return server.connected;
        }

        pub fn recvByeRequest_sendByeResponse(server: *Self, timeOut: u64) status.AmpeError!bool {
            log.debug("server wait ByeRequest send ByeResponse =>", .{});
            defer log.debug("server wait ByeRequest send ByeResponse <=", .{});

            if (!server.connected) {
                return true;
            }

            return server.waitRequest(.bye, timeOut);
        }

        fn waitRequest(server: *Self, mtype: message.MessageType, timeOut: u64) status.AmpeError!bool {
            while (true) {
                var recvMsg: ?*Message = server.*.chnls.?.waitReceive(timeOut) catch |err| {
                    log.info("server - waitReceive error {s}", .{@errorName(err)});
                    return err;
                };
                defer server.ampe.put(&recvMsg);

                if (recvMsg == null) {
                    continue;
                }

                server.helloBh = recvMsg.?.bhdr;

                server.helloBh.dumpProto("server recv");

                if (recvMsg.?.bhdr.status != 0) {
                    if (status.raw_to_status(recvMsg.?.bhdr.status) == .pool_empty) {
                        log.info("server - Pool is empy - return message to the pool", .{});
                        continue;
                    }

                    status.raw_to_error(recvMsg.?.bhdr.status) catch |err| {
                        log.info("server -  - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        return err;
                    };
                }

                log.debug("server msg received on channel {d} mid {d}", .{ recvMsg.?.bhdr.channel_number, recvMsg.?.bhdr.message_id });

                assert(recvMsg.?.bhdr.proto.role == .request);
                assert(recvMsg.?.bhdr.proto.mtype == mtype);

                recvMsg.?.bhdr.proto.role = .response;
                recvMsg.?.bhdr.proto.origin = .application; // For sure

                const bh: message.BinaryHeader = server.*.chnls.?.sendToPeer(&recvMsg) catch |err| {
                    log.info("server - sendToPeer error {s}", .{@errorName(err)});
                    return err;
                };

                log.debug("server - send to channel {d} mid {d}", .{ bh.channel_number, bh.message_id });
                return true;
            }
        }
    };

    const TofuClient = struct {
        const Self = @This();
        gpa: Allocator = undefined,
        ampe: Ampe = undefined,
        chnls: ?tofu.Channels = undefined,
        cfg: Configurator = undefined,
        helloBh: message.BinaryHeader = undefined,
        connected: bool = undefined,

        pub fn create(allocator: Allocator, engine: Ampe, cfg: *Configurator) status.AmpeError!*Self {
            const result: *Self = allocator.create(Self) catch {
                return status.AmpeError.AllocationFailed;
            };
            errdefer allocator.destroy(result);

            result.* = try Self.init(allocator, engine, cfg);

            return result;
        }

        pub fn init(allocator: Allocator, engine: Ampe, cfg: *Configurator) status.AmpeError!Self {
            return .{
                .gpa = allocator,
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
            const allocator = self.gpa;
            defer allocator.destroy(self);
            self.deinit();
            return;
        }

        pub fn sendHelloRequest_recvHelloResponse(client: *Self, tries: usize, sleepBetweenNS: u64, srv: ?*TofuServer) status.AmpeError!void {
            log.debug("client send HelloRequest recv HelloResponse =>", .{});
            defer log.debug("client send HelloRequest recv HelloResponse <=", .{});

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
                        client.*.helloBh = client.*.chnls.?.sendToPeer(&helloRequest) catch unreachable;

                        client.*.helloBh.dumpProto("client send ");

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

                    recvMsg.?.bhdr.dumpProto("client recv");

                    // Ignore messages for already closed channel
                    if ((status.raw_to_status(recvMsg.?.bhdr.status) == .channel_closed) and (recvMsg.?.bhdr.channel_number != client.helloBh.channel_number)) {
                        continue;
                    }

                    switch (status.raw_to_status(recvMsg.?.bhdr.status)) {
                        .success => {
                            log.info("Client connected", .{});
                            client.connected = true;
                            return;
                        },
                        .pool_empty => {
                            log.info("Client - empty pool", .{});
                            continue; // defer above will return received signal message to the pool
                        },
                        .connect_failed => {
                            break; // connect should be repeated
                        },
                        .channel_closed => { // ????
                            buildAndSendHelloRequest = true;
                            continue;
                        },
                        else => {
                            status.raw_to_error(recvMsg.?.bhdr.status) catch |err| {
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

        pub fn sendByeRequest(client: *Self) status.AmpeError!void {
            log.debug("client send ByeRequest =>", .{});
            defer log.debug("client send ByeRequest <=", .{});

            if (!client.connected) {
                return;
            }

            // Prepare and send ByeRequest
            var byeRequest: ?*Message = client.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
            defer client.*.ampe.put(&byeRequest);

            // Don't forget set the same channel # returned after send HelloRequest
            byeRequest.?.bhdr.channel_number = client.*.helloBh.channel_number;
            byeRequest.?.bhdr.proto.mtype = .bye;
            byeRequest.?.bhdr.proto.role = .request;
            byeRequest.?.bhdr.proto.origin = .application;

            client.*.helloBh = client.*.chnls.?.sendToPeer(&byeRequest) catch unreachable;

            client.*.helloBh.dumpProto("client send ");

            return;
        }

        pub fn recvByeResponse(client: *Self, timeOut: u64) status.AmpeError!bool {
            log.debug("client wait ByeResponse =>", .{});
            defer log.debug("client wait ByeResponse <=", .{});

            if (!client.connected) {
                return true;
            }

            return client.recvResponse(.bye, timeOut);
        }

        fn recvResponse(client: *Self, mtype: message.MessageType, timeOut: u64) status.AmpeError!bool {
            while (true) {
                var recvMsg: ?*Message = client.*.chnls.?.waitReceive(timeOut) catch |err| {
                    log.info("client - waitReceive error {s}", .{@errorName(err)});
                    return err;
                };
                defer client.ampe.put(&recvMsg);

                if (recvMsg == null) {
                    continue;
                }

                recvMsg.?.bhdr.dumpProto("client recv");

                assert(client.helloBh.channel_number == recvMsg.?.bhdr.channel_number);

                if (recvMsg.?.bhdr.status != 0) {
                    if (status.raw_to_status(recvMsg.?.bhdr.status) == .pool_empty) {
                        log.info("client - Pool is empy - return message to the pool", .{});
                        continue;
                    }

                    status.raw_to_error(recvMsg.?.bhdr.status) catch |err| {
                        log.info("client -  - RECEIVED MESSAGE with error status {s}", .{@errorName(err)});
                        return err;
                    };
                }

                log.debug("client msg received on channel {d} mid {d}", .{ recvMsg.?.bhdr.channel_number, recvMsg.?.bhdr.message_id });

                assert(recvMsg.?.bhdr.proto.role == .response);
                assert(recvMsg.?.bhdr.proto.mtype == mtype);

                return true;
            }
        }
    };

    var tCl: *TofuClient = try TofuClient.create(gpa, ampe, cltCfg);
    defer tCl.destroy();

    try tCl.sendHelloRequest_recvHelloResponse(1, std.time.ns_per_ms * 10, null);

    var tSr: *TofuServer = try TofuServer.create(gpa, ampe, srvCfg);
    defer tSr.destroy();

    try tCl.sendHelloRequest_recvHelloResponse(1, std.time.ns_per_ms * 10, tSr);

    // wait HelloResponse
    // _ = try tCl.recvResponse(.hello, std.time.ns_per_ms * 100);

    try tCl.sendByeRequest();

    // wait ByeRequest on server and ByeResponse on client
    if ((try tSr.recvByeRequest_sendByeResponse(std.time.ns_per_ms * 100)) and (try tCl.recvByeResponse(std.time.ns_per_ms * 100))) {
        return status.AmpeStatus.success;
    }

    return status.AmpeStatus.communication_failed;
}

// Helper function to destroy Channels using defer.
// Suitable for tests and simple examples.
// In production, Channels is long-lived, and destruction
// should handle errors differently.
pub fn destroyChannels(ampe: tofu.Ampe, chnls: tofu.Channels) void {
    ampe.destroy(chnls) catch {};
}

pub inline fn sleepSec() void {
    std.time.sleep(1_000_000_000);
}

pub inline fn sleep1MlSec() void {
    std.time.sleep(1_000_000);
}

pub inline fn sleep10MlSec() void {
    std.time.sleep(1_000_000_0);
}
