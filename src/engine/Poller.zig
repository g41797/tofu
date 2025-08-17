// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Poller = @This();

const PolledChannel = struct {
    acn: channels.ActiveChannel = undefined,
    tskt: TriggeredSkt = undefined,
    trgrs: sockets.Triggers = undefined,
};

mutex: Mutex = undefined,
allocator: Allocator = undefined,
options: engine.Options = undefined,
msgs: [2]MSGMailBox = undefined,
ntfr: Notifier = undefined,
pool: Pool = undefined,
acns: ActiveChannels = undefined,
maxid: u32 = undefined,
ntfsEnabled: bool = undefined,
thread: ?Thread = null,

// Accessible from the thread - don't lock/unlock
cnhsVtor: std.ArrayList(channels.ChannelNumber) = undefined,
pollfdVtor: std.ArrayList(std.posix.pollfd) = undefined,
polled_map: std.AutoArrayHashMap(channels.ChannelNumber, PolledChannel) = undefined,

pub fn ampe(plr: *Poller) !Ampe {
    try plr.*.createThread();

    const result: Ampe = .{
        .ptr = plr,
        .vtable = &.{
            .create = create,
            .destroy = destroy,
        },
    };

    return result;
}

pub fn alerter(plr: *Poller) Notifier.Alerter {
    const result: Notifier.Alerter = .{
        .ptr = plr,
        .func = send_alert,
    };
    return result;
}

pub fn init(gpa: Allocator, options: Options) !Poller {
    var plr: Poller = .{
        .mutex = .{},
        .allocator = gpa,
        .options = options,
        .msgs = .{ .{}, .{} },
        .maxid = 0,
    };

    plr.acns = try ActiveChannels.init(plr.allocator, 255);
    errdefer plr.acns.deinit();

    plr.ntfr = try Notifier.init(plr.allocator);
    errdefer plr.ntfr.deinit();

    plr.pool = try Pool.init(plr.allocator, plr.alerter());
    errdefer plr.pool.close();

    try plr.prepareForThreadRunning();

    return plr;
}

pub fn deinit(plr: *Poller) void {
    const gpa = plr.allocator;
    _ = gpa;
    {
        plr.mutex.lock();
        defer plr.mutex.unlock();

        for (plr.msgs, 0..) |_, i| {
            var mbx = plr.msgs[i];
            var allocated = mbx.close();
            while (allocated != null) {
                const next = allocated.?.next;
                allocated.?.destroy();
                allocated = next;
            }
        }

        plr.pool.close();
        plr.acns.deinit();

        plr.ntfr.deinit();
        plr.ntfsEnabled = false;
    }

    plr.waitFinish();

    plr.* = undefined;
}

pub fn create(ptr: ?*anyopaque) !*Sr {
    const plr: *Poller = @alignCast(@ptrCast(ptr));
    return plr._create();
}

pub fn destroy(ptr: ?*anyopaque, sr: *Sr) !void {
    const plr: *Poller = @alignCast(@ptrCast(ptr));
    return plr._destroy(sr);
}

inline fn _create(plr: *Poller) !*Sr {
    plr.maxid += 1;

    const srptr = try plr.allocator.create(Sr);
    errdefer plr.allocator.destroy(srptr);

    var srs = try SenderReceiver.create(plr, plr.maxid);

    srptr.* = srs.sr();

    return srptr;
}

inline fn _destroy(plr: *Poller, sr: *Sr) !void {
    const srs: *SenderReceiver = @alignCast(@ptrCast(sr.ptr));
    srs.destroy();
    plr.allocator.destroy(sr);
    return;
}

pub fn submitMsg(plr: *Poller, msg: *Message, hint: VC, priority: Notifier.MessagePriority) !void {
    plr.mutex.lock();
    defer plr.mutex.unlock();

    if (!plr.ntfsEnabled) {
        return AMPError.NotificationDisabled;
    }

    try plr.msgs[@intFromEnum(priority)].send(msg);

    try plr.ntfr.sendNotification(.{
        .kind = .message,
        .hint = hint,
        .priority = priority,
    });

    return;
}

pub fn send_alert(ptr: ?*anyopaque, alert: Notifier.Alert) !void {
    const plr: *Poller = @alignCast(@ptrCast(ptr));
    return plr.sendAlert(alert);
}

pub fn sendAlert(plr: *Poller, alrt: Notifier.Alert) !void {
    plr.mutex.lock();
    defer plr.mutex.unlock();

    if (!plr.ntfsEnabled) {
        return AMPError.NotificationDisabled;
    }

    try plr.ntfr.sendNotification(.{
        .kind = .alert,
        .alert = alrt,
    });

    return;
}

fn createThread(plr: *Poller) !void {
    plr.mutex.lock();
    defer plr.mutex.unlock();

    if (plr.thread != null) {
        return;
    }

    plr.thread = try std.Thread.spawn(.{}, onThread, .{plr});

    _ = try plr.ntfr.recvAck();

    return;
}

fn prepareForThreadRunning(plr: *Poller) !void {
    var cnhsVtor = try std.ArrayList(channels.ChannelNumber).initCapacity(plr.allocator, 256);
    errdefer cnhsVtor.deinit();

    var pollfdVtor = try std.ArrayList(std.posix.pollfd).initCapacity(plr.allocator, 256);
    errdefer pollfdVtor.deinit();

    var polled_map = std.AutoArrayHashMap(channels.ChannelNumber, PolledChannel).init(plr.allocator);
    errdefer polled_map.deinit();
    try polled_map.ensureTotalCapacity(256);

    plr.cnhsVtor = cnhsVtor;
    plr.pollfdVtor = pollfdVtor;
    plr.polled_map = polled_map;

    return;
}

fn onThread(plr: *Poller) void {
    plr.ntfr.sendAck(0) catch unreachable;

    plr.cnhsVtor.deinit();
    plr.polled_map.deinit();
    plr.pollfdVtor.deinit();

    return;
}

inline fn waitFinish(plr: *Poller) void {
    if (plr.thread) |t| {
        t.join();
    }
}

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

pub const engine = @import("../engine.zig");
pub const Options = engine.Options;
pub const Ampe = engine.Ampe;
pub const Sr = engine.Sr;

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

const sockets = @import("sockets.zig");
const TriggeredSkt = sockets.TriggeredSkt;

const SenderReceiver = @import("SenderReceiver.zig");

pub const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
pub const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;
