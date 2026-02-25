//! Services interface for message processing.
//!
//! Flow: Server calls `waitReceive()` → passes message to `service.onMessage()` → service processes.
//!

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const log = std.log;
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;

pub const tofu = @import("tofu");
pub const Reactor = tofu.Reactor;
pub const Ampe = tofu.Ampe;
pub const ChannelGroup = tofu.ChannelGroup;
pub const address = tofu.address;
pub const Address = address.Address;
pub const status = tofu.status;
pub const message = tofu.message;
pub const BinaryHeader = message.BinaryHeader;
pub const Message = message.Message;

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const MultiHomed = @import("MultiHomed.zig");

/// Single-threaded. Server owns channels, service uses them.
pub const Services = struct {
    ptr: ?*anyopaque,
    vtable: *const SRVCSVTable,

    /// Initialize. Don't call waitReceive() or destroy channels.
    pub fn start(srvcs: Services, ampe: Ampe, sendTo: ChannelGroup) !void {
        return srvcs.vtable.*.start(srvcs.ptr, ampe, sendTo);
    }

    /// Return true to continue. Set msg.* = null to take ownership.
    pub fn onMessage(srvcs: Services, msg: *?*message.Message) bool {
        return srvcs.vtable.*.onMessage(srvcs.ptr, msg);
    }

    pub fn stop(srvcs: Services) void {
        return srvcs.vtable.*.stop(srvcs.ptr);
    }
};

pub const SRVCSVTable = struct {
    start: *const fn (ptr: ?*anyopaque, ampe: Ampe, sendTo: ChannelGroup) anyerror!void,

    stop: *const fn (ptr: ?*anyopaque) void,

    onMessage: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) bool,
};

/// Handles pool_empty. Stops after 1000 messages.
pub const EchoService = struct {
    // Engine interface for pool operations (get/put)
    engine: ?Ampe = null,

    // Channels for sending messages back to clients
    sendTo: ?ChannelGroup = null,

    // Atomic flag for graceful shutdown from another thread
    cancel: Atomic(bool) = .init(false),

    // Allocator for creating new messages when pool is empty
    allocator: Allocator = undefined,

    // Counter: stops after processing this many messages
    // Extra 100 for non-graceful close messages (ByeSignal, channel_closed, etc.)
    rest: u32 = 1000 + 100,

    pub fn services(echo: *EchoService) Services {
        return .{
            .ptr = echo,
            .vtable = &.{
                .start = start,
                .stop = stop,
                .onMessage = onMessage,
            },
        };
    }

    pub fn start(ptr: ?*anyopaque, ampe: Ampe, channels: ChannelGroup) !void {
        const echo: *EchoService = @ptrCast(@alignCast(ptr));
        echo.*.engine = ampe;
        echo.*.sendTo = channels;
        echo.*.cancel.store(false, .monotonic);
        echo.*.allocator = ampe.getAllocator();
        return;
    }

    pub fn stop(ptr: ?*anyopaque) void {
        const echo: *EchoService = @ptrCast(@alignCast(ptr));
        echo.*.engine = null;
        echo.*.sendTo = null;
        echo.*.cancel.store(true, .monotonic);
        return;
    }

    pub fn onMessage(ptr: ?*anyopaque, msg: *?*message.Message) bool {
        const echo: *EchoService = @ptrCast(@alignCast(ptr));

        if (echo.*.wasCancelled()) {
            return false;
        }

        if ((echo.*.engine == null) or (echo.*.sendTo == null)) { // before start or after stop
            echo.*.cancel.store(true, .monotonic);
            return false;
        }

        return echo.*.processMessage(msg);
    }

    pub fn processMessage(echo: *EchoService, msg: *?*message.Message) bool {
        if (msg.* == null) {
            return true;
        }

        if (echo.*.rest == 0) {
            return false;
        }

        msg.*.?.*.bhdr.dumpMeta("echo srvs received msg");

        const sts: status.AmpeStatus = status.raw_to_status(msg.*.?.*.bhdr.status);

        // Check message origin
        if (msg.*.?.isFromEngine()) {
            switch (sts) {
                .pool_empty => return echo.*.addMessagesToPool(),
                else => {
                    log.debug("received error status {s}", .{std.enums.tagName(status.AmpeStatus, sts).?});
                    return true;
                },
            }
        }

        // Transform request to response
        const oc: message.OpCode = msg.*.?.*.getOpCode() catch unreachable;
        switch (oc.getRole()) {
            .request => {
                msg.*.?.*.bhdr.proto.opCode = oc.echo() catch unreachable;
            },
            .signal => {},
            else => {
                log.warn("{s} is not supported", .{std.enums.tagName(message.OpCode, msg.*.?.*.bhdr.proto.opCode).?});
                return false;
            },
        }

        // Count application messages only
        if ((msg.*.?.*.bhdr.proto.getType() != .hello) and (msg.*.?.*.bhdr.proto.getType() != .bye)) {
            echo.*.rest -= 1;
        }

        msg.*.?.*.copyBh2Body();

        _ = echo.*.sendTo.?.post(msg) catch |err| {
            log.warn("post error {s}", .{@errorName(err)});
            return false;
        };

        return true;
    }

    pub inline fn setCancel(echo: *EchoService) void {
        echo.*.cancel.store(true, .monotonic);
    }

    pub inline fn wasCancelled(echo: *EchoService) bool {
        return echo.*.cancel.load(.monotonic);
    }

    pub fn addMessagesToPool(echo: *EchoService) bool {
        // Just one as example
        var newMsg: ?*Message = Message.create(echo.*.allocator) catch {
            return false;
        };
        echo.*.engine.?.put(&newMsg);
        return true;
    }
};

/// Runs on separate thread. Reports completion via mailbox.
pub const EchoClient = struct {
    const Self = EchoClient;

    // For usage as Letter in MailBoxIntrusive
    prev: ?*Self = null,
    next: ?*Self = null,

    ampe: Ampe = undefined,
    gpa: Allocator = undefined,
    chnls: ?ChannelGroup = null,
    adr: Address = undefined,
    ack: *mailbox.MailBoxIntrusive(Self) = undefined,
    thread: ?std.Thread = null,
    count: u16 = 0, // number of successful echoes
    echoes: u16 = 0,
    sts: status.AmpeStatus = .processing_failed,
    connected: bool = false,
    helloBh: BinaryHeader = .{},

    /// Connects, spawns thread. Sends self to ack mailbox when done.
    pub fn start(engine: Ampe, adr: Address, echoes: u16, ack: *mailbox.MailBoxIntrusive(EchoClient)) !void {
        const all: Allocator = engine.getAllocator();

        const result: *Self = all.create(Self) catch {
            return status.AmpeError.AllocationFailed;
        };
        errdefer result.*.destroy();

        result.* = .{
            .ampe = engine,
            .gpa = all,
            .adr = adr,
            .chnls = engine.create() catch unreachable,
            .ack = ack,
            .echoes = if (echoes == 0) 256 else echoes,
        };

        _ = try result.*.connect();

        result.*.thread = try std.Thread.spawn(.{}, runOnThread, .{result});

        return;
    }

    pub fn deinit(self: *Self) void {
        if (self.*.chnls != null) {
            self.*.ampe.destroy(self.*.chnls.?) catch {};
            self.*.chnls = null;
        }
        return;
    }

    pub fn release(self: *Self) void {
        self.*.ack.*.send(self) catch {
            self.*.destroy();
        };
        return;
    }

    pub fn destroy(self: *Self) void {
        const allocator: Allocator = self.*.gpa;
        defer allocator.destroy(self);
        self.*.deinit();
        return;
    }

    pub fn runOnThread(self: *Self) void {
        defer self.*.release();
        defer self.*.disconnect();

        _ = self.*.sendRecvEchoes() catch |err| {
            // Store error status
            // Error status will be send by destroy()
            self.*.sts = status.errorToStatus(err);
            return;
        };

        return;
    }

    pub fn connect(self: *Self) status.AmpeError!void {
        var helloRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
        defer self.*.ampe.put(&helloRequest);

        self.*.adr.format(helloRequest.?) catch unreachable;

        helloRequest.?.*.copyBh2Body();
        self.*.helloBh = try self.*.chnls.?.post(&helloRequest);

        while (true) { // Re-connect is not supported
            var recvMsgOpt: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                log.info("echo client - waitReceive error {s}", .{@errorName(err)});
                return err;
            };
            defer self.*.ampe.put(&recvMsgOpt);

            if (recvMsgOpt.?.isFromEngine()) {
                const sts: status.AmpeStatus = status.raw_to_status((recvMsgOpt.?.*.bhdr.status));

                if (sts == .pool_empty) {
                    continue; // defer above will put message to the pool
                }

                // Other statuses are failure
                log.info("echo client connect failed with status {s}", .{@tagName(sts)});
                return status.status_to_error(sts);
            }

            // Should be hello response
            assert(recvMsgOpt.?.*.bhdr.proto.opCode == .HelloResponse);
            self.*.connected = true;
            break;
        }

        return;
    }

    pub fn sendRecvEchoes(self: *Self) status.AmpeError!void {
        // Simular to connect, because connect is
        //     - send hello request
        //     - recv hello response

        // For now echo messages are empty - only binary header
        // is transferred

        for (1..self.*.echoes + 1) |mn| {
            var echoRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
            defer self.*.ampe.put(&echoRequest);

            // Prepare request - don't forget channel number
            echoRequest.?.*.bhdr.channel_number = self.*.helloBh.channel_number;

            // !!! We can set own value of message id !!!
            echoRequest.?.*.bhdr.message_id = mn;

            echoRequest.?.*.bhdr.proto = .default(.Request);

            echoRequest.?.*.bhdr.dumpMeta("echoRequest ");

            echoRequest.?.*.copyBh2Body();
            _ = try self.*.chnls.?.post(&echoRequest);

            while (true) { //
                var recvMsgOpt: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                    log.info("echo client - wait echo response waitReceive error {s}", .{@errorName(err)});
                    return err;
                };
                defer self.*.ampe.put(&recvMsgOpt);

                if (recvMsgOpt.?.isFromEngine()) {
                    const sts: status.AmpeStatus = status.raw_to_status((recvMsgOpt.?.*.bhdr.status));

                    if (sts == .pool_empty) {
                        continue; // defer above will put message to the pool
                    }

                    // Other statuses are failure
                    log.info("echo client failed with status {s}", .{@tagName(sts)});
                    return status.status_to_error(sts);
                }

                // Should be application response
                assert(recvMsgOpt.?.*.bhdr.proto.opCode == .Response);

                // And ofc the same message id
                assert(recvMsgOpt.?.*.bhdr.message_id == mn);

                recvMsgOpt.?.*.bhdr.dumpMeta("echoResponse ");

                break;
            }

            self.*.count += 1;
        }

        return;
    }

    pub fn disconnect(self: *Self) void {
        if (!self.*.connected) {
            return;
        }

        if (self.*.count > 0) {
            log.debug("transferred {d}", .{self.*.count});
        }

        // Disconnect from server
        var byeRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
        defer self.*.ampe.put(&byeRequest);

        // Set channel number to assigned earlier (hello request/response)
        byeRequest.?.*.bhdr.channel_number = self.*.helloBh.channel_number;

        byeRequest.?.*.bhdr.proto = .default(.ByeSignal);

        byeRequest.?.*.copyBh2Body();
        _ = self.*.chnls.?.post(&byeRequest) catch unreachable;

        // Wait close of the channel
        while (true) {
            var recvMsgOpt: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                log.info("echo client - waitReceive error during disconect {s}", .{@errorName(err)});
                return;
            };
            defer self.*.ampe.put(&recvMsgOpt);

            if (status.raw_to_status(recvMsgOpt.?.*.bhdr.status) == .channel_closed) {
                return;
            }
        }

        return;
    }

    pub fn backUp(self: *Self) void {
        defer self.*.destroy();

        _ = self.*.connect() catch |err| {
            // Store error status
            // Error status will be send by destroy()
            self.*.sts = status.errorToStatus(err);
            return;
        };

        while (true) {
            var helloRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
            defer self.*.ampe.put(&helloRequest);

            self.*.adr.format(helloRequest.?) catch unreachable;

            helloRequest.?.*.copyBh2Body();
            self.*.helloBh = self.*.chnls.?.post(&helloRequest) catch unreachable;

            var recvMsg: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                log.info("On client thread - waitReceive error {s}", .{@errorName(err)});
                return;
            };
            defer self.*.ampe.put(&recvMsg);

            if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .connect_failed) {
                // Connection failed - reconnect
                continue;
            }

            if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                log.info("Pool is empy - return message to the pool", .{});
                continue;
            }

            if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .receiver_update) {
                log.info("On client thread - exit required", .{});
                return;
            }

            if (recvMsg.?.*.bhdr.proto.opCode == .HelloResponse) {

                // Connected to server
                // NOTE: self.*.result is not defined in Self, assuming typo/omission
                // self.*.result = .success;

                // Disconnect from server
                recvMsg.?.*.bhdr.proto.default(.ByeSignal);

                recvMsg.?.*.copyBh2Body();
                _ = self.*.chnls.?.post(&recvMsg) catch unreachable;
                return;
            }
        }

        while (true) {
            var recvMsg: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_SEC_TIMEOUT) catch |err| {
                log.info("On client thread - waitReceive error {s}", .{@errorName(err)});
                return;
            };
            defer self.*.ampe.put(&recvMsg);

            if (recvMsg == null) {
                continue;
            }

            if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .pool_empty) {
                log.info("Pool is empy - return message to the pool", .{});
                continue;
            }

            if (status.raw_to_status(recvMsg.?.*.bhdr.status) == .receiver_update) {
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
};

pub const EchoClientServer = struct {
    gpa: Allocator = undefined,
    engine: ?*Reactor = null,
    ampe: Ampe = undefined,
    mh: ?*MultiHomed = null,
    ack: mailbox.MailBoxIntrusive(EchoClient) = .{},
    echsrv: ?*EchoService = null,
    clcCount: u16 = 0,
    echoes: usize = 0,

    pub fn init(allocator: Allocator, srvcfg: []Address) !EchoClientServer {
        var ecs: EchoClientServer = .{
            .gpa = allocator,
        };
        errdefer ecs.deinit();

        // Because EchoService creates Services interface,
        // it should be allocated on the heap.
        // ptr: ?*anyopaque - needs to point to valid
        // memory location is not changed during struct copy etc.
        ecs.echsrv = try ecs.gpa.create(EchoService);
        // FIX: The optional pointer must be accessed (.?), then dereferenced (.*)
        ecs.echsrv.?.* = .{};

        ecs.engine = try Reactor.create(ecs.gpa, .{ .initialPoolMsgs = 16, .maxPoolMsgs = 64 });
        // Dereference the optional pointer to engine, then dereference the pointer to call the method
        ecs.ampe = try ecs.engine.?.*.ampe();

        // Dereference the optional pointer to echsrv, then dereference the pointer to call the method
        ecs.mh = try MultiHomed.run(ecs.ampe, srvcfg, ecs.echsrv.?.*.services());

        return ecs;
    }

    pub fn run(ecs: *EchoClientServer, clncfg: []Address) !status.AmpeStatus {
        defer ecs.*.deinit();

        if (clncfg.len == 0) {
            return error.EmptyConfiguration;
        }

        const iterations = if (comptime builtin.os.tag == .windows) 10 else 100;

        for (1..iterations + 1) |_| {
            for (clncfg) |cladrs| {
                _ = EchoClient.start(ecs.*.ampe, cladrs, 100, &ecs.*.ack) catch |err| {
                    log.info("start EchoClient error {s}", .{@errorName(err)});
                    continue;
                };
                ecs.*.clcCount += 1;
            }
        }

        assert(ecs.*.clcCount > 0);

        // Wait finish of the clients
        for (0..ecs.*.clcCount) |ncl| {
            const finishedClient: *EchoClient = ecs.*.ack.receive(tofu.waitReceive_INFINITE_TIMEOUT) catch {
                // for any error - break wait
                break;
            };
            defer finishedClient.*.destroy();
            ecs.*.echoes += finishedClient.*.count;
            log.debug("client {d} processed {d} sum {d}", .{ ncl + 1, finishedClient.*.count, ecs.*.echoes });
        }

        const echoSts: status.AmpeStatus = if (ecs.*.echoes >= 1000) .success else .processing_failed;

        return echoSts;
    }

    pub fn deinit(ecs: *EchoClientServer) void {
        if (ecs.*.mh != null) {
            // Dereference the optional pointer to echsrv, then dereference the pointer to call the method
            ecs.*.echsrv.?.*.setCancel();

            // Dereference the optional pointer to mh, then call the method
            ecs.*.mh.?.*.stop();
            ecs.*.mh = null;

            ecs.*.gpa.destroy(ecs.*.echsrv.?);
        }

        ecs.*.cleanMbox();

        if (ecs.*.engine != null) {
            // Dereference the optional pointer to engine, then dereference the pointer to call the method
            ecs.*.engine.?.*.destroy();
            ecs.*.engine = null;
        }

        return;
    }

    pub fn cleanMbox(ecs: *EchoClientServer) void {
        var client: ?*EchoClient = ecs.*.ack.close();
        while (client != null) {
            assert(ecs.*.clcCount > 0);
            ecs.*.clcCount -= 1;
            ecs.*.echoes += client.?.*.count;
            client.?.*.destroy();
            const next: ?*EchoClient = client.?.*.next;
            client = next;
        }
        return;
    }
};
