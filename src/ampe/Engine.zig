// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Engine = @This();

pub fn ampe(eng: *Engine) !Ampe {
    try eng.*.createThread();

    const result: Ampe = .{
        .ptr = eng,
        .vtable = &.{
            .get = get,
            .put = put,
            .create = create,
            .destroy = destroy,
        },
    };

    return result;
}

mutex: Mutex = undefined,
allocator: Allocator = undefined,
options: tofu.Options = undefined,
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

m4delCnt: usize = undefined,

allChnN: std.ArrayList(message.ChannelNumber) = undefined,

pub fn Create(gpa: Allocator, options: Options) AmpeError!*Engine {
    const eng: *Engine = gpa.create(Engine) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer gpa.destroy(eng);

    // 2DO add here comptime creation based on os
    const plru: poller.Poller = .{
        .poll = poller.Poll.init(gpa) catch {
            return AmpeError.AllocationFailed;
        },
    };

    eng.* = .{
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
        .m4delCnt = 0,
    };

    eng.acns = ActiveChannels.init(eng.allocator, 255) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer eng.acns.deinit();

    eng.ntfr = Notifier.init(eng.allocator) catch {
        return AmpeError.NotificationDisabled;
    };
    errdefer eng.ntfr.deinit();

    eng.pool = Pool.init(eng.allocator, eng.options.initialPoolMsgs, eng.options.maxPoolMsgs, eng.alerter()) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer eng.pool.close();

    var trgrd_map = TriggeredChannelsMap.init(eng.allocator);
    errdefer trgrd_map.deinit();
    trgrd_map.ensureTotalCapacity(256) catch {
        return AmpeError.AllocationFailed;
    };

    eng.trgrd_map = trgrd_map;

    eng.allChnN = std.ArrayList(message.ChannelNumber).initCapacity(eng.allocator, 256) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer eng.allChnN.deinit();

    try TriggeredChannel.createNotificationChannel(eng);

    return eng;
}

pub fn Destroy(eng: *Engine) void {
    const gpa = eng.allocator;
    defer gpa.destroy(eng);
    {
        eng.mutex.lock();
        defer eng.mutex.unlock();

        var waitEnabled: bool = true;

        eng._sendAlert(.shutdownStarted) catch {
            waitEnabled = false;
        };

        if (waitEnabled) {
            eng.waitFinish();
        }

        // eng.cleanMboxes();

        eng.pool.close();
        eng.acns.deinit();
        eng.allChnN.deinit();
        eng.ntfr.deinit();
        eng.ntfcsEnabled = false;
    }

    //
    // All releases should be done here, not on the thread!!!
    //
    eng.releaseToPool(&eng.currMsg);
    eng.plr.deinit();
    eng.deinitTrgrdChns();
    eng.* = undefined;
}

fn deinitTrgrdChns(eng: *Engine) void {
    var it = Iterator.init(&eng.trgrd_map);

    it.reset();

    var tcopt = it.next();

    while (tcopt != null) : (tcopt = it.next()) {
        tcopt.?.acn.ctx = null;
        tcopt.?.deinit();
    }

    eng.trgrd_map.deinit();
}

fn cleanMboxes(eng: *Engine) void {
    for (eng.msgs, 0..) |_, i| {
        var mbx = eng.msgs[i];
        var allocated = mbx.close();
        while (allocated != null) {
            const next = allocated.?.next;
            allocated.?.destroy();
            allocated = next;
        }
    }
}

fn get(ptr: ?*anyopaque, strategy: tofu.AllocationStrategy) AmpeError!?*Message {
    const eng: *Engine = @alignCast(@ptrCast(ptr));
    return eng._get(strategy);
}

fn _get(eng: *Engine, strategy: tofu.AllocationStrategy) AmpeError!?*Message {
    const msg = eng.pool.get(strategy) catch |err| {
        switch (err) {
            AmpeError.PoolEmpty => {
                return null;
            },
            else => {
                return err;
            },
        }
    };
    return msg;
}

fn put(ptr: ?*anyopaque, msg: *?*Message) void {
    const eng: *Engine = @alignCast(@ptrCast(ptr));
    return eng._put(msg);
}

fn _put(eng: *Engine, msg: *?*Message) void {
    const msgopt = msg.*;
    if (msgopt) |m| {
        eng.pool.put(m);
    }
    msg.* = null;

    return;
}

fn create(ptr: ?*anyopaque) AmpeError!Channels {
    const eng: *Engine = @alignCast(@ptrCast(ptr));
    return eng.*._create();
}

fn destroy(ptr: ?*anyopaque, chnlsimpl: ?*anyopaque) AmpeError!void {
    const eng: *Engine = @alignCast(@ptrCast(ptr));
    return eng._destroy(chnlsimpl);
}

inline fn _create(eng: *Engine) AmpeError!Channels {
    eng.maxid += 1;

    const grp = try MchnGroup.Create(eng, eng.maxid);

    return grp.chnls();
}

fn _destroy(eng: *Engine, chnlsimpl: ?*anyopaque) AmpeError!void {
    if (chnlsimpl == null) {
        return AmpeError.InvalidAddress;
    }

    var dstr = try eng._get(.always);
    errdefer eng._put(&dstr);

    // Create Signal for destroy of
    // resources of chnls
    var dmsg = dstr.?;
    dmsg.bhdr.proto.mtype = .regular;
    dmsg.bhdr.proto.role = .signal;
    dmsg.bhdr.proto.origin = .engine;
    dmsg.bhdr.proto.oob = .on;
    dmsg.bhdr.proto.more = .last;

    dmsg.bhdr.channel_number = 0;
    dmsg.bhdr.status = status.status_to_raw(.shutdown_started);

    const grp: *MchnGroup = @alignCast(@ptrCast(chnlsimpl));
    _ = dmsg.ptrToBody(MchnGroup, grp);

    try eng.submitMsg(dmsg, .AppSignal);

    grp.waitReleaseCompleted();
    grp.Destroy();

    return;
}

pub fn submitMsg(eng: *Engine, msg: *Message, hint: VC) AmpeError!void {
    eng.mutex.lock();
    defer eng.mutex.unlock();

    if (!eng.ntfcsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    const oob = msg.bhdr.proto.oob;

    eng.msgs[@intFromEnum(oob)].send(msg) catch {
        return AmpeError.NotAllowed;
    };

    try eng.ntfr.sendNotification(.{
        .kind = .message,
        .hint = hint,
        .oob = oob,
    });

    return;
}

pub fn send_alert(ptr: ?*anyopaque, alert: Notifier.Alert) AmpeError!void {
    const eng: *Engine = @alignCast(@ptrCast(ptr));
    return eng.sendAlert(alert);
}

pub fn sendAlert(eng: *Engine, alrt: Notifier.Alert) AmpeError!void {
    eng.mutex.lock();
    defer eng.mutex.unlock();

    return eng._sendAlert(alrt);
}

fn _sendAlert(eng: *Engine, alrt: Notifier.Alert) AmpeError!void {
    if (!eng.ntfcsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    try eng.ntfr.sendNotification(.{
        .kind = .alert,
        .alert = alrt,
    });

    return;
}

fn createThread(eng: *Engine) !void {
    eng.mutex.lock();
    defer eng.mutex.unlock();

    if (eng.thread != null) {
        return;
    }

    eng.thread = try std.Thread.spawn(.{}, onThread, .{eng});

    _ = try eng.ntfr.recvAck();

    return;
}

fn onThread(eng: *Engine) void {
    eng.ntfr.sendAck(0) catch unreachable;
    loop(eng);
    return;
}

fn loop(eng: *Engine) void {
    log.debug("loop ->", .{});
    defer log.debug("<- loop", .{});

    defer eng.cleanMboxes();

    eng.cnmapChanged = false;
    var it = Iterator.init(&eng.trgrd_map);
    var withItrtr: bool = true;

    while (true) {
        eng.m4delCnt = 0;
        eng.loopTrgrs = .{};

        if (eng.cnmapChanged) {
            it = Iterator.init(&eng.trgrd_map);
            eng.cnmapChanged = false;
            withItrtr = true;
        }

        var itropt: ?Iterator = null;
        if (withItrtr) {
            itropt = it;
        }

        eng.loopTrgrs = eng.plr.waitTriggers(itropt, Notifier.SEC_TIMEOUT_MS * 20) catch |err| {
            log.err("waitTriggers error {any}", .{
                err,
            });
            eng.processWaitTriggersFailure();
            return;
        };

        const utrs = sockets.UnpackedTriggers.fromTriggers(eng.loopTrgrs);
        _ = utrs;

        if (eng.loopTrgrs.timeout == .on) {
            eng.processTimeOut();
            continue;
        }

        if (eng.loopTrgrs.notify == .on) {
            eng.processNotify() catch |err|
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

        eng.processTriggeredChannels(&it) catch |err|
            switch (err) {
                AmpeError.ShutdownStarted => {
                    return;
                },
                else => {
                    log.err("processTriggeredChannels failed with error {any}", .{err});
                    return;
                },
            };

        eng.processMessageFromChannels() catch |err|
            switch (err) {
                AmpeError.ShutdownStarted => {
                    return;
                },
                else => {
                    log.debug("processMessageFromChannels returned error {any}", .{err});
                },
            };

        const wasRemoved = eng.processMarkedForDelete() catch |err| {
            log.err("processMarkedForDelete failed with error {any}", .{err});
            return;
        };

        if (wasRemoved) {
            eng.cnmapChanged = true;
        }
    }

    return;
}

fn processNotify(eng: *Engine) !void {
    log.debug("processNotify ->", .{});
    defer log.debug("<- processNotify", .{});

    // eng.loopTrgrs.notify = .off;

    const notfTrChnOpt = eng.trgrd_map.getPtr(0);
    assert(notfTrChnOpt != null);
    const notfTrChn = notfTrChnOpt.?;
    assert(notfTrChn.act.notify == .on);

    eng.currNtfc = try notfTrChn.tskt.tryRecvNotification();
    eng.unpnt = Notifier.UnpackedNotification.fromNotification(eng.currNtfc);

    notfTrChn.act = .{}; // Disable obsolete processing during iteration

    if (eng.currNtfc.kind == .alert) {
        switch (eng.currNtfc.alert) {
            .shutdownStarted => {
                // Exit processing loop.
                // All resources will be released/destroyed
                // after waitFinish() of the thread
                return AmpeError.ShutdownStarted;
            },
            .freedMemory => {
                return; // Adding message from pool will be handled in processTriggeredChannels
                // return eng.addMessagesForRecv(it);
            },
        }
    }

    assert(eng.currNtfc.kind == .message);

    return eng.storeMessageFromChannels();
}

fn storeMessageFromChannels(eng: *Engine) !void {
    log.debug("storeMessageFromChannels ->", .{});
    defer log.debug("<- storeMessageFromChannels", .{});

    eng.currMsg = null;

    var currMsg: *message.Message = undefined;
    var received: bool = false;

    for (0..2) |n| {
        currMsg = eng.msgs[n].receive(0) catch |err| {
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

    eng.currMsg = currMsg;
    eng.currBhdr = currMsg.bhdr;

    return;
}

fn processTriggeredChannels(eng: *Engine, it: *Iterator) !void {
    log.debug("processTriggeredChannels ->", .{});
    defer log.debug("<- processTriggeredChannels", .{});

    it.reset();

    eng.currTcopt = it.next();

    trcIter: while (eng.currTcopt != null) : (eng.currTcopt = it.next()) {
        const tc = eng.currTcopt.?;

        const trgrs = tc.act;

        const utrgs = sockets.UnpackedTriggers.fromTriggers(trgrs);
        _ = utrgs;

        if (trgrs.off()) {
            continue;
        }

        if (trgrs.notify == .on) {
            continue;
        }

        if (trgrs.err == .on) {
            tc.markForDelete(trgrs.toStatus());
            continue;
        }

        if (trgrs.connect == .on) {
            _ = tc.tskt.tryConnect() catch {
                tc.markForDelete(.connect_failed);
            };
            continue;
        }

        if (trgrs.pool == .on) {
            while (true) {
                const rcvmsg = eng.pool.get(.poolOnly) catch {
                    break;
                };

                tc.tskt.addForRecv(rcvmsg) catch |err| {
                    eng.pool.put(rcvmsg);
                    var reason: AmpeStatus = .recv_failed;
                    if (err == AmpeError.NotAllowed) {
                        reason = .not_allowed;
                    }
                    tc.markForDelete(reason);
                    continue :trcIter;
                };
                tc.act.pool = .off;
                break;
            }
        }

        if (trgrs.accept == .on) {
            TriggeredChannel.createIoServerChannel(eng, tc) catch |err| {
                log.info("createIoServerChannel for connected client failed with error {s}", .{@errorName(err)});
            };
            continue;
        }

        if (trgrs.send == .on) {
            var wereSend: message.MessageQueue = tc.tskt.trySend() catch {
                tc.markForDelete(.send_failed);
                continue;
            };
            var next: ?*Message = wereSend.dequeue();
            while (next != null) {
                eng.pool.put(next.?);
                next = wereSend.dequeue();
            }
        }

        if (trgrs.recv == .on) {
            var wereRecv: message.MessageQueue = tc.tskt.tryRecv() catch {
                tc.markForDelete(.recv_failed);
                continue;
            };
            var next: ?*Message = wereRecv.dequeue();
            while (next != null) {
                var byeResponseReceived: bool = false;
                if ((next.?.bhdr.proto.mtype == .bye) and (next.?.bhdr.proto.role == .response)) {
                    byeResponseReceived = true;
                }
                tc.sendToCtx(&next);
                if (byeResponseReceived) {
                    tc.markForDelete(.channel_closed);
                }
                next = wereRecv.dequeue();
            }
        }

        break;
    }

    return;
}

fn processMessageFromChannels(eng: *Engine) !void {
    log.debug("processMessageFromChannels ->", .{});
    defer log.debug("<- processMessageFromChannels", .{});

    if (eng.currMsg == null) {
        return;
    }

    defer eng.releaseToPool(&eng.currMsg);

    if (eng.currBhdr.proto.origin == .engine) {
        return eng.processInternal();
    }

    const hint = eng.currNtfc.hint;

    switch (hint) {
        .HelloRequest, .HelloSignal => return eng.sendHello(),
        .WelcomeRequest, .WelcomeSignal => return eng.sendWelcome(),
        .ByeRequest, .ByeSignal => return eng.sendBye(),
        .ByeResponse => return eng.sendByeResponse(),

        .HelloResponse, .AppRequest, .AppSignal, .AppResponse => return eng.sendToPeer(),

        else => return AmpeError.InvalidMessage,
    }

    return;
}

inline fn waitFinish(eng: *Engine) void {
    log.debug("waitFinish ->", .{});
    defer log.debug("<- waitFinish", .{});

    if (eng.thread) |t| {
        t.join();
    }
}

pub fn releaseToPool(eng: *Engine, storedMsg: *?*Message) void {
    if (storedMsg.*) |msg| {
        eng.pool.put(msg);
        storedMsg.* = null;
    }
    return;
}

pub fn buildStatusSignal(eng: *Engine, stat: AmpeStatus) *Message {
    var ret = eng.pool.get(.always) catch unreachable;
    ret.bhdr.status = status.status_to_raw(stat);
    ret.bhdr.proto.mtype = .regular;
    ret.bhdr.proto.origin = .engine;
    ret.bhdr.proto.role = .signal;
    return ret;
}

fn alerter(eng: *Engine) Notifier.Alerter {
    const result: Notifier.Alerter = .{
        .ptr = eng,
        .func = send_alert,
    };
    return result;
}

pub fn addChannel(eng: *Engine, tchn: TriggeredChannel) AmpeError!void {
    eng.trgrd_map.put(tchn.acn.chn, tchn) catch {
        return AmpeError.AllocationFailed;
    };
    eng.cnmapChanged = true;
    return;
}

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

fn addMessagesForRecv(eng: *Engine, it: *Iterator) !void {
    log.debug("addMessagesForRecv ->", .{});
    defer log.debug("<- addMessagesForRecv", .{});

    it.reset();

    eng.currTcopt = it.next();

    while (eng.currTcopt != null) : (eng.currTcopt = it.next()) {
        const tc = eng.currTcopt.?;

        const trgrs = tc.act;

        if (trgrs.pool != .on) {
            continue;
        }

        const rcvmsg = eng.pool.get(.poolOnly) catch {
            return;
        };
        errdefer eng.pool.put(rcvmsg);

        try tc.tskt.addForRecv(rcvmsg);
        tc.act.pool = .off;
    }

    return;
}

const partial = @import("prtlEngine.zig");
const processTimeOut = partial.processTimeOut;
const processWaitTriggersFailure = partial.processWaitTriggersFailure;
const processMarkedForDelete = partial.processMarkedForDelete;
const processInternal = partial.processInternal;

pub const sendToPeer = partial.sendToPeer;
const sendByeResponse = partial.sendByeResponse;
const sendBye = partial.sendBye;
const sendWelcome = partial.sendWelcome;
const sendHello = partial.sendHello;

pub const addDumbChannel = partial.addDumbChannel;
pub const responseFailure = partial.responseFailure;
pub const markForDelete = partial.markForDelete;
pub const clearForDelete = partial.clearForDelete;

const tofu = @import("../tofu.zig");
const message = tofu.message;
const MessageType = message.MessageType;
const MessageRole = message.MessageRole;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = message.TextHeaderIterator;
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageID = message.MessageID;
const VC = message.ValidCombination;

const Options = tofu.Options;
const Ampe = tofu.Ampe;
const Channels = tofu.Channels;

const status = tofu.status;
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const internal = tofu.@"internal usage";
const Notifier = internal.Notifier;

const Pool = internal.Pool;

const channels = internal.channels;
const ActiveChannels = channels.ActiveChannels;

const sockets = internal.sockets;
const Triggers = internal.triggeredSkts.Triggers;
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;

const MchnGroup = internal.MchnGroup;

const poller = internal.poller;

const TriggeredChannel = internal.TriggeredChannel;

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
