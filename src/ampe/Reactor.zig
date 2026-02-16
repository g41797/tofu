// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Reactor = @This();

pub fn ampe(rtr: *Reactor) !Ampe {
    const result: Ampe = .{
        .ptr = rtr,
        .vtable = &.{
            .get = get,
            .put = put,
            .create = createCG,
            .destroy = destroyCG,
            .getAllocator = getAllocator,
        },
    };

    return result;
}

fn alerter(rtr: *Reactor) Notifier.Alerter {
    const result: Notifier.Alerter = .{
        .ptr = rtr,
        .func = send_alert,
    };
    return result;
}

sndMtx: Mutex = undefined,
crtMtx: Mutex = undefined,
shtdwnStrt: bool = undefined,
allocator: Allocator = undefined,
options: tofu.Options = undefined,
msgs: [2]MSGMailBox = undefined,
ntfr: Notifier = undefined,
pool: Pool = undefined,
acns: ActiveChannels = undefined,
maxid: u32 = undefined,
ntfcsEnabled: bool = undefined,
thread: ?Thread = null,
cmpl: Semaphore = undefined,
plr: poller.Poller = undefined,
//
// Accessible from the thread - don't lock/unlock
//
trgrd_map: TriggeredChannelsMap = undefined,
cnmapChanged: bool = undefined,
chnlsGroup_map: ChannelsGroupMap = undefined,

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

pub fn create(gpa: Allocator, options: Options) AmpeError!*Reactor {
    try initPlatform();

    const rtr: *Reactor = gpa.create(Reactor) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer {
        deinitPlatform();
        gpa.destroy(rtr);
    }

    // 2DO add here comptime creation based on os
    const plru: poller.Poller = .{
        .poll = poller.Poll.init(gpa) catch {
            return AmpeError.AllocationFailed;
        },
    };

    rtr.* = .{
        .sndMtx = .{},
        .crtMtx = .{},
        .shtdwnStrt = false,
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
        .cmpl = Semaphore{},
    };

    rtr.acns = ActiveChannels.init(rtr.allocator, 1024) catch { // was 255
        return AmpeError.AllocationFailed;
    };
    errdefer rtr.acns.deinit();

    rtr.ntfr = Notifier.init(rtr.allocator) catch {
        return AmpeError.NotificationDisabled;
    };
    errdefer rtr.ntfr.deinit();

    rtr.pool = Pool.init(rtr.allocator, rtr.options.initialPoolMsgs, rtr.options.maxPoolMsgs, rtr.alerter()) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer rtr.pool.close();

    var trgrd_map = TriggeredChannelsMap.init(rtr.allocator);
    errdefer trgrd_map.deinit();
    trgrd_map.ensureTotalCapacity(256) catch {
        return AmpeError.AllocationFailed;
    };

    rtr.trgrd_map = trgrd_map;

    var chnlsGroup_map = ChannelsGroupMap.init(rtr.allocator);
    errdefer chnlsGroup_map.deinit();
    chnlsGroup_map.ensureTotalCapacity(256) catch {
        return AmpeError.AllocationFailed;
    };

    rtr.chnlsGroup_map = chnlsGroup_map;

    rtr.allChnN = std.ArrayList(message.ChannelNumber).initCapacity(rtr.allocator, 256) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer rtr.allChnN.deinit(rtr.allocator);

    try rtr.createNotificationChannel();

    rtr.createThread() catch |err| {
        log.err("create engine thread error {s}", .{@errorName(err)});
        return AmpeError.AllocationFailed;
    };

    return rtr;
}

pub fn destroy(rtr: *Reactor) void {
    const gpa = rtr.allocator;
    defer gpa.destroy(rtr);
    {
        rtr.crtMtx.lock();
        defer rtr.crtMtx.unlock();

        log.warn("!!! engine will be destroyed !!!", .{});

        var waitEnabled: bool = true;

        rtr._sendAlert(.shutdownStarted) catch {
            waitEnabled = false;
        };

        if (waitEnabled) {
            rtr.waitFinish();
        }

        rtr.pool.close();
        rtr.acns.deinit();
        rtr.allChnN.deinit(rtr.allocator);
        rtr.ntfr.deinit();
        rtr.ntfcsEnabled = false;
    }

    //
    // All releases should be done here, not on the thread!!!
    //
    rtr.releaseToPool(&rtr.currMsg);
    rtr.plr.deinit();
    rtr.deinitTrgrdChns();

    deinitPlatform();

    rtr.* = undefined;
}

fn get(ptr: ?*anyopaque, strategy: tofu.AllocationStrategy) AmpeError!?*Message {
    const rtr: *Reactor = @ptrCast(@alignCast(ptr));
    return rtr._get(strategy);
}

fn _get(rtr: *Reactor, strategy: tofu.AllocationStrategy) AmpeError!?*Message {
    const msg = rtr.pool.get(strategy) catch |err| {
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
    const rtr: *Reactor = @ptrCast(@alignCast(ptr));
    return rtr._put(msg);
}

fn _put(rtr: *Reactor, msg: *?*Message) void {
    const msgopt = msg.*;
    if (msgopt) |m| {
        rtr.pool.put(m);
    }
    msg.* = null;

    return;
}

fn createCG(ptr: ?*anyopaque) AmpeError!ChannelGroup {
    const rtr: *Reactor = @ptrCast(@alignCast(ptr));
    return rtr.*._create();
}

fn destroyCG(ptr: ?*anyopaque, chnlsimpl: ?*anyopaque) AmpeError!void {
    log.warn("!!! channel group will be destroyed !!!", .{});
    const rtr: *Reactor = @ptrCast(@alignCast(ptr));
    return rtr._destroy(chnlsimpl);
}

inline fn _create(rtr: *Reactor) AmpeError!ChannelGroup {
    rtr.crtMtx.lock();
    defer rtr.crtMtx.unlock();

    if (rtr.shtdwnStrt) {
        return AmpeError.ShutdownStarted;
    }

    const grp = try MchnGroup.create(rtr, next_gid());

    const channelGroup: ChannelGroup = grp.chnls();

    try rtr.*.send_create(channelGroup.ptr);

    return channelGroup;
}

inline fn send_create(rtr: *Reactor, chnlsimpl: ?*anyopaque) AmpeError!void {
    const grp: *MchnGroup = @ptrCast(@alignCast(chnlsimpl));

    grp.resetCmdCompleted();

    try send_channels_cmd(rtr, chnlsimpl, .success);
    return;
}

inline fn _destroy(rtr: *Reactor, chnlsimpl: ?*anyopaque) AmpeError!void {
    rtr.crtMtx.lock();
    defer rtr.crtMtx.unlock();

    if (rtr.shtdwnStrt) {
        return AmpeError.ShutdownStarted;
    }

    if (chnlsimpl == null) {
        return AmpeError.InvalidAddress;
    }
    return try rtr.*.send_destroy(chnlsimpl);
}

inline fn send_destroy(rtr: *Reactor, chnlsimpl: ?*anyopaque) AmpeError!void {
    const grp: *MchnGroup = @ptrCast(@alignCast(chnlsimpl));

    grp.resetCmdCompleted();

    try send_channels_cmd(rtr, chnlsimpl, .shutdown_started);

    grp.waitCmdCompleted();

    grp.destroy();

    return;
}

fn send_channels_cmd(rtr: *Reactor, chnlsimpl: ?*anyopaque, st: AmpeStatus) AmpeError!void {
    const grp: *MchnGroup = @ptrCast(@alignCast(chnlsimpl));

    var msg: ?*Message = try rtr._get(.always);
    errdefer rtr._put(&msg);

    const cmd: *Message = msg.?;
    cmd.*.bhdr.channel_number = message.SpecialMaxChannelNumber;
    cmd.*.bhdr.proto.opCode = .Signal;
    cmd.*.bhdr.proto.origin = .engine;
    cmd.*.bhdr.proto._internalA = .on;
    cmd.*.bhdr.proto.more = .last;

    cmd.*.bhdr.channel_number = 0;
    cmd.*.bhdr.status = status.status_to_raw(st);

    _ = cmd.*.ptrToBody(MchnGroup, grp);

    try rtr.submitMsg(cmd);

    return;
}

fn getAllocator(ptr: ?*anyopaque) Allocator {
    const rtr: *Reactor = @ptrCast(@alignCast(ptr));
    return rtr.*.allocator;
}

pub fn submitMsg(rtr: *Reactor, msg: *Message) AmpeError!void {
    rtr.sndMtx.lock();
    defer rtr.sndMtx.unlock();

    if (!rtr.ntfcsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    const oob = msg.bhdr.proto._internalA;

    rtr.msgs[@intFromEnum(oob)].send(msg) catch {
        return AmpeError.NotAllowed;
    };

    try rtr.ntfr.sendNotification(.{
        .kind = .message,
        .oob = oob,
    });

    return;
}

fn send_alert(ptr: ?*anyopaque, alert: Notifier.Alert) AmpeError!void {
    const rtr: *Reactor = @ptrCast(@alignCast(ptr));
    return rtr.sendAlert(alert);
}

fn sendAlert(rtr: *Reactor, alrt: Notifier.Alert) AmpeError!void {
    // rtr.mutex.lock();
    // defer rtr.mutex.unlock();

    return rtr._sendAlert(alrt);
}

fn _sendAlert(rtr: *Reactor, alrt: Notifier.Alert) AmpeError!void {
    rtr.sndMtx.lock();
    defer rtr.sndMtx.unlock();

    if (!rtr.ntfcsEnabled) {
        return AmpeError.NotificationDisabled;
    }

    try rtr.ntfr.sendNotification(.{
        .kind = .alert,
        .alert = alrt,
    });

    if (alrt == .shutdownStarted) {
        rtr.ntfcsEnabled = false;
        rtr.shtdwnStrt = true;
    }

    return;
}

fn createNotificationChannel(rtr: *Reactor) !void {
    var ntcn = rtr.createDumbChannel();
    ntcn.acn.chn = message.SpecialMaxChannelNumber;
    ntcn.resp2ac = true;
    ntcn.tskt = .{
        .notification = internal.triggeredSkts.NotificationSkt.init(&rtr.ntfr.receiver),
    };

    try rtr.addChannel(ntcn);

    rtr.ntfcsEnabled = true;

    return;
}

fn deinitTrgrdChns(rtr: *Reactor) void {
    var it = Iterator.init(&rtr.trgrd_map);

    it.reset();

    var tcopt = it.next();

    while (tcopt != null) : (tcopt = it.next()) {
        tcopt.?.acn.ctx = null;

        tcopt.?.deinitTc();
    }

    rtr.trgrd_map.deinit();
    rtr.chnlsGroup_map.deinit();
}

// Generates the next unique group id using an atomic counter.
inline fn next_gid() u32 {
    return gid.fetchAdd(1, .monotonic);
}

// Atomic counter for generating unique group id
var gid: Atomic(u32) = .init(1);

fn createThread(rtr: *Reactor) !void {
    rtr.crtMtx.lock();
    defer rtr.crtMtx.unlock();

    if (rtr.thread != null) {
        return;
    }

    rtr.thread = try std.Thread.spawn(.{}, runOnThread, .{rtr});

    _ = try rtr.*.recv_ack();

    return;
}

inline fn waitFinish(rtr: *Reactor) void {
    if (rtr.thread) |t| {
        t.join();
    }
}

fn releaseToPool(rtr: *Reactor, storedMsg: *?*Message) void {
    if (storedMsg.*) |msg| {
        rtr.pool.put(msg);
        storedMsg.* = null;
    }
    return;
}

pub fn buildStatusSignal(rtr: *Reactor, stat: AmpeStatus) *Message {
    var ret = Message.create(rtr.allocator) catch unreachable;
    ret.bhdr.status = status.status_to_raw(stat);
    ret.bhdr.proto.opCode = .Signal;
    ret.bhdr.proto.origin = .engine;
    return ret;
}

fn addChannel(rtr: *Reactor, tchn: TriggeredChannel) AmpeError!void {
    if (rtr.trgrd_map.contains(tchn.acn.chn)) {
        log.warn("channel {d} already exists", .{tchn.acn.chn});
        return AmpeError.InvalidChannelNumber;
    }

    rtr.trgrd_map.put(tchn.acn.chn, tchn) catch {
        return AmpeError.AllocationFailed;
    };

    rtr.trgrd_map.getPtr(tchn.acn.chn).?.reportWrong();

    rtr.cnmapChanged = true;

    return;
}

pub const TriggeredChannelsMap = std.AutoArrayHashMap(channels.ChannelNumber, TriggeredChannel);

const ChannelsGroupMap = std.AutoArrayHashMap(u32, *MchnGroup);

//=================================================
//                 ON THREAD
//=================================================

fn runOnThread(rtr: *Reactor) void {
    rtr.loop();
    return;
}

inline fn ack(rtr: *Reactor) void {
    rtr.*.cmpl.post();
}

inline fn recv_ack(rtr: *Reactor) !void {
    _ = try rtr.*.cmpl.timedWait(tofu.waitReceive_INFINITE_TIMEOUT);
    return;
}

fn loop(rtr: *Reactor) void {
    defer rtr.cleanMboxes();

    rtr.cnmapChanged = false;
    var it = Iterator.init(&rtr.trgrd_map);
    var withItrtr: bool = true;

    var sendAckDone: bool = false;
    var timeOut: i32 = 0;

    while (true) {
        { // Section for delay during debug session
            // 1_000_000_000    1 sec
            // 1_000_000        1 mlsec
            // std.time.sleep(50_000_000);
        }

        rtr.vchns();

        if (sendAckDone) {
            timeOut = poll_SEC_TIMEOUT * 3; // was poll_INFINITE_TIMEOUT;
        } else {
            sendAckDone = true;
            defer rtr.ack();
        }

        rtr.*.validateChannels();

        rtr.m4delCnt = 0;
        rtr.loopTrgrs = .{};

        if (rtr.cnmapChanged) {
            it = Iterator.init(&rtr.trgrd_map);
            rtr.cnmapChanged = false;
            withItrtr = true;
        }

        var itropt: ?Iterator = null;
        if (withItrtr) {
            itropt = it;
        }

        rtr.loopTrgrs = rtr.plr.waitTriggers(itropt, timeOut) catch |err| {
            log.err("waitTriggers error {any}", .{
                err,
            });
            rtr.processWaitTriggersFailure();
            return;
        };

        const utrs = UnpackedTriggers.fromTriggers(rtr.loopTrgrs);
        _ = utrs;

        if (rtr.loopTrgrs.notify == .on) {
            rtr.processNotify() catch |err|
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

        rtr.processTriggeredChannels(&it) catch |err|
            switch (err) {
                AmpeError.ShutdownStarted => {
                    return;
                },
                else => {
                    log.err("processTriggeredChannels failed with error {any}", .{err});
                    return;
                },
            };

        rtr.processMessageFromChannels() catch |err|
            switch (err) {
                AmpeError.ShutdownStarted => {
                    return;
                },
                else => {
                    log.info("processMessageFromChannels returned error {any}", .{err});
                },
            };

        _ = rtr.processMarkedForDelete() catch |err| { // was wasRemoved
            log.err("processMarkedForDelete failed with error {any}", .{err});
            return;
        };

        // if (wasRemoved) {
        rtr.cnmapChanged = true;
        // }
    }

    return;
}

fn validateChannels(rtr: *Reactor) void {
    var it = Iterator.init(&rtr.trgrd_map);

    it.reset();

    var tcopt = it.next();

    while (tcopt != null) : (tcopt = it.next()) {
        tcopt.?.reportWrong();
    }
}

inline fn processWaitTriggersFailure(rtr: *Reactor) void {
    // 2DO - Add failure processing
    _ = rtr;
    return;
}

inline fn processTimeOut(rtr: *Reactor) void {
    // Placeholder for idle processing
    _ = rtr;
    return;
}

fn processNotify(rtr: *Reactor) !void {
    const notfTrChnOpt = rtr.trgrd_map.getPtr(message.SpecialMaxChannelNumber);
    assert(notfTrChnOpt != null);
    const notfTrChn = notfTrChnOpt.?;
    assert(notfTrChn.act.notify == .on);

    rtr.currNtfc = try notfTrChn.tryRecvNotification();
    rtr.unpnt = Notifier.UnpackedNotification.fromNotification(rtr.currNtfc);

    notfTrChn.act = .{}; // Disable obsolete processing during iteration

    if (rtr.currNtfc.kind == .alert) {
        switch (rtr.currNtfc.alert) {
            .shutdownStarted => {
                // Exit processing loop.
                // All resources will be released/destroyed
                // after waitFinish() of the thread
                rtr.ntfcsEnabled = false;
                return AmpeError.ShutdownStarted;
            },
            .freedMemory => {
                return; // Adding message from pool will be handled in processTriggeredChannels
            },
        }
    }

    assert(rtr.currNtfc.kind == .message);

    return rtr.storeMessageFromChannels();
}

fn storeMessageFromChannels(rtr: *Reactor) !void {
    rtr.currMsg = null;

    var currMsg: *message.Message = undefined;
    var received: bool = false;

    const queueIndx = @intFromEnum(rtr.currNtfc.oob);

    for (0..1) |_| {
        currMsg = rtr.msgs[queueIndx].receive(0) catch |err|
            switch (err) {
                error.Timeout, error.Interrupted => {
                    break;
                },
                else => {
                    return AmpeError.ShutdownStarted;
                },
            };

        received = true;
        break;
    }

    if (!received) {
        return;
    }

    rtr.currMsg = currMsg;
    rtr.currBhdr = currMsg.bhdr;
    currMsg.assert();
    return;
}

fn processTriggeredChannels(rtr: *Reactor, it: *Iterator) !void {
    it.reset();

    rtr.currTcopt = it.next();

    trcIter: while (rtr.currTcopt != null) : (rtr.currTcopt = it.next()) {
        const tc = rtr.currTcopt.?;

        const trgrs = tc.act;

        const utrgs = UnpackedTriggers.fromTriggers(trgrs);
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
            _ = tc.tryConnect() catch {
                tc.markForDelete(.connect_failed);
            };
            continue;
        }

        if (trgrs.pool == .on) {
            while (true) {
                const rcvmsg = rtr.pool.get(.poolOnly) catch {
                    // Pool still empty, update receiver
                    tc.*.informPoolEmpty();
                    break;
                };

                tc.addForRecv(rcvmsg) catch |err| {
                    rtr.pool.put(rcvmsg);
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
            rtr.createIoServerChannel(tc) catch |err| {
                log.info("createIoServerChannel for connected client failed with error {s}", .{@errorName(err)});
            };
            continue;
        }

        if (trgrs.send == .on) {
            var wereSend: message.MessageQueue = tc.trySend() catch {
                tc.markForDelete(.send_failed);
                continue;
            };
            var next: ?*Message = wereSend.dequeue();
            while (next != null) {
                rtr.pool.put(next.?);
                next = wereSend.dequeue();
            }
        }

        if (trgrs.recv == .on) {
            var wereRecv: message.MessageQueue = tc.tryRecv() catch {
                tc.markForDelete(.recv_failed);
                continue;
            };
            var next: ?*Message = wereRecv.dequeue();
            while (next != null) {
                var byeResponseReceived: bool = false;
                if ((next.?.bhdr.proto.opCode == .ByeResponse)) {
                    byeResponseReceived = true;
                }
                tc.sendToCtx(&next);
                if (byeResponseReceived) {
                    tc.markForDelete(.channel_closed);
                }
                next = wereRecv.dequeue();
            }
        }
    }

    return;
}

fn processMessageFromChannels(rtr: *Reactor) !void {
    if (rtr.currMsg == null) {
        return;
    }

    defer rtr.releaseToPool(&rtr.currMsg);

    if (rtr.currBhdr.proto.origin == .engine) {
        return rtr.processInternal();
    }

    const oc: message.OpCode = try rtr.currMsg.?.*.getOpCode();

    rtr.currMsg.?.assert();

    switch (oc) {
        .HelloRequest => return rtr.sendHelloRequest(),
        .WelcomeRequest => return rtr.sendWelcomeRequest(),
        .ByeRequest, .ByeSignal => return rtr.sendBye(),
        .ByeResponse => return rtr.sendByeResponse(),

        .HelloResponse, .Request, .Signal, .Response => return rtr.post(),

        else => return AmpeError.InvalidMessage,
    }

    return;
}

fn processInternal(rtr: *Reactor) !void {
    rtr.currMsg.?.assert();

    var cmsg = rtr.currMsg.?;
    const chnlsimpl: ?*MchnGroup = cmsg.bodyToPtr(MchnGroup);
    const grp = chnlsimpl.?;

    if (cmsg.bhdr.status == 0) { // Create group
        rtr.chnlsGroup_map.put(grp.id.?, grp) catch {
            return AmpeError.AllocationFailed;
        };
        return;
    }

    defer grp.setCmdCompleted();

    const grpPtr: ?**MchnGroup = rtr.chnlsGroup_map.getPtr(grp.id.?);
    assert(grpPtr != null);
    assert(grpPtr.?.*.id.? == grp.id.?);
    _ = rtr.chnlsGroup_map.orderedRemove(grp.id.?);

    var chgr = rtr.acns.channelGroup(chnlsimpl) catch unreachable;
    defer chgr.deinit(rtr.allocator);
    _ = rtr.acns.removeChannels(chnlsimpl) catch unreachable;
    {
        for (chgr.items) |chN| {
            const trcopt = rtr.trgrd_map.getPtr(chN);

            if (trcopt != null) {
                var tc = trcopt.?;

                assert(tc.acn.ctx != null);
                const grpCtx: *MchnGroup = @ptrCast(@alignCast(tc.acn.ctx.?));
                assert(grp == grpCtx);
                tc.resp2ac = false;
                tc.*.deinitTc();
            }
        }
        // }
        return;
    }
}

fn sendByeResponse(rtr: *Reactor) !void {
    // For now - nothing special, just post
    // In the future - possibly to disable further sends
    return rtr.post();
}

fn processMarkedForDelete(rtr: *Reactor) !bool {
    var removedCount: usize = 0;

    try rtr.allTrgChannels(&rtr.allChnN);

    for (rtr.allChnN.items) |chN| {
        const tcOpt: ?*TriggeredChannel = rtr.trgrd_map.getPtr(chN);
        if (tcOpt) |tcPtr| {
            if (tcPtr.mrk4del) {
                tcPtr.deinitTc();
                _ = rtr.trgrd_map.swapRemove(chN);
                removedCount += 1;
            }
        }
    }

    return removedCount > 0;
}

fn sendHelloRequest(rtr: *Reactor) !void {
    rtr.currMsg.?.assert();

    rtr.createIoClientChannel() catch |err| {
        assert(rtr.currMsg != null);
        rtr.currMsg.?.bhdr.proto.opCode = .HelloResponse;

        const st = status.errorToStatus(err);
        rtr.responseFailure(st);
        return;
    };

    return;
}

fn sendWelcomeRequest(rtr: *Reactor) !void {
    rtr.currMsg.?.assert();

    rtr.createListenerChannel() catch |err| {
        log.info("createListenerChannel {d} failed with error {any}", .{ rtr.currMsg.?.bhdr.channel_number, err });

        rtr.currMsg.?.bhdr.proto.opCode = .WelcomeResponse;

        const st = status.errorToStatus(err);
        rtr.responseFailure(st);
        return;
    };

    return;
}

fn sendBye(rtr: *Reactor) !void {
    rtr.currMsg.?.assert();

    const bye: *Message = rtr.currMsg.?;

    if ((bye.bhdr.proto.getRole() == .signal) and (bye.bhdr.proto._internalA == .on)) {
        // Initiate close of the channel
        rtr.responseFailure(AmpeStatus.channel_closed);
        return;
    }

    return rtr.post();
}

fn post(rtr: *Reactor) !void {
    rtr.currMsg.?.assert();

    const sendMsg: *Message = rtr.currMsg.?;
    const chN = sendMsg.bhdr.channel_number;

    var tc = rtr.trgrd_map.getPtr(chN);
    if (tc == null) { // Already removed
        return;
    }

    tc.?.tskt.addToSend(sendMsg) catch |err| {
        log.info("addToSend on channel {d} failed with error {any}", .{ chN, err });
        const st = status.errorToStatus(err);
        rtr.responseFailure(st);
    };

    rtr.currMsg = null;

    return;
}

fn responseFailure(rtr: *Reactor, failure: AmpeStatus) void {
    rtr.currMsg.?.assert();

    defer rtr.releaseToPool(&rtr.currMsg);

    rtr.currMsg.?.bhdr.status = status.status_to_raw(failure);
    rtr.currMsg.?.bhdr.proto.origin = .engine;

    const chn = rtr.currMsg.?.bhdr.channel_number;
    var trchn = rtr.trgrd_map.getPtr(chn);
    if (trchn != null) {
        trchn.?.markForDelete(failure);
        trchn.?.sendToCtx(&rtr.currMsg);
        return;
    }
    if (rtr.currMsg.?.@"<ctx>" == null) {
        // Both channel and channels were deleted
        // Message will be returned to Pool via defer above
        return;
    }

    // Try notify ChannelGroup directly
    _ = MchnGroup.sendToReceiver(rtr.currMsg.?.@"<ctx>", &rtr.currMsg) catch {};
    return;
}

fn createDumbChannel(rtr: *Reactor) TriggeredChannel {
    const ret: TriggeredChannel = .{
        .engine = rtr,
        .acn = .{
            .chn = 0,
            .mid = 0,
            .ctx = null,
        },
        .tskt = .{
            .dumb = .{},
        },
        .exp = internal.triggeredSkts.TriggersOff,
        .act = internal.triggeredSkts.TriggersOff,
        .mrk4del = true,
        .resp2ac = true,
        .st = null,
        .firstRecvFinished = false,
    };
    return ret;
}

fn createIoClientChannel(rtr: *Reactor) AmpeError!void {
    rtr.currMsg.?.assert();

    const hello: *Message = rtr.currMsg.?;
    const chN = hello.bhdr.channel_number;
    var tc = createDumbChannel(rtr);
    tc.acn = rtr.*.acns.activeChannel(chN) catch unreachable;

    try rtr.addChannel(tc);

    var sc: internal.SocketCreator = internal.SocketCreator.init(rtr.allocator);
    var clSkt: internal.triggeredSkts.IoSkt = .{};
    errdefer clSkt.deinit();

    try clSkt.initClientSide(&rtr.pool, hello, &sc);
    rtr.*.currMsg = null;

    _ = clSkt.tryConnect() catch |err| {
        // Restore HelloRequest
        var smsgs: MessageQueue = clSkt.detach();
        const helloMsg: ?*Message = smsgs.dequeue();
        if (helloMsg != null) {
            rtr.*.currMsg = helloMsg.?;
        }
        return err;
    };

    const tcptr = rtr.trgrd_map.getPtr(hello.bhdr.channel_number).?;
    tcptr.disableDelete();
    tcptr.*.resp2ac = true;

    const tskt: internal.triggeredSkts.TriggeredSkt = .{
        .io = clSkt,
    };
    tcptr.*.tskt = tskt;

    return;
}

fn createIoServerChannel(rtr: *Reactor, lstchn: *TriggeredChannel) AmpeError!void {
    // Try to get socket of the client
    var srvsktOpt = lstchn.tryAccept() catch |err| {
        // Failure on the client side ???
        log.info("createIoServerChannel tryAccept error {any}", .{err});
        return;
    };

    if (srvsktOpt == null) {
        // Continue to poll
        log.info("createIoServerChannel srvsktOpt == null ", .{});
        return;
    }

    errdefer srvsktOpt.?.close();

    var tc = createDumbChannel(rtr);

    const lactChn = lstchn.*.acn;

    // new ActiveChannel for connected client
    // 2DO set mid & inttr  to real values upon receive of HelloRequest/HelloSignal
    const newAcn = rtr.createChannelOnT(0, .{}, lactChn.ctx);
    errdefer rtr.removeChannelOnT(newAcn.chn);
    tc.acn = newAcn;
    try rtr.addChannel(tc);

    var clSkt: internal.triggeredSkts.IoSkt = try internal.triggeredSkts.IoSkt.initServerSide(&rtr.pool, newAcn.chn, srvsktOpt.?);
    errdefer clSkt.deinit();

    const srvio: internal.triggeredSkts.TriggeredSkt = .{
        .io = clSkt,
    };

    const tcptr = rtr.trgrd_map.getPtr(newAcn.chn).?;
    tcptr.disableDelete();
    tcptr.*.resp2ac = true;
    tcptr.*.tskt = srvio;
    return;
}

fn createListenerChannel(rtr: *Reactor) AmpeError!void {
    rtr.currMsg.?.assert();

    const welcome: *Message = rtr.currMsg.?;
    const chN = welcome.bhdr.channel_number;

    var tc = rtr.createDumbChannel();
    tc.acn = rtr.*.acns.activeChannel(chN) catch unreachable;

    try rtr.addChannel(tc);

    var sc: internal.SocketCreator = internal.SocketCreator.init(rtr.allocator);
    var accSkt: internal.triggeredSkts.AcceptSkt = .{};
    errdefer accSkt.deinit();

    accSkt = try internal.triggeredSkts.AcceptSkt.init(welcome, &sc);

    const tcptrOpt = rtr.trgrd_map.getPtr(welcome.bhdr.channel_number);
    if (tcptrOpt == null) {
        log.warn("listener channel {d} was not added to triggered channels", .{chN});
        return AmpeError.InvalidChannelNumber;
    }

    const tcptr = tcptrOpt.?;

    tcptr.disableDelete();
    tcptr.*.resp2ac = true;

    const tskt: internal.triggeredSkts.TriggeredSkt = .{
        .accept = accSkt,
    };
    tcptr.*.tskt = tskt;

    // Listener started, so we can send succ. status to the caller.
    if (tcptr.*.acn.intr.?.getRole() == .request) {
        rtr.currMsg.?.bhdr.proto.opCode = .WelcomeResponse;
        rtr.currMsg.?.bhdr.status = 0;
        tcptr.sendToCtx(&rtr.currMsg);
    }

    return;
}

// Wrappers working with ActiveChannels on the thread
fn removeChannelOnT(rtr: *Reactor, cn: message.ChannelNumber) void {
    var tc = rtr.trgrd_map.getPtr(cn);
    if (tc != null) {
        tc.?.markForDelete(status.AmpeStatus.channel_closed);
    } else {
        rtr.acns.removeChannel(cn);
    }
    return;
}

fn createChannelOnT(rtr: *Reactor, mid: MessageID, intr: ?message.ProtoFields, ptr: ?*anyopaque) channels.ActiveChannel {
    return rtr.acns.createChannel(mid, intr, ptr);
}

fn allTrgChannels(rtr: *Reactor, chns: *std.ArrayList(message.ChannelNumber)) !void {
    chns.resize(rtr.allocator, 0) catch unreachable;

    var it = rtr.*.trgrd_map.iterator();
    while (it.next()) |kv_pair| {
        try chns.append(rtr.allocator, kv_pair.key_ptr.*);
    }

    return;
}

fn cleanMboxes(rtr: *Reactor) void {
    for (rtr.msgs, 0..) |_, i| {
        var mbx = rtr.msgs[i];
        var allocated = mbx.close();
        while (allocated != null) {
            const next = allocated.?.next;
            allocated.?.destroy();
            allocated = next;
        }
    }
}

// Run-time validators
inline fn vchns(rtr: *Reactor) void {
    if (rtr.trgrd_map.count() == 0) {
        log.warn(" !!!! zero triggered channels !!!!", .{});
        std.Thread.sleep(1_000_000_000); // For breakpoint
    }

    const notfTrChnOpt: ?*TriggeredChannel = rtr.trgrd_map.getPtr(message.SpecialMaxChannelNumber);
    assert(notfTrChnOpt != null);

    assert(notfTrChnOpt.?.*.tskt.notification.getSocket() == rtr.*.ntfr.receiver.socket.?);

    return;
}

pub const Iterator = struct {
    itrtr: ?Reactor.TriggeredChannelsMap.Iterator = null,
    map: ?*Reactor.TriggeredChannelsMap = null,

    pub fn init(tcm: *Reactor.TriggeredChannelsMap) Iterator {
        return .{
            .itrtr = tcm.iterator(),
            .map = tcm,
        };
    }

    pub fn getPtr(itr: *Iterator, key: channels.ChannelNumber) ?*TriggeredChannel {
        if (itr.map) |m| {
            return m.getPtr(key);
        }
        return null;
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

pub const TriggeredChannel = struct {
    engine: *Reactor = undefined,
    acn: channels.ActiveChannel = undefined,
    resp2ac: bool = undefined,
    tskt: TriggeredSkt = undefined,
    exp: internal.triggeredSkts.Triggers = undefined,
    act: internal.triggeredSkts.Triggers = undefined,
    mrk4del: bool = undefined,
    st: ?AmpeStatus = undefined,
    firstRecvFinished: bool = undefined,

    pub fn informPoolEmpty(tchn: *TriggeredChannel) void {
        var peSignal: ?*Message = tchn.*.engine.*.buildStatusSignal(.pool_empty);

        // log.debug(" ^^^^^^^^^^^^^^^^^ empty pool channel {d}", .{tchn.*.acn.chn});

        tchn.*.sendToCtx(&peSignal);
        return;
    }

    pub fn sendToCtx(tchn: *TriggeredChannel, msg: *?*Message) void {
        if (msg.* == null) {
            return;
        }

        defer tchn.engine.releaseToPool(msg);

        if ((tchn.acn.ctx == null) or (tchn.resp2ac == false)) {
            return;
        }

        if (msg.*.?.@"<ctx>" == null) {
            msg.*.?.@"<ctx>" = tchn.acn.ctx;
        }

        msg.*.?.bhdr.channel_number = tchn.*.acn.chn;

        MchnGroup.sendToReceiver(tchn.acn.ctx.?, msg) catch {};

        return;
    }

    pub fn deinitTc(tchn: *TriggeredChannel) void {
        defer tchn.*.removeTc();

        if ((tchn.acn.ctx == null) or (tchn.resp2ac == false)) {
            return;
        }

        var mq = tchn.detach();
        var next = mq.dequeue();
        const st = if (tchn.st != null) status.status_to_raw(tchn.st.?) else status.status_to_raw(.channel_closed);
        while (next != null) {
            next.?.bhdr.proto.origin = .engine;
            next.?.bhdr.status = st;
            tchn.sendToCtx(&next);
            next = mq.dequeue();
        }

        var statusMsg = tchn.engine.buildStatusSignal(.channel_closed);

        // Stored information from from received message
        statusMsg.bhdr.channel_number = tchn.acn.chn;
        statusMsg.bhdr.message_id = tchn.acn.mid;

        var responseToCtx: ?*Message = statusMsg;

        tchn.sendToCtx(&responseToCtx);

        return;
    }

    inline fn removeTc(tchn: *TriggeredChannel) void {
        const chN = tchn.acn.chn;

        if (chN == 0) {
            return;
        }

        const rtr = tchn.engine;

        tchn.tskt.deinit();

        rtr.removeChannelOnT(chN);

        const wasRemoved: bool = rtr.trgrd_map.swapRemove(chN);

        if (wasRemoved) {
            rtr.cnmapChanged = true;
        }

        const trcopt = rtr.trgrd_map.getPtr(chN);
        if (trcopt != null) {
            assert(trcopt.?.acn.chn == chN);
            log.err("trg channel {d} was not removed", .{chN});
        }

        return;
    }

    pub inline fn markForDelete(tchn: *TriggeredChannel, reason: AmpeStatus) void {
        tchn.mrk4del = true;
        tchn.st = reason;
        return;
    }

    pub inline fn reportWrong(_: *TriggeredChannel) void {
        // if (tchn.acn.chn == 0) {
        //     switch (tchn.*.tskt) {
        //         .notification => {},
        //         else => {
        //             log.debug("non-notification channel == 0", .{});
        //
        //             if (tchn.acn.intr != null) {
        //                 const proto: message.ProtoFields = tchn.acn.intr.?;
        //
        //                 const mt = std.enums.tagName(MessageType, proto.mtype).?;
        //                 const rl = std.enums.tagName(MessageRole, proto.role).?;
        //                 const org = std.enums.tagName(OriginFlag, proto.origin).?;
        //                 const mr = std.enums.tagName(MoreMessagesFlag, proto.more).?;
        //                 const ob = std.enums.tagName(message.Oob, proto.oob).?;
        //
        //                 log.debug("[mid {d}] ({d}) {s} {s} {s} {s} {s}", .{ tchn.acn.mid, tchn.acn.chn, mt, rl, org, mr, ob });
        //             }
        //         },
        //     }
        // }
        return;
    }

    pub inline fn disableDelete(tchn: *TriggeredChannel) void {
        tchn.mrk4del = false;
        tchn.st = null;
    }

    // Wrappers of TriggeredSkt
    pub inline fn triggers(tchn: *TriggeredChannel) !Triggers {
        return tchn.tskt.triggers();
    }

    pub inline fn getSocket(tchn: *TriggeredChannel) Socket {
        return tchn.tskt.getSocket();
    }
    pub inline fn tryRecvNotification(tchn: *TriggeredChannel) !Notification {
        return tchn.tskt.tryRecvNotification();
    }

    pub inline fn tryAccept(tchn: *TriggeredChannel) !?Skt {
        return tchn.tskt.tryAccept();
    }

    pub inline fn tryConnect(tchn: *TriggeredChannel) !bool {
        return tchn.tskt.tryConnect();
    }

    pub inline fn tryRecv(tchn: *TriggeredChannel) !MessageQueue {
        var mq: MessageQueue = try tchn.tskt.tryRecv();
        if ((tchn.firstRecvFinished) or (mq.count() == 0)) {
            return mq;
        }

        tchn.acn.mid = mq.first.?.bhdr.message_id;
        tchn.acn.intr = mq.first.?.bhdr.proto;
        tchn.firstRecvFinished = true;

        return mq;
    }

    pub inline fn trySend(tchn: *TriggeredChannel) !MessageQueue {
        return tchn.tskt.trySend();
    }

    pub inline fn addToSend(tchn: *TriggeredChannel, sndmsg: *Message) !void {
        sndmsg.assert();

        return tchn.tskt.addToSend(sndmsg);
    }

    pub inline fn addForRecv(tchn: *TriggeredChannel, rcvmsg: *Message) !void {
        return tchn.tskt.addForRecv(rcvmsg);
    }

    pub inline fn detach(tchn: *TriggeredChannel) MessageQueue {
        return tchn.tskt.detach();
    }
};

inline fn initPlatform() AmpeError!void {
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        var wsa_data: ws2_32.WSADATA = undefined;
        if (ws2_32.WSAStartup(0x0202, &wsa_data) != 0) return AmpeError.CommunicationFailed;
    }
}

inline fn deinitPlatform() void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.WSACleanup();
    }
}

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
const MessageQueue = message.MessageQueue;

const Options = tofu.Options;
const Ampe = tofu.Ampe;
const ChannelGroup = tofu.ChannelGroup;

const status = tofu.status;
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const internal = tofu.@"internal usage";
const Notifier = internal.Notifier;
const Notification = Notifier.Notification;

const Skt = internal.Skt;

const Pool = internal.Pool;

const channels = internal.channels;
const ActiveChannels = channels.ActiveChannels;

const Triggers = internal.triggeredSkts.Triggers;
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;
const UnpackedTriggers = internal.triggeredSkts.UnpackedTriggers;

pub const MchnGroup = @import("MchnGroup.zig");
const GroupId = MchnGroup.GroupId;

const poller = internal.poller;

const poll_INFINITE_TIMEOUT: u32 = @import("poller.zig").poll_INFINITE_TIMEOUT;
const poll_SEC_TIMEOUT: u32 = @import("poller.zig").poll_SEC_TIMEOUT;

const Appendable = @import("Appendable");

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;
const Semaphore = std.Thread.Semaphore;
const getCurrentTid = Thread.getCurrentId;
const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicRmwOp = std.builtin.AtomicRmwOp;

const Socket = std.posix.socket_t;
const log = std.log;
const assert = std.debug.assert;
