// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Distributor = @This();

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
ntfcsEnabled: bool = undefined,
thread: ?Thread = null,
plr: poller.Poller = undefined,
//
// Accessible from the thread - don't lock/unlock
//
trgrd_map: TriggeredChannelsMap = undefined,
cnmapChanged: bool = undefined,

// Summary of triggers after poller
loopTrgrs: Triggers = undefined, // Summary of triggers after poller

// Notification flow
currNtfc: Notifier.Notification = undefined,
currMsg: ?*Message = undefined,
currBhdr: BinaryHeader = undefined,

// Iteration flow
currTcopt: ?*TriggeredChannel = undefined,

unpnt: Notifier.UnpackedNotification,

pub fn ampe(dtr: *Distributor) !Ampe {
    try dtr.*.createThread();

    const result: Ampe = .{
        .ptr = dtr,
        .vtable = &.{
            .create = create,
            .destroy = destroy,
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
        .loopTrgrs = .{},
        .currNtfc = .{},
        .currMsg = null,
        .currBhdr = .{},
        .currTcopt = null,
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

        var waitEnabled: bool = true;

        dtr._sendAlert(.shutdownStarted) catch {
            waitEnabled = false;
        };

        if (waitEnabled) {
            dtr.waitFinish();
        }

        // dtr.cleanMboxes();

        dtr.pool.close();
        dtr.acns.deinit();

        dtr.ntfr.deinit();
        dtr.ntfcsEnabled = false;
    }

    //
    // All releases should be done here, not on the thread!!!
    //
    dtr.releaseToPool(&dtr.currMsg);
    dtr.plr.deinit();
    dtr.deinitTrgrdChns();
    dtr.* = undefined;
}

fn deinitTrgrdChns(dtr: *Distributor) void {
    var it = Iterator.init(&dtr.trgrd_map);

    it.reset();

    var tcopt = it.next();

    while (tcopt != null) : (tcopt = it.next()) {
        tcopt.?.acn.ctx = null;
        tcopt.?.deinit();
    }

    dtr.trgrd_map.deinit();
}

fn cleanMboxes(dtr: *Distributor) void {
    for (dtr.msgs, 0..) |_, i| {
        var mbx = dtr.msgs[i];
        var allocated = mbx.close();
        while (allocated != null) {
            const next = allocated.?.next;
            allocated.?.destroy();
            allocated = next;
        }
    }
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

fn _destroy(dtr: *Distributor, mcgimpl: ?*anyopaque) AmpeError!void {
    if (mcgimpl == null) {
        return AmpeError.InvalidAddress;
    }

    var dstr = try Gate.get(mcgimpl, .always);
    errdefer Gate.put(mcgimpl, &dstr);

    // Create Signal for destroy of
    // resources of mcg
    var dmsg = dstr.?;
    dmsg.bhdr.proto.mtype = .application;
    dmsg.bhdr.proto.role = .signal;
    dmsg.bhdr.proto.origin = .engine;
    dmsg.bhdr.proto.oob = .on;
    dmsg.bhdr.proto.more = .last;

    dmsg.bhdr.channel_number = 0;
    dmsg.bhdr.status = status.status_to_raw(.shutdown_started);

    const gt: *Gate = @alignCast(@ptrCast(mcgimpl));
    _ = dmsg.ptrToBody(Gate, gt);

    try dtr.submitMsg(dmsg, .AppSignal);

    gt.waitReleaseCompleted();
    gt.Destroy();

    return;
}

pub fn submitMsg(dtr: *Distributor, msg: *Message, hint: VC) AmpeError!void {
    dtr.mutex.lock();
    defer dtr.mutex.unlock();

    if (!dtr.ntfcsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    const oob = msg.bhdr.proto.oob;

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

    return dtr._sendAlert(alrt);
}

fn _sendAlert(dtr: *Distributor, alrt: Notifier.Alert) AmpeError!void {
    if (!dtr.ntfcsEnabled) {
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
    log.debug("loop ->", .{});
    defer log.debug("<- loop", .{});

    defer dtr.cleanMboxes();

    dtr.cnmapChanged = false;
    var it = Iterator.init(&dtr.trgrd_map);
    var withItrtr: bool = true;

    while (true) {
        dtr.loopTrgrs = .{};

        if (dtr.cnmapChanged) {
            it = Iterator.init(&dtr.trgrd_map);
            dtr.cnmapChanged = false;
            withItrtr = true;
        }

        var itropt: ?Iterator = null;
        if (withItrtr) {
            itropt = it;
        }

        dtr.loopTrgrs = dtr.plr.waitTriggers(itropt, Notifier.SEC_TIMEOUT_MS * 20) catch |err| {
            log.err("waitTriggers error {any}", .{
                err,
            });
            dtr.processWaitTriggersFailure();
            return;
        };

        const utrs = sockets.UnpackedTriggers.fromTriggers(dtr.loopTrgrs);
        _ = utrs;

        if (dtr.loopTrgrs.timeout == .on) {
            dtr.processTimeOut();
            continue;
        }

        if (dtr.loopTrgrs.notify == .on) {
            dtr.processNotify(&it) catch |err|
                switch (err) {
                    AmpeError.ShutdownStarted => {
                        return;
                    },
                    else => {
                        log.err("processNotify failed with error {any}", .{err});
                        return;
                    },
                };
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

        dtr.processMessageFromMcg() catch |err|
            switch (err) {
                AmpeError.ShutdownStarted => {
                    return;
                },
                else => {
                    log.err("processMessageFromMcg failed with error {any}", .{err});
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

fn processNotify(dtr: *Distributor, it: *Iterator) !void {
    log.debug("processNotify ->", .{});
    defer log.debug("<- processNotify", .{});

    // dtr.loopTrgrs.notify = .off;

    const notfTrChnOpt = dtr.trgrd_map.getPtr(0);
    assert(notfTrChnOpt != null);
    const notfTrChn = notfTrChnOpt.?;
    assert(notfTrChn.act.notify == .on);

    dtr.currNtfc = try notfTrChn.tskt.tryRecvNotification();
    dtr.unpnt = Notifier.UnpackedNotification.fromNotification(dtr.currNtfc);

    notfTrChn.act = .{}; // Disable obsolete processing during iteration

    if (dtr.currNtfc.kind == .alert) {
        switch (dtr.currNtfc.alert) {
            .shutdownStarted => {
                // Exit processing loop.
                // All resources will be released/destroyed
                // after waitFinish() of the thread
                return AmpeError.ShutdownStarted;
            },
            .freedMemory => {
                return dtr.addMessagesForRecv(it);
            },
        }
    }

    assert(dtr.currNtfc.kind == .message);

    return dtr.storeMessageFromMcg();
}

fn addMessagesForRecv(dtr: *Distributor, it: *Iterator) !void {
    log.debug("addMessagesForRecv ->", .{});
    defer log.debug("<- addMessagesForRecv", .{});

    it.reset();

    dtr.currTcopt = it.next();

    while (dtr.currTcopt != null) : (dtr.currTcopt = it.next()) {
        const tc = dtr.currTcopt.?;

        const trgrs = tc.act;

        if (trgrs.pool != .on) {
            continue;
        }

        const rcvmsg = dtr.pool.get(.poolOnly) catch {
            return;
        };
        errdefer dtr.pool.put(rcvmsg);

        try tc.tskt.addForRecv(rcvmsg);
        tc.act.pool = .off;
    }

    return;
}

fn storeMessageFromMcg(dtr: *Distributor) !void {
    log.debug("storeMessageFromMcg ->", .{});
    defer log.debug("<- storeMessageFromMcg", .{});

    dtr.currMsg = null;

    var currMsg: *message.Message = undefined;
    var received: bool = false;

    for (0..2) |n| {
        currMsg = dtr.msgs[n].receive(0) catch |err| {
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

    dtr.currMsg = currMsg;
    dtr.currBhdr = currMsg.bhdr;

    return;
}

fn processTriggeredChannels(dtr: *Distributor, it: *Iterator) !void {
    log.debug("processTriggeredChannels ->", .{});
    defer log.debug("<- processTriggeredChannels", .{});

    it.reset();

    dtr.currTcopt = it.next();

    while (dtr.currTcopt != null) : (dtr.currTcopt = it.next()) {
        const tc = dtr.currTcopt.?;

        const trgrs = tc.act;

        if (trgrs.off()) {
            continue;
        }

        if (trgrs.notify == .on) {
            continue;
        }
    }

    return;
}

fn processMessageFromMcg(dtr: *Distributor) !void {
    log.debug("processMessageFromMcg ->", .{});
    defer log.debug("<- processMessageFromMcg", .{});

    if (dtr.currMsg == null) {
        return;
    }

    defer dtr.releaseToPool(&dtr.currMsg);

    if (dtr.currBhdr.proto.origin == .engine) {
        return dtr.processInternal();
    }

    const hint = dtr.currNtfc.hint;

    switch (hint) {
        .HelloRequest, .HelloSignal => return dtr.sendHello(),
        .WelcomeRequest, .WelcomeSignal => return dtr.sendWelcome(),
        .ByeRequest, .ByeSignal => return dtr.sendBye(),
        .ByeResponse => return dtr.sendByeResponse(),

        .HelloResponse, .AppRequest, .AppSignal, .AppResponse => return dtr.sendToPeer(),

        else => return AmpeError.InvalidMessage,
    }

    return;
}

inline fn waitFinish(dtr: *Distributor) void {
    log.debug("waitFinish ->", .{});
    defer log.debug("<- waitFinish", .{});

    if (dtr.thread) |t| {
        t.join();
    }
}

pub fn releaseToPool(dtr: *Distributor, storedMsg: *?*Message) void {
    if (storedMsg.*) |msg| {
        dtr.pool.put(msg);
        storedMsg.* = null;
    }
    return;
}

const partial = @import("prtlDistributor.zig");
const processTimeOut = partial.processTimeOut;
const processWaitTriggersFailure = partial.processWaitTriggersFailure;
const processMarkedForDelete = partial.processMarkedForDelete;
const processInternal = partial.processInternal;

const sendToPeer = partial.sendToPeer;
const sendByeResponse = partial.sendByeResponse;
const sendBye = partial.sendBye;
const sendWelcome = partial.sendWelcome;
const sendHello = partial.sendHello;

pub const addNotificationChannel = partial.addNotificationChannel;
pub const addDumbChannel = partial.addDumbChannel;
pub const responseFailure = partial.responseFailure;
pub const markForDelete = partial.markForDelete;

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageRole = message.MessageRole;
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
const Triggers = @import("triggeredSkts.zig").Triggers;
const TriggeredSkt = @import("triggeredSkts.zig").TriggeredSkt;

const Gate = @import("Gate.zig");

const poller = @import("poller.zig");

pub const TriggeredChannel = @import("TriggeredChannel.zig");

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
