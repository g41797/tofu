const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;

pub const tofu = @import("tofu");
pub const Engine = tofu.Engine;
pub const Ampe = tofu.Ampe;
pub const Channels = tofu.Channels;
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
    ///             services can use sendToPeer method.
    ///             --- Don't call waitReceive - it's duty of the server.        ---
    ///             --- Don't destroy 'channels' - it's also duty of the server. ---
    pub fn start(srvcs: Services, ampe: Ampe, sendTo: Channels) !void {
        return srvcs.vtable.start(srvcs.ptr, ampe, sendTo);
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
    /// Remember - you can use 'sendToPeer' from multiple threads.
    ///
    /// Returns
    ///    true  - continue to receive messages and call onMessage
    ///    false - stop to receive and call
    pub fn onMessage(srvcs: Services, msg: *?*message.Message) bool {
        return srvcs.vtable.onMessage(srvcs.ptr, msg);
    }

    /// Stop processing
    pub fn stop(srvcs: Services) void {
        return srvcs.vtable.stop(srvcs.ptr);
    }
};

const SRVCSVTable = struct {
    start: *const fn (ptr: ?*anyopaque, ampe: Ampe, sendTo: Channels) anyerror!void,

    stop: *const fn (ptr: ?*anyopaque) void,

    onMessage: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) bool,
};

/// Simplest service - 'echo'
/// For received request - send back the same message as response
/// For received signal - send it back as-is
/// Very lazy - stops after 1000 processed messages
pub const EchoService = struct {
    engine: ?Ampe = null,
    sendTo: ?Channels = null,
    cancel: Atomic(bool) = .init(false),
    allocator: Allocator = undefined,
    rest: u32 = 1000,

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

    fn start(ptr: ?*anyopaque, ampe: Ampe, channels: Channels) !void {
        const echo: *EchoService = @alignCast(@ptrCast(ptr));
        echo.*.engine = ampe;
        echo.*.sendTo = channels;
        echo.cancel.store(false, .monotonic);
        echo.allocator = ampe.getAllocator();
        return;
    }

    fn stop(ptr: ?*anyopaque) !void {
        const echo: *EchoService = @alignCast(@ptrCast(ptr));
        echo.*.engine = null;
        echo.*.sendTo = null;
        echo.cancel.store(true, .monotonic);
        return;
    }

    fn onMessage(ptr: ?*anyopaque, msg: *?*message.Message) bool {
        const echo: *EchoService = @alignCast(@ptrCast(ptr));

        if (echo.*.wasCancelled()) {
            return false;
        }

        if ((echo.*.engine == null) or (echo.*.sendTo == null)) { // before start or after stop
            echo.cancel.store(true, .monotonic);
            return false;
        }

        return echo.processMessage(msg);
    }

    fn processMessage(echo: *EchoService, msg: *?*message.Message) bool {
        if (msg.* == null) {
            return true;
        }

        if (echo.*.rest == 0) {
            return false;
        }

        echo.*.rest -= 1;

        msg.*.?.bhdr.dumpMeta("echo srvs received msg");

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
                .pool_empty => return echo.addMessagesToPool(),
                else => {
                    // Let's start to learn what are the list of possible error statuses.
                    // Later you can add specific handling per status
                    log.info("received error status {s}", .{std.enums.tagName(status.AmpeStatus, sts)});
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
                log.warn("message role {s} is not supported", .{std.enums.tagName(message.MessageRole, msg.*.?.*.bhdr.proto.role)});
                return false;
            },
        }

        _ = echo.*.sendTo.?.sendToPeer(msg) catch |err| {
            log.warn("sendToPeer error {s}", .{@errorName(err)});
            return false;
        };

        return true;
    }

    pub inline fn setCancel(echo: *EchoService) void {
        echo.cancel.store(true, .monotonic);
    }

    pub inline fn wasCancelled(echo: *EchoService) bool {
        echo.*.cancel.load(.monotonic);
    }

    fn addMessagesToPool(echo: *EchoService) bool {
        // Just one as example
        const newMsg: ?*Message = Message.create(echo.allocator) catch {
            return false;
        };
        echo.*.engine.?.put(&newMsg);
        return true;
    }
};

pub const EchoClient = struct {
    const Self = EchoClient;
    ampe: Ampe = undefined,
    gpa: Allocator = undefined,
    chnls: ?Channels = null,
    cfg: Configurator = undefined,
    ack: *MSGMailBox = undefined,
    thread: ?std.Thread = null,
    rest: u16 = 0,
    sts: status.AmpeStatus = .processing_failed,

    /// Init echo client and after successful connect immediately run it on the thread
    /// Does not support re-connect
    ///  cfg - server address configurator
    ///  echoes - count of sends
    ///  ack - mailbox for sending message with status of the processing
    pub fn start(engine: Ampe, cfg: *Configurator, echoes: u16, ack: *MSGMailBox) !void {
        const all: Allocator = engine.getAllocator();

        const result: *Self = all.create(Self) catch {
            return status.AmpeError.AllocationFailed;
        };
        errdefer result.*.destroy();

        result.* = .{
            .ampe = engine,
            .gpa = all,
            .cfg = cfg.*,
            .chnls = engine.create() catch unreachable,
            .ack = ack,
            .rest = if (echoes == 0) 256 else echoes,
        };

        _ = try result.*.connect();

        result.*.thread = try std.Thread.spawn(.{}, runOnThread, .{result});

        return;
    }

    fn deinit(self: *Self) void {
        if (self.*.chnls != null) {
            self.*.ampe.destroy(self.chnls.?) catch {};
            self.*.chnls = null;
        }

        if (self.*.thread != null) {
            // Send status of processing
            var msg: ?*Message = self.*.ampe.get(.always) catch unreachable;
            msg.?.*.bhdr.status = self.*.sts;
            self.*.ack.send(msg.?) catch {
                self.*.ampe.put(&msg);
            };
        }

        return;
    }

    pub fn destroy(self: *Self) void {
        const allocator = self.gpa;
        defer allocator.destroy(self);
        self.deinit();
        return;
    }

    fn runOnThread(self: *Self) void {
        defer self.*.destroy();

        _ = self.*.sendRecvEchoes() catch |err| {
            // Store error status
            // Error status will be send by destroy()
            self.*.sts = status.errorToStatus(err);
            return;
        };

        self.*.disconnect();

        return;
    }

    fn connect(self: *Self) status.AmpeError!void {
        _ = self;
        return .NotImplementedYet;
    }

    fn sendRecvEchoes(self: *Self) status.AmpeError!void {
        _ = self;
        return .NotImplementedYet;
    }

    fn disconnect(self: *Self) void {
        _ = self;
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

            _ = self.*.chnls.?.sendToPeer(&helloRequest) catch unreachable;

            var recvMsg: ?*Message = self.*.chnls.?.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT) catch |err| {
                log.info("On client thread - waitReceive error {s}", .{@errorName(err)});
                return;
            };
            defer self.ampe.put(&recvMsg);

            if (status.raw_to_status(recvMsg.?.bhdr.status) == .connect_failed) {
                // Connection failed - reconnect
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

                // Connected to server
                self.*.result = .success;

                // Disconnect from server
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
};

/// Example of echo client - server communication
pub const EchoClientServer = struct {
    gpa: Allocator = undefined,
    engine: ?*Engine = null,
    ampe: Ampe = undefined,
    mh: ?*MultiHomed = null,
    ack: MSGMailBox = .{},
    echsrv: EchoService = .{},

    pub fn init(allocator: Allocator, srvcfg: []Configurator, clncfg: []Configurator) !EchoClientServer {
        _ = allocator;
        _ = srvcfg;
        _ = clncfg;
        return status.AmpeError.NotImplementedYet;
    }

    pub fn run(ecs: *EchoClientServer) !status.AmpeStatus {
        _ = ecs;
        return status.AmpeError.NotImplementedYet;
    }

    pub fn deinit(ecs: *EchoClientServer) void {
        if (ecs.*.mh != null) {
            ecs.*.echsrv.setCancel();
            ecs.*.mh.?.stop();
            ecs.*.mh = null;
        }

        ecs.*.cleanMbox();

        if (ecs.*.engine != null) {
            ecs.*.engine.?.Destroy();
            ecs.*.engine = null;
        }

        return;
    }

    fn cleanMbox(ecs: *EchoClientServer) void {
        var allocated: ?*Message = ecs.*.ack.close();
        while (allocated != null) {
            const next: ?*Message = allocated.?.next;
            if (ecs.*.engine != null) {
                ecs.*.ampe.put(&allocated);
            } else {
                allocated.?.destroy();
            }
            allocated = next;
        }
        return;
    }
};
