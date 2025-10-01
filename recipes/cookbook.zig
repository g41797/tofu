const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const assert = std.debug.assert;

pub const tofu = @import("tofu");
pub const Distributor = tofu.Distributor;
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
    var dtr = try Distributor.Create(gpa, DefaultOptions);
    defer dtr.Destroy();
}

pub fn createDestroyEngine(gpa: Allocator) !void {
    var dtr = try Distributor.Create(gpa, DefaultOptions);
    defer dtr.Destroy();

    const ampe = try dtr.ampe();

    // You don't need to destroy/deinit ampe - it's just interface implemented by Distributor
    _ = ampe;
}

pub fn createDestroyMessageChannelGroup(gpa: Allocator) !void {
    var dtr = try Distributor.Create(gpa, DefaultOptions);
    defer dtr.Destroy();

    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();

    // You destroy MessageChannelGroup via destroy it by ampe
    try ampe.destroy(mchgr);
}

pub fn getMsgsFromSmallestPool(gpa: Allocator) !void {
    // For wrong values (0 or maxPoolMsgs < initialPoolMsgs)
    // tofu.DefaultOptions will be used
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();
    defer destroyMcg(ampe, mchgr);

    var msg1 = try mchgr.get(tofu.AllocationStrategy.poolOnly);

    // if not null - return to the pool.
    // pool will be cleaned during dtr.Destroy();
    defer mchgr.put(&msg1);

    if (msg1 == null) {
        return error.FirstMesssageShouldBeNotNull;
    }

    var msg2 = try mchgr.get(tofu.AllocationStrategy.poolOnly);
    defer mchgr.put(&msg2);
    if (msg2 != null) {
        return error.SecondMesssageShouldBeNull;
    }

    // Pool is empty, but message will be allocated
    var msg3 = try mchgr.get(tofu.AllocationStrategy.always);
    defer mchgr.put(&msg3);
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

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();
    defer ampe.destroy(mchgr) catch {
        // What can you do?
    };

    var msg = try mchgr.get(tofu.AllocationStrategy.poolOnly);
    defer mchgr.put(&msg);

    // Message retrieved from the poll is not valid for send
    // without setup.
    // It will be returned to the pool by defer above
    _ = try mchgr.asyncSend(&msg);

    return;
}

pub fn handleMessageWithWrongChannelNumber(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();
    defer ampe.destroy(mchgr) catch {
        // What can you do?
    };

    var msg = try mchgr.get(tofu.AllocationStrategy.poolOnly);
    defer mchgr.put(&msg);

    // Only MessageType.hello and MessageType.welcome have message.ChannelNumber == 0
    // (this value has message returned from the pool).
    // The rest should have valid one (non-zero. existing)

    // Invalid Bye Request
    var bhdr = &msg.?.bhdr;
    bhdr.proto.mtype = .bye;
    bhdr.proto.role = .request;

    _ = try mchgr.asyncSend(&msg);

    return;
}

pub fn handleHelloWithoutConfiguration(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();
    defer ampe.destroy(mchgr) catch {
        // What can you do?
    };

    var msg = try mchgr.get(tofu.AllocationStrategy.poolOnly);
    defer mchgr.put(&msg);

    // Right ChannelNumber is not enough.
    // MessageType.hello should contain address of peer(server) to connect with.
    // MessageType.welcome should contain address of server for listening of connected clients.

    var bhdr = &msg.?.bhdr;

    // Hello Request without server address - in terms of tofu 'configuration'
    bhdr.proto.mtype = .hello;
    bhdr.proto.role = .request;

    _ = try mchgr.asyncSend(&msg);

    return;
}

pub fn handleHelloWithWrongAddress(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();
    defer destroyMcg(ampe, mchgr);

    var msg = try mchgr.get(tofu.AllocationStrategy.poolOnly);
    defer mchgr.put(&msg);

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

    _ = try mchgr.asyncSend(&msg);

    var recvMsg = try mchgr.waitReceive(INFINITE_TIMEOUT_MS);

    const st = recvMsg.?.bhdr.status;
    mchgr.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleHelloToNonListeningServer(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 16, // just for example
        .maxPoolMsgs = 64, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();
    defer destroyMcg(ampe, mchgr);

    var msg = try mchgr.get(tofu.AllocationStrategy.poolOnly);
    defer mchgr.put(&msg);

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
    const bhdr = try mchgr.asyncSend(&msg);
    _ = bhdr;

    var recvMsg = try mchgr.waitReceive(INFINITE_TIMEOUT_MS);

    const st = recvMsg.?.bhdr.status;
    mchgr.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleWelcomeWithWrongAddress(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 16, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();
    defer destroyMcg(ampe, mchgr);

    var msg = try mchgr.get(tofu.AllocationStrategy.poolOnly);
    defer mchgr.put(&msg);

    // MessageType.welcome should contain ip address and port of listening server.

    // Configuration is dedicated 'TextHeader' added to TextHeaders of the message.
    // tofu has helper objects (ok - structs) for creation of configuration in required format.
    // Let's suppose our listening TCP server has wrong IP address "192.128.4.5" and port 3298.
    // We are going to use helpers for creation of server configuration within welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("192.128.4.5", 3298) };

    // Appends configuration to TextHeaders of the message
    try cnfg.prepareRequest(msg.?);

    _ = try mchgr.asyncSend(&msg);

    var recvMsg = try mchgr.waitReceive(INFINITE_TIMEOUT_MS);

    const st = recvMsg.?.bhdr.status;
    mchgr.put(&recvMsg);
    return status.raw_to_error(st);
}

pub fn handleStartOfTcpServerAkaListener(gpa: Allocator) !status.AmpeStatus {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 16, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.create();
    defer destroyMcg(ampe, mchgr);

    var msg = try mchgr.get(tofu.AllocationStrategy.poolOnly);
    defer mchgr.put(&msg);

    // MessageType.welcome should contain ip address and port of listening server.

    // Configuration is dedicated 'TextHeader' added to TextHeaders of the message.
    // tofu has helper structs for creation of configuration in required format.
    // Let's suppose our TCP server listens on all available network interfaces (IPv4 address "0.0.0.0" and port 32984.
    // We are going to use helpers for creation of server configuration within welcome request.

    var cnfg: Configurator = .{ .tcp_server = configurator.TCPServerConfigurator.init("0.0.0.0", 32984) };

    // Appends configuration to TextHeaders of the message
    try cnfg.prepareRequest(msg.?);

    const corrInfo: message.BinaryHeader = try mchgr.asyncSend(&msg);
    log.debug("Listen will start on channel {d} ", .{corrInfo.channel_number});

    var recvMsg = try mchgr.waitReceive(INFINITE_TIMEOUT_MS);

    // Don't forget return message to the pool:
    defer mchgr.put(&recvMsg);

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
    // It will be closed during destroy of MessageChannelGroup
    // see 'defer destroyMcg(ampe, mchgr)' above.

    // raw_to_status converts status byte (u8) from binary header
    // to AmpeStatus enum for your convenience.
    return status.raw_to_status(st);
}

// Helper function - allows to destroy MessageChannelGroup using defer
// It's OK for the test and go-no-go examples.
// In production, MessageChannelGroup is long life "object" and you will
// use other approach for the destroy (at least you need to handle possible failure)
pub fn destroyMcg(ampe: tofu.Ampe, mcg: tofu.MessageChannelGroup) void {
    ampe.destroy(mcg) catch {};
}
