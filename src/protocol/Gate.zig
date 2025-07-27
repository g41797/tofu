// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Gate = @This();

allocator: Allocator = undefined,
options: protocol.Options = undefined,
pool: Pool = undefined,
acns: ActiveChannels = undefined,
msgs: MSGMailBox = undefined,
mutex: Mutex = undefined,
shutdown_started: bool = undefined,

pub fn init(gt: *Gate, allocator: Allocator, options: Options) !void {
    gt.allocator = allocator;
    gt.options = options;
    gt.pool = try Pool.init(gt.allocator);
    gt.acns = try ActiveChannels.init(allocator, 255);
    gt.msgs = .{};
    gt.mutex = .{};
    gt.shutdown_started = false;
    return;
}

pub fn amp(gt: *Gate) AMP {
    const result: AMP = .{
        .impl = gt,
        .functions = &.{
            .start_send = start_send,
            .wait_receive = wait_receive,
            .shutdown = shutdown,
            .get = get,
            .put = put,
        },
        .allocator = gt.allocator,
        .running = Atomic(bool).init(true),
        .shutdown_finished = Atomic(bool).init(false),
    };
    return result;
}

pub fn get(impl: *const anyopaque, force: bool) ?*Message {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    return gt._get(force);
}

pub fn put(impl: *const anyopaque, msg: *Message) void {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    return gt._put(msg);
}

pub fn start_send(impl: *const anyopaque, msg: *Message) !BinaryHeader {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    return gt._start_send(msg);
}

pub fn wait_receive(impl: *const anyopaque, timeout_ns: u64) anyerror!?*Message {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    return gt._wait_receive(timeout_ns);
}

fn _start_send(gt: *Gate, msg: *Message) !BinaryHeader {
    const vc = try msg.check_and_prepare();

    {
        gt.mutex.lock();
        defer gt.mutex.unlock();

        if ((msg.bhdr.channel_number != 0) and !gt.acns.exists(msg.bhdr.channel_number)) {
            msg.bhdr.status = status_to_raw(.invalid_channel_number);
            return AMPError.InvalidChannelNumber;
        } else {
            // channel_number == 0 - Allowed for ShutdownRequest/Response
            // For other messages - should be assigned
            if (!((vc == .ShutdownRequest) or (vc == .ShutdownResponse))) {
                var mID: ?MessageID = null;
                if (msg.bhdr.message_id != 0) {
                    mID = msg.bhdr.message_id;
                }
                const cres = gt.acns.createChannel(mID);
                msg.bhdr.channel_number = cres.@"0";
                msg.bhdr.message_id = cres.@"1";
            }
        }

        const ret = switch (vc) {
            .WelcomeRequest => gt.not_implemented(msg),
            .HelloRequest => gt.not_implemented(msg),
            .HelloResponse => gt.not_implemented(msg),
            .ByeRequest => gt.not_implemented(msg),
            .ByeResponse => gt.not_implemented(msg),
            .ByeSignal => gt.not_implemented(msg),
            .ControlRequest => gt.not_implemented(msg),
            .ControlSignal => gt.not_implemented(msg),
            .ShutdownRequest => gt.not_implemented(msg),
            .AppRequest => gt.not_implemented(msg),
            .AppResponse => gt.not_implemented(msg),
            .AppSignal => gt.not_implemented(msg),
            else => gt.not_allowed(msg),
        };
        return ret;
    }
}

fn _wait_receive(gt: *Gate, timeout_ns: u64) !?*Message {
    _ = gt;
    _ = timeout_ns;
    return null;
}

inline fn _get(gt: *Gate, force: bool) ?*Message {
    return gt.pool.get(force);
}

inline fn _put(gt: *Gate, msg: *Message) void {
    gt.pool.put(msg);

    return;
}

fn deinit(gt: *Gate) void {
    var allocated = gt.msgs.close();
    while (allocated != null) {
        const next = allocated.?.next;
        allocated.?.destroy();
        allocated = next;
    }

    gt.pool.close();
    gt.acns.deinit();

    return;
}

pub fn shutdown(impl: *const anyopaque) !void {
    var gt: *Gate = @constCast(@ptrCast(@alignCast(impl)));
    var allocator: Allocator = undefined;
    {
        gt.mutex.lock();
        defer gt.mutex.unlock();

        gt.shutdown_started = true;
        gt.msgs.interrupt() catch {};

        allocator = gt.allocator;
        gt.deinit();
    }
    allocator.destroy(gt);
    return;
}

inline fn not_implemented(gt: *Gate, msg: *Message) !BinaryHeader {
    _ = gt;
    msg.bhdr.status = status_to_raw(.not_implemented_yet);
    return AMPError.NotImplementedYet;
}

inline fn not_allowed(gt: *Gate, msg: *Message) !BinaryHeader {
    _ = gt;
    msg.bhdr.status = status_to_raw(.not_allowed);
    return AMPError.NotAllowed;
}

//
// usage: const ret = try sm[@intFromEnum(vc)].func(gt, msg);
//
// var sm = directEnumArray(VC, SendProc, 0, .{
//     .WelcomeRequest = SendProc{
//         .func = not_implemented,
//     },
//     .WelcomeResponse = SendProc{
//         .func = not_implemented,
//     },
//     .HelloRequest = SendProc{
//         .func = not_implemented,
//     },
//     .HelloResponse = SendProc{
//         .func = not_implemented,
//     },
//     .ByeRequest = SendProc{
//         .func = not_implemented,
//     },
//     .ByeResponse = SendProc{
//         .func = not_implemented,
//     },
//     .ByeSignal = SendProc{
//         .func = not_implemented,
//     },
//     .ControlRequest = SendProc{
//         .func = not_implemented,
//     },
//     .ControlResponse = SendProc{
//         .func = not_implemented,
//     },
//     .ControlSignal = SendProc{
//         .func = not_implemented,
//     },
//     .ShutdownRequest = SendProc{
//         .func = not_implemented,
//     },
//     .ShutdownResponse = SendProc{
//         .func = not_implemented,
//     },
//     .AppRequest = SendProc{
//         .func = not_implemented,
//     },
//     .AppResponse = SendProc{
//         .func = not_implemented,
//     },
//     .AppSignal = SendProc{
//         .func = not_implemented,
//     },
// });
//
// const send_method = *const fn (gt: *Gate, msg: *Message) anyerror!BinaryHeader;
//
// const SendProc = struct {
//     func: send_method = undefined,
// };

pub const message = @import("../message.zig");
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = @import("../TextHeaderIterator.zig");
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const VC = message.ValidCombination;

pub const protocol = @import("../protocol.zig");
pub const Options = protocol.Options;
pub const AMP = protocol.AMP;

pub const status = @import("../status.zig");
pub const AMPStatus = status.AMPStatus;
pub const AMPError = status.AMPError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const Pool = @import("Pool.zig");
const Notifier = @import("Notifier.zig");

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

pub const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
pub const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
const directEnumArray = std.enums.directEnumArray;
