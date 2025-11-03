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
pub const status = tofu.status;
pub const message = tofu.message;
pub const BinaryHeader = message.BinaryHeader;
pub const Message = message.Message;

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
pub const EchoService = struct {
    engine: ?Ampe = null,
    sendTo: ?Channels = null,
    cancel: Atomic(bool) = .init(false),
    allocator: Allocator = undefined,

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

        if (echo.*.cancel.load(.monotonic)) {
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

        const sts: status.AmpeStatus = status.raw_to_status(msg.*.?.*.bhdr.status);

        // Please pay attention - this code analyses only error statuses from engine.
        // Application may transfer own statuses for .origin == .application.
        // These statuses does not processed by engine and may be used free for
        // application purposes.

        // In cookbook examples I was lazy enough to separate engine and application statuses,
        // but you definitely are  not...
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

    fn addMessagesToPool(echo: *EchoService) bool {
        // Just one as example
        const newMsg: ?*Message = Message.create(echo.allocator) catch {
            return false;
        };
        echo.*.engine.?.put(&newMsg);
        return true;
    }
};
