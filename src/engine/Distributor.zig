// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Distributor = @This();

pub const TriggeredChannel = struct {
    acn: channels.ActiveChannel = undefined,
    tskt: TriggeredSkt = undefined,
    exp: sockets.Triggers = undefined,
    act: sockets.Triggers = undefined,
};

pub const TriggeredChannelsMap = std.AutoArrayHashMap(channels.ChannelNumber, TriggeredChannel);

pub const Iterator = struct {
    itrtr: ?TriggeredChannelsMap.Iterator = null,

    pub fn init(tcm: *TriggeredChannelsMap) Iterator {
        return .{
            .itrtr = tcm.iterator(),
        };
    }

    pub fn next(itr: *Iterator) ?*TriggeredChannel {
        if (itr.itrtr != null) {
            const entry = itr.itrtr.?.next();
            if (entry) |entr| {
                return entr.value_ptr;
            }
        }
        return null;
    }

    pub fn reset(itr: *Iterator) void {
        if (itr.itrtr != null) {
            itr.itrtr.?.reset();
        }
        return;
    }
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
plr: poller.Poller = undefined,

// Accessible from the thread - don't lock/unlock
trgrd_map: TriggeredChannelsMap = undefined,

pub fn ampe(dtr: *Distributor) !Ampe {
    try dtr.*.createThread();

    const result: Ampe = .{
        .ptr = dtr,
        .vtable = &.{
            .acquire = create,
            .release = destroy,
        },
    };

    return result;
}

fn alerter(dtr: *Distributor) Notifier.Alerter {
    const result: Notifier.Alerter = .{
        .ptr = dtr,
        .func = send_alert,
    };
    return result;
}

pub fn Create(gpa: Allocator, options: Options) AmpeError!*Distributor {
    const dtr: *Distributor = gpa.create(Distributor) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer gpa.destroy(dtr);

    // add here comptime creation based on os
    const plru: poller.Poller = .{
        .poll = poller.Poll.init(gpa) catch {
            return AmpeError.AllocationFailed;
        },
    };

    dtr.* = .{
        .mutex = .{},
        .allocator = gpa,
        .options = options,
        .msgs = .{ .{}, .{} },
        .maxid = 0,
        .plr = plru,
    };

    dtr.acns = ActiveChannels.init(dtr.allocator, 255) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer dtr.acns.deinit();

    dtr.ntfr = Notifier.init(dtr.allocator) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer dtr.ntfr.deinit();

    dtr.pool = Pool.init(dtr.allocator, dtr.alerter()) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer dtr.pool.close();

    var trgrd_map = TriggeredChannelsMap.init(dtr.allocator);
    errdefer trgrd_map.deinit();
    trgrd_map.ensureTotalCapacity(256) catch {
        return AmpeError.AllocationFailed;
    };

    dtr.trgrd_map = trgrd_map;
    return dtr;
}

pub fn Destroy(dtr: *Distributor) void {
    const gpa = dtr.allocator;
    defer gpa.destroy(dtr);
    {
        dtr.mutex.lock();
        defer dtr.mutex.unlock();

        for (dtr.msgs, 0..) |_, i| {
            var mbx = dtr.msgs[i];
            var allocated = mbx.close();
            while (allocated != null) {
                const next = allocated.?.next;
                allocated.?.destroy();
                allocated = next;
            }
        }

        dtr.pool.close();
        dtr.acns.deinit();

        dtr.ntfr.deinit();
        dtr.ntfsEnabled = false;
    }

    dtr.waitFinish();

    dtr.plr.deinit();

    dtr.* = undefined;
}

fn create(ptr: ?*anyopaque) !Fdmp {
    const dtr: *Distributor = @alignCast(@ptrCast(ptr));
    return dtr.*._create();
}

fn destroy(ptr: ?*anyopaque, fdmpimpl: ?*anyopaque) !void {
    const dtr: *Distributor = @alignCast(@ptrCast(ptr));
    return dtr._destroy(fdmpimpl);
}

inline fn _create(dtr: *Distributor) !Fdmp {
    dtr.maxid += 1;

    const sr = try SenderReceiver.Create(dtr, dtr.maxid);

    return sr.fdmp();
}

inline fn _destroy(dtr: *Distributor, fdmpimpl: ?*anyopaque) !void {
    _ = dtr;
    const srs: *SenderReceiver = @alignCast(@ptrCast(fdmpimpl));
    srs.Destroy();
    return;
}

pub fn submitMsg(dtr: *Distributor, msg: *Message, hint: VC, priority: Notifier.MessagePriority) !void {
    dtr.mutex.lock();
    defer dtr.mutex.unlock();

    if (!dtr.ntfsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    try dtr.msgs[@intFromEnum(priority)].send(msg);

    try dtr.ntfr.sendNotification(.{
        .kind = .message,
        .hint = hint,
        .priority = priority,
    });

    return;
}

pub fn send_alert(ptr: ?*anyopaque, alert: Notifier.Alert) !void {
    const dtr: *Distributor = @alignCast(@ptrCast(ptr));
    return dtr.sendAlert(alert);
}

pub fn sendAlert(dtr: *Distributor, alrt: Notifier.Alert) !void {
    dtr.mutex.lock();
    defer dtr.mutex.unlock();

    if (!dtr.ntfsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    try dtr.ntfr.sendNotification(.{
        .kind = .alert,
        .alert = alrt,
    });

    return;
}

fn createThread(dtr: *Distributor) !void {
    dtr.mutex.lock();
    defer dtr.mutex.unlock();

    if (dtr.thread != null) {
        return;
    }

    dtr.thread = try std.Thread.spawn(.{}, onThread, .{dtr});

    _ = try dtr.ntfr.recvAck();

    return;
}

fn onThread(dtr: *Distributor) void {
    dtr.ntfr.sendAck(0) catch unreachable;

    dtr.trgrd_map.deinit();

    return;
}

inline fn waitFinish(dtr: *Distributor) void {
    if (dtr.thread) |t| {
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
pub const TextHeaderIterator = @import("../message.zig").TextHeaderIterator;
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const VC = message.ValidCombination;

pub const engine = @import("../engine.zig");
pub const Options = engine.Options;
pub const Ampe = engine.Ampe;
pub const Fdmp = engine.Fdmp;

pub const status = @import("../status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const Notifier = @import("Notifier.zig");

const Pool = @import("Pool.zig");

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

const sockets = @import("sockets.zig");
const TriggeredSkt = sockets.TriggeredSkt;

const SenderReceiver = @import("SenderReceiver.zig");

const poller = @import("poller.zig");

pub const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
pub const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;

// 2DO  Add processing options for Pool as part of init()
