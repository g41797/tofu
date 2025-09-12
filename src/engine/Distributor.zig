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
cnmapChanged: bool = undefined,
ntfc: Notifier.Notification = undefined,
unpnt: Notifier.UnpackedNotification,
fromMcg: ?*message.Message = undefined,

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
        .unpnt = .{},
        .ntfc = .{},
        .fromMcg = null,
    };

    dtr.acns = ActiveChannels.init(dtr.allocator, 255) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer dtr.acns.deinit();

    dtr.ntfr = Notifier.init(dtr.allocator) catch {
        return AmpeError.NotificationDisabled;
    };
    errdefer dtr.ntfr.deinit();

    dtr.pool = Pool.init(dtr.allocator, dtr.options.initialPoolMsgs, dtr.options.maxPoolMsgs, dtr.alerter()) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer dtr.pool.close();

    var trgrd_map = TriggeredChannelsMap.init(dtr.allocator);
    errdefer trgrd_map.deinit();
    trgrd_map.ensureTotalCapacity(256) catch {
        return AmpeError.AllocationFailed;
    };

    dtr.trgrd_map = trgrd_map;

    try dtr.addNotificationChannel();

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

    //
    // All releases should be done here, not on the thread!!!
    //
    dtr.plr.deinit();
    dtr.trgrd_map.deinit();
    dtr.* = undefined;
}

fn create(ptr: ?*anyopaque) AmpeError!MessageChannelGroup {
    const dtr: *Distributor = @alignCast(@ptrCast(ptr));
    return dtr.*._create();
}

fn destroy(ptr: ?*anyopaque, mcgimpl: ?*anyopaque) AmpeError!void {
    const dtr: *Distributor = @alignCast(@ptrCast(ptr));
    return dtr._destroy(mcgimpl);
}

inline fn _create(dtr: *Distributor) AmpeError!MessageChannelGroup {
    dtr.maxid += 1;

    const gt = try Gate.Create(dtr, dtr.maxid);

    return gt.mcg();
}

inline fn _destroy(dtr: *Distributor, mcgimpl: ?*anyopaque) AmpeError!void {
    _ = dtr;
    const gt: *Gate = @alignCast(@ptrCast(mcgimpl));
    gt.Destroy();
    return;
}

pub fn submitMsg(dtr: *Distributor, msg: *Message, hint: VC, oob: message.Oob) AmpeError!void {
    dtr.mutex.lock();
    defer dtr.mutex.unlock();

    if (!dtr.ntfsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    dtr.msgs[@intFromEnum(oob)].send(msg) catch {
        return AmpeError.NotAllowed;
    };

    try dtr.ntfr.sendNotification(.{
        .kind = .message,
        .hint = hint,
        .oob = oob,
    });

    return;
}

pub fn send_alert(ptr: ?*anyopaque, alert: Notifier.Alert) AmpeError!void {
    const dtr: *Distributor = @alignCast(@ptrCast(ptr));
    return dtr.sendAlert(alert);
}

pub fn sendAlert(dtr: *Distributor, alrt: Notifier.Alert) AmpeError!void {
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
    loop(dtr);
    return;
}

fn loop(dtr: *Distributor) void {
    dtr.cnmapChanged = false;
    var it = Iterator.init(&dtr.trgrd_map);
    var withItrtr: bool = true;

    while (true) {
        if (dtr.cnmapChanged) {
            it = Iterator.init(&dtr.trgrd_map);
            dtr.cnmapChanged = false;
            withItrtr = true;
        }

        var itropt: ?Iterator = null;
        if (withItrtr) {
            itropt = it;
        }

        const trgrs = dtr.plr.waitTriggers(itropt, Notifier.SEC_TIMEOUT_MS * 20) catch |err| {
            log.err("waitTriggers error {any}", .{
                err,
            });
            dtr.processWaitTriggersFailure();
            return;
        };

        const utrs = sockets.UnpackedTriggers.fromTriggers(trgrs);
        _ = utrs;

        if (trgrs.timeout == .on) {
            dtr.processTimeOut();
            continue;
        }

        dtr.processTriggeredChannels(&it) catch |err|
            switch (err) {
                AmpeError.ShutdownStarted => {
                    return;
                },
                else => {
                    log.err("processTriggeredChannels failed with error {any}", .{err});
                    return;
                },
            };

        dtr.cnmapChanged = dtr.processMarkedForDelete() catch |err| {
            log.err("processMarkedForDelete failed with error {any}", .{err});
            return;
        };
    }

    return;
}

fn processMarkedForDelete(dtr: *Distributor) !bool {
    _ = dtr;
    return false;
}

fn processTriggeredChannels(dtr: *Distributor, it: *Iterator) !void {
    it.reset();

    var tcptr = it.next();
    var indx: usize = 0;

    while (tcptr != null) : (indx += 1) {
        const tc = tcptr.?;
        tcptr = it.next();

        const trgrs = tc.act;

        if (trgrs.off()) {
            continue;
        }

        if (trgrs.notify == .on) {
            assert(indx == 0);
            try dtr.processNotify(tc);
            continue;
        }
    }

    return AmpeError.ShutdownStarted;
}

fn processNotify(dtr: *Distributor, tc: *TriggeredChannel) !void {
    dtr.ntfc = try tc.tskt.tryRecvNotification();
    dtr.unpnt = Notifier.UnpackedNotification.fromNotification(dtr.ntfc);

    if (dtr.ntfc.kind == .alert) {
        switch (dtr.ntfc.alert) {
            .shutdownStarted => {
                return AmpeError.ShutdownStarted;
            },
            else => {
                // Alert from the pool just interrupts poller.
                // During loop engine checks channels waiting for free messages
                return;
            },
        }
    }

    assert(dtr.ntfc.kind == .message);

    return dtr.processMcgMessage();
}

fn processMcgMessage(dtr: *Distributor) !void {
    dtr.fromMcg = null;

    var fromMcg: *message.Message = undefined;
    var received: bool = false;

    for (0..2) |n| {
        fromMcg = dtr.msgs[n].receive(0) catch |err| {
            switch (err) {
                error.Timeout, error.Interrupted => {
                    continue;
                },
                else => {
                    return AmpeError.ShutdownStarted;
                },
            }
        };

        received = true;
        break;
    }

    if (!received) {
        return;
    }

    dtr.fromMcg = fromMcg;
    defer Message.DestroySendMsg(&dtr.fromMcg);

    return;
}

fn processTimeOut(dtr: *Distributor) void {
    // 2DO - Add processing
    _ = dtr;
    return;
}

fn processWaitTriggersFailure(dtr: *Distributor) void {
    // 2DO - Add failure processing
    _ = dtr;
    return;
}

inline fn waitFinish(dtr: *Distributor) void {
    if (dtr.thread) |t| {
        t.join();
    }
}

fn addNotificationChannel(dtr: *Distributor) !void {
    const nSkt = dtr.ntfr.receiver;

    const ntcn: TriggeredChannel = .{
        .acn = .{
            .chn = 0,
            .mid = 0,
            .ctx = null,
        },
        .tskt = .{
            .notification = sockets.NotificationSkt.init(nSkt),
        },
        .exp = sockets.TriggersOff,
        .act = sockets.TriggersOff,
    };

    dtr.trgrd_map.put(ntcn.acn.chn, ntcn) catch {
        return AmpeError.AllocationFailed;
    };

    dtr.ntfsEnabled = true;
    dtr.cnmapChanged = false;
    return;
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
const log = std.log;
const assert = std.debug.assert;

// 2DO  Add processing options for Pool as part of init()
