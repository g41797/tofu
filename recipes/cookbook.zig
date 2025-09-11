const std = @import("std");
const Allocator = std.mem.Allocator;

pub const tofu = @import("tofu");
pub const Distributor = tofu.Distributor;
pub const Options = tofu.Options;
pub const DefaultOptions = tofu.DefaultOptions;
pub const configurator = tofu.configurator;
pub const Configurator = configurator.Configurator;
pub const TCPClientConfigurator = configurator.TCPClientConfigurator;

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

    const mchgr = try ampe.acquire();

    // You destroy MessageChannelGroup via release it by ampe
    try ampe.release(mchgr);
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

    const mchgr = try ampe.acquire();
    defer ampe.release(mchgr) catch {
        // What can you do?
    };

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

pub fn trySendMessageFromThePool(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.acquire();
    defer ampe.release(mchgr) catch {
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

pub fn trySendMessageWithWrongChannelNumber(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.acquire();
    defer ampe.release(mchgr) catch {
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
    bhdr.proto.mode = .request;

    _ = try mchgr.asyncSend(&msg);

    return;
}

pub fn trySendHelloWithoutConfiguration(gpa: Allocator) !void {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.acquire();
    defer ampe.release(mchgr) catch {
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
    bhdr.proto.mode = .request;

    _ = try mchgr.asyncSend(&msg);

    return;
}

pub fn trySendHelloWithWrongConfiguration(gpa: Allocator) !bool {
    const options: tofu.Options = .{
        .initialPoolMsgs = 1, // just for example
        .maxPoolMsgs = 1, // just for example
    };

    var dtr = try Distributor.Create(gpa, options);
    defer dtr.Destroy();
    const ampe = try dtr.ampe();

    const mchgr = try ampe.acquire();
    defer ampe.release(mchgr) catch {
        // What can you do?
    };

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
    // bhdr.proto.mode = .request;

    // Appends configuration to TextHeaders of the message
    _ = try cnfg.prepareRequest(msg.?);

    _ = try mchgr.asyncSend(&msg);

    return true;
}

pub fn hi() void {
    if (tofu.DBG) {
        std.log.debug("   ****  tofu HI (DEBUG MODE)  ****", .{});
    } else {
        std.log.debug("   ****  tofu HI (NON-DEBUG MODE)  ****", .{});
    }
}

pub fn bye() void {
    std.log.debug("   ****  tofu BYE  ****", .{});
}
