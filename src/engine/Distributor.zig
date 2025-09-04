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

    dtr.pool = Pool.init(dtr.allocator, null, null, dtr.alerter()) catch {
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

fn create(ptr: ?*anyopaque) !MessageChannelGroup {
    const dtr: *Distributor = @alignCast(@ptrCast(ptr));
    return dtr.*._create();
}

fn destroy(ptr: ?*anyopaque, mcgimpl: ?*anyopaque) !void {
    const dtr: *Distributor = @alignCast(@ptrCast(ptr));
    return dtr._destroy(mcgimpl);
}

inline fn _create(dtr: *Distributor) !MessageChannelGroup {
    dtr.maxid += 1;

    const gt = try Gate.Create(dtr, dtr.maxid);

    return gt.mcg();
}

inline fn _destroy(dtr: *Distributor, mcgimpl: ?*anyopaque) !void {
    _ = dtr;
    const gt: *Gate = @alignCast(@ptrCast(mcgimpl));
    gt.Destroy();
    return;
}

pub fn submitMsg(dtr: *Distributor, msg: *Message, hint: VC, oob: message.Oob) !void {
    dtr.mutex.lock();
    defer dtr.mutex.unlock();

    if (!dtr.ntfsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    try dtr.msgs[@intFromEnum(oob)].send(msg);

    try dtr.ntfr.sendNotification(.{
        .kind = .message,
        .hint = hint,
        .oob = oob,
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

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageMode = message.MessageMode;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = @import("../message.zig").TextHeaderIterator;
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageID = message.MessageID;
const VC = message.ValidCombination;

const engine = @import("../engine.zig");
const Options = engine.Options;
const Ampe = engine.Ampe;
const MessageChannelGroup = engine.MessageChannelGroup;

const status = @import("../status.zig");
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const Notifier = @import("Notifier.zig");

const Pool = @import("Pool.zig");

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

const sockets = @import("sockets.zig");
const TriggeredSkt = sockets.TriggeredSkt;

const Gate = @import("Gate.zig");

const poller = @import("poller.zig");

const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;

// 2DO  Add processing options for Pool as part of init()
