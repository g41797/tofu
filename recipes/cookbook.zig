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

const SEC_TIMEOUT_MS = 1_000;
const INFINITE_TIMEOUT_MS = std.math.maxInt(u64);

pub fn createDestroyMain(gpa: Allocator) !void {
    var eng = try Engine.Create(gpa, DefaultOptions);
    defer eng.Destroy();
}

pub fn createDestroyEngine(gpa: Allocator) !void {
    var eng = try Engine.Create(gpa, DefaultOptions);
    defer eng.Destroy();

    const ampe = try eng.ampe();

    // You don't need to destroy/deinit ampe - it's just interface implemented by Engine
    _ = ampe;
}

pub fn createDestroyMessageChannelGroup(gpa: Allocator) !void {
    var eng = try Engine.Create(gpa, DefaultOptions);
    defer eng.Destroy();

    const ampe = try eng.ampe();

    const chnls = try ampe.create();

    // You destroy Channels via destroy it by ampe
    try ampe.destroy(chnls);
}

pub fn getMsgsFromSmallestPool(gpa: Allocator) !void {
    // For wrong values (0 or maxPoolMsgs < initialPoolMsgs)
    // tofu.DefaultOptions will be used
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg1 = try ampe.get(tofu.AllocationStrategy.poolOnly);

    // if not null - return to the pool.
    // pool will be cleaned during eng.Destroy();
    defer ampe.put(&msg1);

    if (msg1 == null) {
        return error.FirstMesssageShouldBeNotNull;
    }

    var msg2 = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg2);
    if (msg2 != null) {
        return error.SecondMesssageShouldBeNull;
    }

    // Pool is empty, but message will be allocated
    var msg3 = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&msg3);
    if (msg3 == null) {
        return error.THirdMesssageShouldBeNotNull;
    }

    return;
}

pub fn sendMessageFromThePool(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // What can you do?
    };

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // Message retrieved from the poll is not valid for send
    // without setup.
    // It will be returned to the pool by defer above
    _ = try chnls.asyncSend(&msg);

    return;
}

pub fn handleMessageWithWrongChannelNumber(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // What can you do?
    };

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // Only MessageType.hello and MessageType.welcome have message.ChannelNumber == 0
    // (this value has message returned from the pool).
    // The rest should have valid one (non-zero. existing)

    // Invalid Bye Request
    var bhdr = &msg.?.bhdr;
    bhdr.proto.mtype = .bye;
    bhdr.proto.role = .request;

    _ = try chnls.asyncSend(&msg);

    return;
}

pub fn handleHelloWithoutConfiguration(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer ampe.destroy(chnls) catch {
        // What can you do?
    };

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // Right ChannelNumber is not enough.
    // MessageType.hello should contain address of peer(server) to connect with.
    // MessageType.welcome should contain address of server for listening of connected clients.

    var bhdr = &msg.?.bhdr;

    // Hello Request without server address - in terms of tofu 'configuration'
    bhdr.proto.mtype = .hello;
    bhdr.proto.role = .request;

    _ = try chnls.asyncSend(&msg);

    return;
}

pub fn handleHelloWithWrongAddress(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // MessageType.hello should contain address of peer(server) to connect with.
    // This address should be resolved. For IP - it should be also valid.

    // Configuration is dedicated 'TextHeader' added to TextHeaders of the message.
    // tofu has helper objects (ok - structs) for creation of configuration in required format.
    // Let's suppose TCP server has address "tofu.server.zig" and port 3298.
    // We are going to use helpers for creation of server configuration within hello request.

    var cnfg: Configurator = .{ .tcp_client = TCPClientConfigurator.init("tofu.server.zig", 3298) };

    // Setup hello message - you don't need 3 lines below
    // var bhdr = &msg.?.bhdr;
    // bhdr.proto.mtype = .hello;
    // bhdr.proto.role = .request;

    // Appends configuration to TextHeaders of the message
    try cnfg.prepareRequest(msg.?);

    _ = try chnls.asyncSend(&msg);

    var recvMsg = try chnls.waitReceive(INFINITE_TIMEOUT_MS);

    const st = recvMsg.?.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleHelloToNonListeningServer(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // just for example
        .maxPoolMsgs = 64, // just for example
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // MessageType.hello should contain address of peer(server) to connect with.
    // This address should be resolved. For IP - it should be also valid.

    // Configuration is dedicated 'TextHeader' added to TextHeaders of the message.
    // tofu has helper objects (ok - structs) for creation of configuration in required format.
    // Let's suppose TCP server has address "127.0.0.1" and port 32987.
    // We are going to use helpers for creation of server configuration within hello request.

    var cnfg: Configurator = .{ .tcp_client = TCPClientConfigurator.init("127.0.0.1", 32987) };

    // Appends configuration to TextHeaders of the message
    try cnfg.prepareRequest(msg.?);

    // Store information for further processing
    const bhdr = try chnls.asyncSend(&msg);
    _ = bhdr;

    var recvMsg = try chnls.waitReceive(INFINITE_TIMEOUT_MS);

    const st = recvMsg.?.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleWelcomeWithWrongAddress(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 16, // just for example
    };

    var eng = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe = try eng.ampe();

    const chnls = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // MessageType.welcome should contain ip address and port of listening server.

    // Configuration is dedicated 'TextHeader' added to TextHeaders of the message.
    // tofu has helper objects (ok - structs) for creation of configuration in required format.
    // Let's suppose our listening TCP server has wrong IP address "192.128.4.5" and port 3298.
    // We are going to use helpers for creation of server configuration within welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("192.128.4.5", 3298) };

    // Appends configuration to TextHeaders of the message
    try cnfg.prepareRequest(msg.?);

    _ = try chnls.asyncSend(&msg);

    var recvMsg = try chnls.waitReceive(INFINITE_TIMEOUT_MS);

    const st = recvMsg.?.bhdr.status;
    ampe.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleStartOfTcpServerAkaListener(gpa: Allocator) !status.AmpeStatus {

    // WelcomeRequest for TCP/IP server should contain ip address and port of listening server.

    // Configuration is dedicated 'TextHeader' added to TextHeaders of the message.
    // tofu has helper structs for creation of configuration in required format.
    // Let's suppose our TCP server listens on all available network interfaces (IPv4 address "0.0.0.0" and port 32984.
    // We are going to use helpers for creation of server configuration within welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("0.0.0.0", 32984) };

    return handleStartOfListener(gpa, &cnfg);
}

pub fn handleStartOfUdsServerAkaListener(gpa: Allocator) !status.AmpeStatus {

    // "Unlike network sockets that use IP addresses and port numbers,
    // UDS utilizes a file path within the local file system to facilitate
    // inter-process communication (IPC) on the same machine."
    //
    // => WelcomeRequest for UDS server should contain file path.
    //
    // For testing purposes tofu has helper for creation of such (temporary) file.

    var tup: tofu.TempUdsPath = .{};

    const filePath = try tup.buildPath(gpa);

    // Create configurator for UDS Server
    var cnfg: Configurator = .{ .uds_server = configurator.UDSServerConfigurator.init(filePath) };

    // Call the same code used also for TCP/IP server
    return handleStartOfListener(gpa, &cnfg);
}

pub fn handleStartOfListener(gpa: Allocator, cnfg: *Configurator) !status.AmpeStatus {

    // The same code is used for both TCP amd UDS servers
    // Only configuration is different.

    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // just for example
        .maxPoolMsgs = 32, // just for example
    };

    var eng: *Engine = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe: Ampe = try eng.ampe();

    const chnls: Channels = try ampe.create();
    defer destroyChannels(ampe, chnls);

    var msg = try ampe.get(tofu.AllocationStrategy.poolOnly);
    defer ampe.put(&msg);

    // Appends configuration to TextHeaders of the message
    try cnfg.prepareRequest(msg.?);

    const corrInfo: BinaryHeader = try chnls.asyncSend(&msg);
    log.debug(">><< Listen will start on channel {d} ", .{corrInfo.channel_number});

    var recvMsg = try chnls.waitReceive(INFINITE_TIMEOUT_MS);

    // Don't forget return message to the pool:
    defer ampe.put(&recvMsg);

    const st = recvMsg.?.bhdr.status;

    // Received message should contain the same channel number
    assert(corrInfo.channel_number == recvMsg.?.bhdr.channel_number);

    // Because we send 'WelcomeRequest', received message should be 'WelcomeResponse'
    // with status of listen (success or failure).
    // We also may send 'WelcomeSignal'. As result we will get Signal with error
    // status only for failed listen.
    assert(recvMsg.?.bhdr.proto.mtype == .welcome);
    assert(recvMsg.?.bhdr.proto.role == .response);

    // We don't close this channel explicitly.
    // It will be closed during destroy of Channels
    // see 'defer destroyChannels(ampe, chnls)' above.

    // raw_to_status converts status byte (u8) from binary header
    // to AmpeStatus enum for your convenience.
    return status.raw_to_status(st);
}

pub fn handleConnnectOfTcpClientServer(gpa: Allocator) anyerror!status.AmpeStatus {

    // Both server and client are on the localhost
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

    // The same code is used for both TCP amd UDS client/server
    // Only configurations are different.
    // Of course configurations should be or for TCP client/server or for UDS ones.

    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // just for example
        .maxPoolMsgs = 32, // just for example
    };

    var eng: *Engine = try Engine.Create(gpa, options);
    defer eng.Destroy();
    const ampe: Ampe = try eng.ampe();

    // For simplicity we create the same Channels for the client and server.
    // You can create and use separated groups for the client and server.

    const chnls: Channels = try ampe.create();

    // We don't close this channel explicitly.
    // It will be closed during destroy of it's Channels
    defer destroyChannels(ampe, chnls);

    var welcomeRequest: ?*Message = try ampe.get(tofu.AllocationStrategy.poolOnly);

    // If pool is empty, for poolOnly AllocationStrategy.poolOnly it returns null
    if (welcomeRequest == null) {
        // You can directly create message. Use the same allocator used by Engine.Create.
        welcomeRequest = Message.create(gpa) catch unreachable;
    }

    // If message was send to ampe, welcome will be null
    // (tt's safe to put null message to the pool).
    // For failed send, message will be returned to the pool.
    defer ampe.put(&welcomeRequest);

    // Appends configuration to TextHeaders of the message
    try srvCfg.prepareRequest(welcomeRequest.?);

    const srvCorrInfo: BinaryHeader = try chnls.asyncSend(&welcomeRequest);
    log.debug(">><< Listen will start on channel {d} ", .{srvCorrInfo.channel_number});

    var welcomeResp: ?*Message = try chnls.waitReceive(INFINITE_TIMEOUT_MS);

    // Don't forget return message to the pool:
    defer ampe.put(&welcomeResp);

    var st: u8 = welcomeResp.?.bhdr.status;

    // This is the way of convert u8 status to AmpeError
    status.raw_to_error(st) catch |err| {
        log.debug(">><< welcomeResp error {s} ", .{@errorName(err)});
    };
    assert(st == 0);

    // Received message should contain the same channel number
    assert(srvCorrInfo.channel_number == welcomeResp.?.bhdr.channel_number);

    // Received message should contain the same message id
    // If you did not set it befoe send, tofu assigns sequential number
    assert(srvCorrInfo.message_id == welcomeResp.?.bhdr.message_id);

    // Because we send 'WelcomeRequest', received message should be 'WelcomeResponse'
    // with status of listen (success or failure).
    // We also may send 'WelcomeSignal'. As result we will get Signal with error
    // status only for failed listen.
    assert(welcomeResp.?.bhdr.proto.mtype == .welcome);
    assert(welcomeResp.?.bhdr.proto.role == .response);

    // For simplicity we also started listener before connect.
    //
    // In production client code should check connect status
    // and retry connect to the server.
    //
    // tofu does not support automatic re-connection
    // for ideological reasons.

    // In order to connect we will done almost the same boring
    // calls that were done for the listener.
    //
    // tofu is boring, most of the time you will work with structs
    // instead of playing with super-duper APIs

    // We are lazy enough to check result and use AllocationStrategy.always.
    var helloRequest: ?*Message = try ampe.get(tofu.AllocationStrategy.always);
    defer ampe.put(&helloRequest);

    // Appends configuration to TextHeaders of the message
    try cltCfg.prepareRequest(helloRequest.?);

    const cltCorrInfo: BinaryHeader = try chnls.asyncSend(&helloRequest);
    log.debug(">><< Connect will start on channel {d} ", .{cltCorrInfo.channel_number});

    // Should be different channels.
    assert(cltCorrInfo.channel_number != srvCorrInfo.channel_number);

    // Funny part - because group works with both client and server,
    // we should receive HelloRequest from the client side.
    // I'd like to remind you, that successful HelloRequest contains of two actions:
    // - connect to the server
    // - send HelloRequest message to the server
    //
    // Also it worth to remind, that real working with network/sockets is done
    // on dedicated thread. So actually both asyncSend and waitReceive are working
    // with internal message queues and don't make and socket calls.
    //
    // We use different names for HelloRequest - try to understand why...
    var helloRequestOnServerSide: ?*Message = try chnls.waitReceive(INFINITE_TIMEOUT_MS);
    defer ampe.put(&helloRequestOnServerSide);

    st = helloRequestOnServerSide.?.bhdr.status;
    const chN: message.ChannelNumber = helloRequestOnServerSide.?.bhdr.channel_number;
    status.raw_to_error(st) catch |err| {
        log.debug(">><< helloRequestOnServerSide channel {d} error {s} ", .{ chN, @errorName(err) });
    };
    assert(st == 0);

    // Store information about connected client
    const connectedClientInfo: BinaryHeader = helloRequestOnServerSide.?.bhdr;
    log.debug(">><< Channel of new connected client on the server side {d} ", .{connectedClientInfo.channel_number});

    // We have 3 different channels:
    // - listener channel (srvCorrInfo.channel_number)
    // - client channel on the client side (cltCorrInfo.channel_number)
    // - client channel on the server side (connectedClientInfo.channel_number)
    //
    // Remember - physical representation of the channel is stream oriented socket
    // (TCP/IP or UDS).
    // Most confusing part of connection flow - creation of the new socket on the server
    // side for every connected client.
    assert(connectedClientInfo.channel_number != srvCorrInfo.channel_number);
    assert(connectedClientInfo.channel_number != cltCorrInfo.channel_number);

    // Message id should be the same, because helloRequestOnServerSide is the copy of
    // hello
    assert(connectedClientInfo.message_id == cltCorrInfo.message_id);

    // Use the same message and send HelloResponse back
    // Set role to .response in order to create HelloResponse
    helloRequestOnServerSide.?.bhdr.proto.role = .response;
    _ = try chnls.asyncSend(&helloRequestOnServerSide);

    // Now we are on the client side:
    var helloResp: ?*Message = try chnls.waitReceive(INFINITE_TIMEOUT_MS);

    // Don't forget return message to the pool:
    defer ampe.put(&helloResp);

    st = helloResp.?.bhdr.status;

    // Received message should contain the same channel number and message id
    assert(cltCorrInfo.channel_number == helloResp.?.bhdr.channel_number);
    assert(cltCorrInfo.message_id == helloResp.?.bhdr.message_id);

    // Because we send 'HelloRequest', received message should be 'HelloResponse'
    // - from engine with error status for the failure
    // - from server side if connect + send HelloRequest were successful.
    // We also may send 'HelloSignal'. As result we will get Signal with error
    // status only for failed connect.
    assert(welcomeResp.?.bhdr.proto.mtype == .welcome);
    assert(welcomeResp.?.bhdr.proto.role == .response);

    // Close all 3 channels in 'force' mode.
    // It's dono via ByeSignal with oob == on

    var closeListener: ?*Message = try ampe.get(tofu.AllocationStrategy.always);

    // Prepare BySignal to listener channel
    closeListener.?.bhdr.proto.mtype = .bye;
    closeListener.?.bhdr.proto.role = .signal;
    closeListener.?.bhdr.proto.oob = .on;

    // Set channel_number in order to close this channel
    closeListener.?.bhdr.channel_number = srvCorrInfo.channel_number;

    _ = try chnls.asyncSend(&closeListener);

    var closeListenerResp: ?*Message = try chnls.waitReceive(INFINITE_TIMEOUT_MS);
    defer ampe.put(&closeListenerResp);

    assert(closeListenerResp.?.bhdr.status == status.status_to_raw(status.AmpeStatus.channel_closed));

    // Close one of the client channels
    var closeClient: ?*Message = try ampe.get(tofu.AllocationStrategy.always);

    // Prepare BySignal to listener channel
    closeClient.?.bhdr.proto.mtype = .bye;
    closeClient.?.bhdr.proto.role = .signal;
    closeClient.?.bhdr.proto.oob = .on;

    // Set channel_number in order to close this channel
    closeClient.?.bhdr.channel_number = cltCorrInfo.channel_number; //client channel on the client side

    _ = try chnls.asyncSend(&closeClient);

    // We should receive two messages with statuses,
    // because close of on socket on the side will immediately close
    // socket on the server side
    for (0..2) |_| {
        var closeClientResp: ?*Message = try chnls.waitReceive(INFINITE_TIMEOUT_MS);
        defer ampe.put(&closeClientResp);
        assert(closeClientResp.?.bhdr.status == status.status_to_raw(status.AmpeStatus.channel_closed));
    }

    // You saw that main tofu programming are done via
    // setting information within message itself.
    // There are only 3 communication APIs.
    // For now we know two of them:
    // - asyncSend
    // - waitRecv

    // raw_to_status converts status byte (u8) from binary header
    // to AmpeStatus enum for your convenience.
    return status.raw_to_status(st);
}

// Helper function - allows to destroy Channels using defer
// It's OK for the test and go-no-go examples.
// In production, Channels is long life "object" and you will
// use different approach for the destroy (at least you need to handle possible failure)
pub fn destroyChannels(ampe: tofu.Ampe, chnls: tofu.Channels) void {
    ampe.destroy(chnls) catch {};
}
