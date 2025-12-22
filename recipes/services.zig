//! Services interface pattern for cooperative message processing in tofu applications.
//! Provides example implementations including EchoService, EchoClient, and EchoClientServer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;

pub const tofu = @import("tofu");
pub const Reactor = tofu.Reactor;
pub const Ampe = tofu.Ampe;
pub const ChannelGroup = tofu.ChannelGroup;
pub const configurator = tofu.configurator;
pub const Configurator = configurator.Configurator;
pub const status = tofu.status;
pub const message = tofu.message;
pub const BinaryHeader = message.BinaryHeader;
pub const Message = message.Message;

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const MultiHomed = @import("MultiHomed.zig");

/// Defines the Services interface for async message processing.
/// All methods of interfaces are called on the same thread of the caller(server).
pub const Services = struct {
    ptr: ?*anyopaque,
    vtable: *const SRVCSVTable,

    /// Activate cooperative processing.
    ///  - ampe - the same engine used by the server, services can use it for pool
    ///         operations (get/put)
    ///  - sendTo - channels created by the server for communication  with clients,
    ///             services can use enqueueToPeer method.
    ///             --- Don't call waitReceive - it's duty of the server.        ---
    ///             --- Don't destroy 'channels' - it's also duty of the server. ---
    pub fn start(srvcs: Services, ampe: Ampe, sendTo: ChannelGroup) !void {
        return srvcs.vtable.*.start(srvcs.ptr, ampe, sendTo);
    }

    /// For any client or engine message (received via waitReceive) server calls onMessage
    /// for further processing. onMessage always called from the same server thread.
    ///
    /// If service takes ownership of the message , it should set msg.* to null.
    ///
    /// After call services returns message to the pool (null is valid value for 'put')
    ///
    /// Service may send responses or signals to peer via 'channels' provided during start.
    ///
    /// For simple processing it may be good enough to process message within onMessage.
    /// But it's better to redistribute processing between pool of threads or similar mechanism.
    /// Remember - you can use 'enqueueToPeer' from multiple threads.
    ///
    /// Returns
    ///    true  - continue to receive messages and call onMessage
    ///    false - stop to receive and call
    pub fn onMessage(srvcs: Services, msg: *?*message.Message) bool {
        return srvcs.vtable.*.onMessage(srvcs.ptr, msg);
    }

    /// Stop processing
    pub fn stop(srvcs: Services) void {
        return srvcs.vtable.*.stop(srvcs.ptr);
    }
};

const SRVCSVTable = struct {
    start: *const fn (ptr: ?*anyopaque, ampe: Ampe, sendTo: ChannelGroup) anyerror!void,

    stop: *const fn (ptr: ?*anyopaque) void,

    onMessage: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) bool,
};

/// Simplest service - 'echo'
/// For received request - send back the same message as response
/// For received signal - send it back as-is
/// Very lazy - stops after 1000+ processed messages
pub const EchoService = struct {
    engine: ?Ampe = null,
    sendTo: ?ChannelGroup = null,
    cancel: Atomic(bool) = .init(false),
    allocator: Allocator = undefined,
    rest: u32 = 1000 + 100, // Added 100 messages, because non-graceful close

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

    fn start(ptr: ?*anyopaque, ampe: Ampe, channels: ChannelGroup) !void {
        const echo: *EchoService = @ptrCast(@alignCast(ptr));
        echo.*.engine = ampe;
        echo.*.sendTo = channels;
        echo.*.cancel.store(false, .monotonic);
        echo.*.allocator = ampe.getAllocator();
        return;
    }

    fn stop(ptr: ?*anyopaque) void {
        const echo: *EchoService = @ptrCast(@alignCast(ptr));
        echo.*.engine = null;
        echo.*.sendTo = null;
        echo.*.cancel.store(true, .monotonic);
        return;
    }

    fn onMessage(ptr: ?*anyopaque, msg: *?*message.Message) bool {
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

    fn processMessage(echo: *EchoService, msg: *?*message.Message) bool {
        if (msg.* == null) {
            return true;
        }

        if (echo.*.rest == 0) {
            return false;
        }

        msg.*.?.*.bhdr.dumpMeta("echo srvs received msg");

        const sts: status.AmpeStatus = status.raw_to_status(msg.*.?.*.bhdr.status);

        // Please pay attention - this code analyses only error statuses from engine.
        // Application may transfer own statuses for .origin == .application.
        // These statuses does not processed by engine and may be used free for
        // application purposes.

        // In cookbook examples I was lazy enough to separate engine and application statuses,
        // but you definitely are not...
        // As excuse - I did not use application statuses in examples.
        if (msg.*.?.*.bhdr.proto.origin == .engine) {
            switch (sts) {
                // For lack of free messages in the pool - add messages to the pool.
                // Also because we do nothing with former message, it also
                // will be returned to the pool after call of 'onMessage"
                .pool_empty => return echo.*.addMessagesToPool(),
                else => {
                    // Let's start to learn what are the list of possible error statuses.
                    // Later you can add specific handling per status
                    log.debug("received error status {s}", .{std.enums.tagName(status.AmpeStatus, sts).?});
                    // continue processing anyway
                    return true;
                },
            }
        }

        switch (msg.*.?.*.bhdr.proto.role) {
            .request => {
                msg.*.?.*.bhdr.proto.role = .response;
            },
            .signal => {},
            else => {
                log.warn("message role {s} is not supported", .{std.enums.tagName(message.MessageRole, msg.*.?.*.bhdr.proto.role).?});
                return false;
            },
        }

        if ((msg.*.?.*.bhdr.proto.mtype != .hello) and (msg.*.?.*.bhdr.proto.mtype != .bye)) {
            echo.*.rest -= 1;
        }

        msg.*.?.*.copyBh2Body();
        _ = echo.*.sendTo.?.enqueueToPeer(msg) catch |err| {
            log.warn("enqueueToPeer error {s}", .{@errorName(err)});
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

    fn addMessagesToPool(echo: *EchoService) bool {
        // Just one as example
        var newMsg: ?*Message = Message.create(echo.*.allocator) catch {
            return false;
        };
        echo.*.engine.?.put(&newMsg);
        return true;
    }
};

/// Simple echo client for testing tofu communication.
/// Connects to a server, sends echo requests, and validates responses.
pub const EchoClient = struct {
    const Self = EchoClient;

    // For usage as Letter in MailBoxIntrusive
    prev: ?*Self = null,
    next: ?*Self = null,

    ampe: Ampe = undefined,
    gpa: Allocator = undefined,
    chnls: ?ChannelGroup = null,
    cfg: Configurator = undefined,
    ack: *mailbox.MailBoxIntrusive(Self) = undefined,
    thread: ?std.Thread = null,
    count: u16 = 0, // number of successful echoes
    echoes: u16 = 0,
    sts: status.AmpeStatus = .processing_failed,
    connected: bool = false,
    helloBh: BinaryHeader = .{},

    /// Initializes and starts echo client on a separate thread after connecting to server.
    /// Does not support re-connect
    ///  cfg - server address configurator
    ///  echoes - count of sends
    ///  ack - mailbox for sending message with status of the processing
    pub fn start(engine: Ampe, cfg: Configurator, echoes: u16, ack: *mailbox.MailBoxIntrusive(EchoClient)) !void {
        const all: Allocator = engine.getAllocator();

        const result: *Self = all.create(Self) catch {
            return status.AmpeError.AllocationFailed;
        };
        errdefer result.*.destroy();

        result.* = .{
            .ampe = engine,
            .gpa = all,
            .cfg = cfg,
            .chnls = engine.create() catch unreachable,
            .ack = ack,
            .echoes = if (echoes == 0) 256 else echoes,
        };

        _ = try result.*.connect();

        result.*.thread = try std.Thread.spawn(.{}, runOnThread, .{result});

        return;
    }

    fn deinit(self: *Self) void {
        if (self.*.chnls != null) {
            self.*.ampe.destroy(self.*.chnls.?) catch {};
            self.*.chnls = null;
        }
        return;
    }

    fn release(self: *Self) void {
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

    fn runOnThread(self: *Self) void {
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

    fn connect(self: *Self) status.AmpeError!void {
        var helloRequest: ?*Message = self.*.ampe.get(tofu.AllocationStrategy.always) catch unreachable;
        defer self.*.ampe.put(&helloRequest);

        self.*.cfg.prepareRequest(helloRequest.?) catch unreachable;

        helloRequest.?.*.copyBh2Body();
        self.*.helloBh = try self.*.chnls.?.enqueueToPeer(&helloRequest);

        while (true) { // Re-connect is not supported
            var recvMsgOpt: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                log.info("echo client - waitReceive error {s}", .{@errorName(err)});
                return err;
            };
            defer self.*.ampe.put(&recvMsgOpt);

            if (recvMsgOpt.?.*.bhdr.proto.origin == .engine) {
                const sts: status.AmpeStatus = status.raw_to_status((recvMsgOpt.?.*.bhdr.status));

                if (sts == .pool_empty) {
                    continue; // defer above will put message to the pool
                }

                // Other statuses are failure
                log.info("echo client connect failed with status {s}", .{@tagName(sts)});
                return status.status_to_error(sts);
            }

            // Should be hello response
            assert(recvMsgOpt.?.*.bhdr.proto.mtype == .hello);
            assert(recvMsgOpt.?.*.bhdr.proto.role == .response);
            self.*.connected = true;
            break;
        }

        return;
    }

    fn sendRecvEchoes(self: *Self) status.AmpeError!void {
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

            echoRequest.?.*.bhdr.proto.mtype = .regular;
            echoRequest.?.*.bhdr.proto.origin = .application;
            echoRequest.?.*.bhdr.proto.role = .request;
            echoRequest.?.*.bhdr.proto.oob = .off;

            echoRequest.?.*.bhdr.dumpMeta("echoRequest ");

            echoRequest.?.*.copyBh2Body();
            _ = try self.*.chnls.?.enqueueToPeer(&echoRequest);

            while (true) { //
                var recvMsgOpt: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                    log.info("echo client - wait echo response waitReceive error {s}", .{@errorName(err)});
                    return err;
                };
                defer self.*.ampe.put(&recvMsgOpt);

                if (recvMsgOpt.?.*.bhdr.proto.origin == .engine) {
                    const sts: status.AmpeStatus = status.raw_to_status((recvMsgOpt.?.*.bhdr.status));

                    if (sts == .pool_empty) {
                        continue; // defer above will put message to the pool
                    }

                    // Other statuses are failure
                    log.info("echo client failed with status {s}", .{@tagName(sts)});
                    return status.status_to_error(sts);
                }

                // Should be application response
                assert(recvMsgOpt.?.*.bhdr.proto.mtype == .regular);
                assert(recvMsgOpt.?.*.bhdr.proto.role == .response);

                // And ofc the same message id
                assert(recvMsgOpt.?.*.bhdr.message_id == mn);

                recvMsgOpt.?.*.bhdr.dumpMeta("echoResponse ");

                break;
            }

            self.*.count += 1;
        }

        return;
    }

    fn disconnect(self: *Self) void {
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

        byeRequest.?.*.bhdr.proto.mtype = .bye;
        byeRequest.?.*.bhdr.proto.origin = .application;
        byeRequest.?.*.bhdr.proto.role = .signal;
        byeRequest.?.*.bhdr.proto.oob = .on;

        byeRequest.?.*.copyBh2Body();
        _ = self.*.chnls.?.enqueueToPeer(&byeRequest) catch unreachable;

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

    fn backUp(self: *Self) void {
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

            self.*.cfg.prepareRequest(helloRequest.?) catch unreachable;

            helloRequest.?.*.copyBh2Body();
            self.*.helloBh = self.*.chnls.?.enqueueToPeer(&helloRequest) catch unreachable;

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

            if (recvMsg.?.*.bhdr.proto.mtype == .hello) {
                assert(recvMsg.?.*.bhdr.proto.role == .response);

                // Connected to server
                // NOTE: self.*.result is not defined in Self, assuming typo/omission
                // self.*.result = .success;

                // Disconnect from server
                recvMsg.?.*.bhdr.proto.mtype = .bye;
                recvMsg.?.*.bhdr.proto.origin = .application;
                recvMsg.?.*.bhdr.proto.role = .signal;
                recvMsg.?.*.bhdr.proto.oob = .on;

                recvMsg.?.*.copyBh2Body();
                _ = self.*.chnls.?.enqueueToPeer(&recvMsg) catch unreachable;
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

/// Complete echo client-server example demonstrating tofu message passing.
/// Runs a multihomed server and multiple echo clients for testing.
pub const EchoClientServer = struct {
    gpa: Allocator = undefined,
    engine: ?*Reactor = null,
    ampe: Ampe = undefined,
    mh: ?*MultiHomed = null,
    ack: mailbox.MailBoxIntrusive(EchoClient) = .{},
    echsrv: ?*EchoService = null,
    clcCount: u16 = 0,
    echoes: usize = 0,

    /// Initializes the echo client-server system with the given server configurations.
    pub fn init(allocator: Allocator, srvcfg: []Configurator) !EchoClientServer {
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

        ecs.engine = try Reactor.Create(ecs.gpa, .{ .initialPoolMsgs = 16, .maxPoolMsgs = 64 });
        // Dereference the optional pointer to engine, then dereference the pointer to call the method
        ecs.ampe = try ecs.engine.?.*.ampe();

        // Dereference the optional pointer to echsrv, then dereference the pointer to call the method
        ecs.mh = try MultiHomed.run(ecs.ampe, srvcfg, ecs.echsrv.?.*.services());

        return ecs;
    }

    /// Runs the echo client-server test with the specified client configurations.
    /// Returns the final status after all clients complete their echo operations.
    pub fn run(ecs: *EchoClientServer, clncfg: []Configurator) !status.AmpeStatus {
        defer ecs.*.deinit();

        if (clncfg.len == 0) {
            return error.EmptyConfiguration;
        }

        for (1..100) |_| {
            for (clncfg) |clcnfg| {
                _ = EchoClient.start(ecs.*.ampe, clcnfg, 100, &ecs.*.ack) catch |err| {
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

    /// Cleans up all resources including the multihomed server and message pool.
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
            ecs.*.engine.?.*.Destroy();
            ecs.*.engine = null;
        }

        return;
    }

    fn cleanMbox(ecs: *EchoClientServer) void {
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
