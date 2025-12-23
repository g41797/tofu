//! Services interface pattern for cooperative message processing in tofu applications.
//!
//! This file demonstrates the Services pattern - a cooperative way to process messages
//! received by a server. The key insight: messages are cubes. Services process these cubes
//! and optionally send new cubes back to clients.
//!
//! **Core Pattern:**
//! Server calls `waitReceive()` → gets message → calls `service.onMessage()` → service processes
//!
//! **Three Example Implementations:**
//! - `EchoService`: Simplest service - receives request, sends back as response
//! - `EchoClient`: Complete client lifecycle - connect, send echoes, disconnect
//! - `EchoClientServer`: Full system with multihomed server + multiple clients
//!
//! **Message-as-Cube Philosophy:**
//! Each message is independent cube. Services combine cubes to create application logic.
//! No complex frameworks. Just: receive cube → process → optionally send cube.

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

/// Defines the Services interface for cooperative message processing.
///
/// **Threading Model:**
/// All methods are called on the same thread (the server thread that calls `waitReceive()`).
/// This single-threaded model simplifies state management in your service.
///
/// **Message-as-Cube Pattern:**
/// The service receives message cubes from `onMessage()`, processes them, and optionally
/// sends new message cubes via `enqueueToPeer()`. Think of it like a factory assembly line:
/// cubes come in, you transform or respond to them, cubes go out.
///
/// **Cooperative Processing:**
/// Server and service work together. Server handles `waitReceive()`, service handles business logic.
/// Server owns the channels. Service uses them but does not destroy them.
pub const Services = struct {
    ptr: ?*anyopaque,
    vtable: *const SRVCSVTable,

    /// Starts cooperative processing. Server calls this before message loop.
    ///
    /// **Parameters:**
    /// - `ampe` - Same engine as server. Use for pool operations (`get()`/`put()`)
    /// - `sendTo` - Channels created by server. Use `enqueueToPeer()` to send messages.
    ///
    /// **Important Rules:**
    /// - Do NOT call `waitReceive()` - server handles this
    /// - Do NOT destroy channels - server owns them
    /// - You CAN use `enqueueToPeer()` from multiple threads
    /// - You CAN use `get()`/`put()` from multiple threads
    ///
    /// **Pattern:**
    /// ```zig
    /// fn start(ptr: ?*anyopaque, ampe: Ampe, channels: ChannelGroup) !void {
    ///     const self: *MyService = @ptrCast(@alignCast(ptr));
    ///     self.engine = ampe;
    ///     self.sendTo = channels;
    ///     // Initialize your service state
    /// }
    /// ```
    pub fn start(srvcs: Services, ampe: Ampe, sendTo: ChannelGroup) !void {
        return srvcs.vtable.*.start(srvcs.ptr, ampe, sendTo);
    }

    /// Processes one message cube. Server calls this for every received message.
    ///
    /// **Message Ownership:**
    /// - Message comes in via `msg` parameter
    /// - If you take ownership, set `msg.* = null`
    /// - If you don't take ownership, server returns message to pool after this call
    /// - Null is valid value for `put()` - it just does nothing
    ///
    /// **Thread Context:**
    /// Always called from same server thread. Your service can have non-thread-safe state.
    ///
    /// **Sending Messages:**
    /// Use `sendTo.enqueueToPeer()` to send responses or signals. You can send from this
    /// function or delegate to worker threads. Remember: `enqueueToPeer()` is thread-safe.
    ///
    /// **Return Value:**
    /// - `true` - Continue processing. Server will call `onMessage()` again for next message.
    /// - `false` - Stop processing. Server exits message loop and calls `stop()`.
    ///
    /// **Example Pattern:**
    /// ```zig
    /// fn onMessage(ptr: ?*anyopaque, msg: *?*Message) bool {
    ///     // Check status
    ///     if (msg.*.?.*.bhdr.status != 0) {
    ///         // Handle error status
    ///     }
    ///
    ///     // Transform request to response (reuse same message cube)
    ///     msg.*.?.*.bhdr.proto.role = .response;
    ///
    ///     // Send back
    ///     _ = sendTo.enqueueToPeer(msg) catch { return false; };
    ///
    ///     return true; // Continue
    /// }
    /// ```
    pub fn onMessage(srvcs: Services, msg: *?*message.Message) bool {
        return srvcs.vtable.*.onMessage(srvcs.ptr, msg);
    }

    /// Stops processing. Server calls this after message loop exits.
    ///
    /// Clean up your service resources here. Server will destroy channels after this.
    pub fn stop(srvcs: Services) void {
        return srvcs.vtable.*.stop(srvcs.ptr);
    }
};

const SRVCSVTable = struct {
    start: *const fn (ptr: ?*anyopaque, ampe: Ampe, sendTo: ChannelGroup) anyerror!void,

    stop: *const fn (ptr: ?*anyopaque) void,

    onMessage: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) bool,
};

/// Simplest service implementation - echo server pattern.
///
/// **What It Does:**
/// Receives message cube → transforms it → sends back
/// - Request becomes response (same message_id)
/// - Signal sent back as-is
///
/// **Key Pattern Demonstrated:**
/// Message cube reuse. Does not create new messages. Just changes role field and sends back.
/// This is efficient and shows the message-as-cube concept clearly.
///
/// **Lifecycle:**
/// - Server calls `start()` - service saves engine and channels
/// - Server calls `onMessage()` for each received message
/// - Service processes message (changes request → response)
/// - Service sends message back
/// - After 1000 messages, service returns `false` to stop
///
/// **Error Handling Pattern:**
/// Handles `pool_empty` status by adding messages to pool. Shows how to handle
/// engine-originated status values. Application status values pass through unchanged.
///
/// **Thread Safety:**
/// All methods called from one thread (server thread). No synchronization needed
/// except for cancel flag (used for graceful shutdown from another thread).
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

    // Core message processing function. Demonstrates key tofu patterns.
    fn processMessage(echo: *EchoService, msg: *?*message.Message) bool {
        // Null message is valid (can happen after ownership transfer). Just continue.
        if (msg.* == null) {
            return true;
        }

        // Check if we processed enough messages. Service decides when to stop.
        if (echo.*.rest == 0) {
            return false; // Signal server to stop calling onMessage
        }

        msg.*.?.*.bhdr.dumpMeta("echo srvs received msg");

        const sts: status.AmpeStatus = status.raw_to_status(msg.*.?.*.bhdr.status);

        // IMPORTANT PATTERN: Check message origin first
        //
        // Messages have two origins:
        // 1. .engine - Created by tofu engine (status values mean specific things)
        // 2. .application - Created by your app (status values are yours to define)
        //
        // Always check origin before interpreting status byte. Same status value
        // means different things depending on origin.
        //
        // This pattern shows engine status handling. Application status handling
        // would go in the else branch (not shown here for simplicity).
        if (msg.*.?.*.bhdr.proto.origin == .engine) {
            switch (sts) {
                // POOL_EMPTY PATTERN:
                // Pool has no free messages. Add messages to pool and continue.
                // The received message (which has pool_empty status) will be returned
                // to pool automatically after onMessage returns.
                .pool_empty => return echo.*.addMessagesToPool(),

                // OTHER ENGINE STATUSES:
                // Could be: connect_failed, channel_closed, communication_failed, etc.
                // For echo service, we log but continue. Real service would handle
                // specific statuses (e.g., stop on channel_closed).
                else => {
                    log.debug("received error status {s}", .{std.enums.tagName(status.AmpeStatus, sts).?});
                    return true; // Continue despite error
                },
            }
        }

        // MESSAGE TRANSFORMATION PATTERN:
        // Echo service transforms request → response by changing role field.
        // Signal stays as signal (no transformation).
        // This demonstrates message cube reuse - no new allocation needed.
        switch (msg.*.?.*.bhdr.proto.role) {
            .request => {
                // Transform request cube to response cube
                msg.*.?.*.bhdr.proto.role = .response;
            },
            .signal => {
                // Signal stays as signal
            },
            else => {
                // Response role here would be error (we don't expect responses)
                log.warn("message role {s} is not supported", .{std.enums.tagName(message.MessageRole, msg.*.?.*.bhdr.proto.role).?});
                return false;
            },
        }

        // Count only application messages (not hello/bye protocol messages)
        if ((msg.*.?.*.bhdr.proto.mtype != .hello) and (msg.*.?.*.bhdr.proto.mtype != .bye)) {
            echo.*.rest -= 1;
        }

        // Copy binary header to body. Useful for debugging - receiver can compare
        // what was sent vs what was received.
        msg.*.?.*.copyBh2Body();

        // Send message cube back to client
        // After this call, msg.* becomes null (ownership transferred to engine)
        _ = echo.*.sendTo.?.enqueueToPeer(msg) catch |err| {
            log.warn("enqueueToPeer error {s}", .{@errorName(err)});
            return false; // Stop on send error
        };

        return true; // Continue processing
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

/// Complete echo client implementation demonstrating full client lifecycle.
///
/// **Pattern Demonstrated:**
/// Connect → Send N echo requests → Receive N responses → Disconnect
///
/// **Key Concepts Shown:**
/// 1. Connection establishment (HelloRequest → HelloResponse)
/// 2. Request-response pattern with message_id correlation
/// 3. Setting custom message_id values (instead of auto-generated)
/// 4. Graceful disconnect (ByeSignal with OOB flag)
/// 5. Error handling (pool_empty, connection failures)
/// 6. Thread-based client (runs on separate thread)
///
/// **Message Flow:**
/// ```
/// Client                    Server
///   |--HelloRequest------->|
///   |<--HelloResponse------|  (connection established)
///   |--EchoRequest[1]----->|
///   |<--EchoResponse[1]----|  (same message_id)
///   |--EchoRequest[2]----->|
///   |<--EchoResponse[2]----|  (same message_id)
///   ...
///   |--ByeSignal(OOB)----->|
///   |<--ChannelClosed------|
/// ```
///
/// **Usage Pattern:**
/// ```zig
/// var ackMbox: MailBoxIntrusive(EchoClient) = .{};
/// try EchoClient.start(ampe, cfg, 100, &ackMbox);
/// const finished: *EchoClient = try ackMbox.receive(timeout);
/// defer finished.destroy();
/// // Check finished.count for successful echoes
/// ```
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

    /// Creates and starts echo client on a separate thread.
    ///
    /// **Parameters:**
    /// - `engine` - Ampe interface for pool operations and channel creation
    /// - `cfg` - Server address configuration (TCP or UDS)
    /// - `echoes` - Number of echo requests to send (0 means 256)
    /// - `ack` - Mailbox for receiving completion notification
    ///
    /// **Behavior:**
    /// 1. Creates client struct and channel group
    /// 2. Connects to server (sends HelloRequest, waits for HelloResponse)
    /// 3. Spawns thread that sends/receives echo messages
    /// 4. When done, client sends itself to `ack` mailbox
    ///
    /// **Important:**
    /// Does NOT support reconnection. Connection failure stops client.
    ///
    /// **Usage:**
    /// ```zig
    /// var ackMbox: MailBoxIntrusive(EchoClient) = .{};
    /// try EchoClient.start(ampe, tcpCfg, 100, &ackMbox);
    /// // Wait for completion
    /// const client: *EchoClient = try ackMbox.receive(timeout);
    /// defer client.destroy();
    /// log.info("Processed {d} echoes", .{client.count});
    /// ```
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
