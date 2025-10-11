// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Engine = @This();

pub fn ampe(eng: *Engine) !Ampe {
    const result: Ampe = .{
        .ptr = eng,
        .vtable = &.{
            .get = get,
            .put = put,
            .create = create,
            .destroy = destroy,
            .getAllocator = getAllocator,
        },
    };

    return result;
}

fn alerter(eng: *Engine) Notifier.Alerter {
    const result: Notifier.Alerter = .{
        .ptr = eng,
        .func = send_alert,
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

    eng.acns = ActiveChannels.init(eng.allocator, 1024) catch { // was 255
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

    try eng.createNotificationChannel();

    eng.createThread() catch |err| {
        log.err("create engine thread error {s}", .{@errorName(err)});
        return AmpeError.AllocationFailed;
    };

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

fn getAllocator(ptr: ?*anyopaque) Allocator {
    const eng: *Engine = @alignCast(@ptrCast(ptr));
    return eng.*.allocator;
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

fn send_alert(ptr: ?*anyopaque, alert: Notifier.Alert) AmpeError!void {
    const eng: *Engine = @alignCast(@ptrCast(ptr));
    return eng.sendAlert(alert);
}

fn sendAlert(eng: *Engine, alrt: Notifier.Alert) AmpeError!void {
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

fn createNotificationChannel(eng: *Engine) !void {
    log.debug("createNotificationChannel ->", .{});
    defer log.debug("<- createNotificationChannel", .{});

    var ntcn = eng.createDumbChannel();
    ntcn.resp2ac = true;
    ntcn.tskt = .{
        .notification = internal.triggeredSkts.NotificationSkt.init(eng.ntfr.receiver),
    };

    try eng.addChannel(ntcn);

    eng.ntfcsEnabled = true;

    return;
}

fn deinitTrgrdChns(eng: *Engine) void {
    var it = Iterator.init(&eng.trgrd_map);

    it.reset();

    var tcopt = it.next();

    while (tcopt != null) : (tcopt = it.next()) {
        tcopt.?.acn.ctx = null;
        tcopt.?.deinitTc();
    }

    eng.trgrd_map.deinit();
}

fn createThread(eng: *Engine) !void {
    eng.mutex.lock();
    defer eng.mutex.unlock();

    if (eng.thread != null) {
        return;
    }

    eng.thread = try std.Thread.spawn(.{}, runOnThread, .{eng});

    _ = try eng.ntfr.recvAck();

    return;
}

inline fn waitFinish(eng: *Engine) void {
    log.debug("waitFinish ->", .{});
    defer log.debug("<- waitFinish", .{});

    if (eng.thread) |t| {
        t.join();
    }
}

fn releaseToPool(eng: *Engine, storedMsg: *?*Message) void {
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

fn addChannel(eng: *Engine, tchn: TriggeredChannel) AmpeError!void {
    eng.trgrd_map.put(tchn.acn.chn, tchn) catch {
        return AmpeError.AllocationFailed;
    };
    eng.cnmapChanged = true;
    return;
}

const TriggeredChannelsMap = std.AutoArrayHashMap(channels.ChannelNumber, TriggeredChannel);

//=================================================
//                 ON THREAD
//=================================================

fn runOnThread(eng: *Engine) void {
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
        eng.*.validateChannels();

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

        log.debug(">>>> triggered channels count {d}", .{eng.trgrd_map.count()});

        eng.loopTrgrs = eng.plr.waitTriggers(itropt, poll_INFINITE_TIMEOUT) catch |err| {
            log.err("waitTriggers error {any}", .{
                err,
            });
            eng.processWaitTriggersFailure();
            return;
        };

        const utrs = UnpackedTriggers.fromTriggers(eng.loopTrgrs);
        _ = utrs;

        assert(eng.loopTrgrs.timeout != .on); // INFINITE_TIMEOUT_MS

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

        _ = eng.processMarkedForDelete() catch |err| { // was wasRemoved
            log.err("processMarkedForDelete failed with error {any}", .{err});
            return;
        };

        // if (wasRemoved) {
        eng.cnmapChanged = true;
        // }
    }

    return;
}

fn validateChannels(eng: *Engine) void {
    eng.acns.allChannels(&eng.allChnN) catch undefined;

    log.debug(">>>> active channels {d} triggered channels {d}", .{ eng.allChnN.items.len, eng.trgrd_map.count() });

    // for (eng.allChnN.items) |chN| {
    //     const tcOpt: ?*TriggeredChannel = eng.trgrd_map.getPtr(chN);
    //     if (tcOpt != null) {
    //         continue;
    //     }
    //
    //     const acn: channels.ActiveChannel = eng.*.acns.activeChannel(chN) catch unreachable;
    //
    //     var proto: u8 = 0;
    //     if (acn.intr != null) {
    //         proto = @bitCast(acn.intr.?);
    //     }
    //
    //     log.debug("^,^,^, channel {d} is not triggered mid {d} proto {b}", .{ chN, acn.mid, proto });
    // }
}

fn processWaitTriggersFailure(eng: *Engine) void {
    // 2DO - Add failure processing
    _ = eng;
    return;
}

fn processTimeOut(eng: *Engine) void {
    // Placeholder for idle processing
    _ = eng;
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

    eng.currNtfc = try notfTrChn.tryRecvNotification();
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
    log.debug("processTriggeredChannels {d} ->", .{eng.*.trgrd_map.count()});
    defer log.debug("<- processTriggeredChannels {d} ", .{eng.*.trgrd_map.count()});

    it.reset();

    eng.currTcopt = it.next();

    trcIter: while (eng.currTcopt != null) : (eng.currTcopt = it.next()) {
        const tc = eng.currTcopt.?;

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
                const rcvmsg = eng.pool.get(.poolOnly) catch {
                    break;
                };

                tc.addForRecv(rcvmsg) catch |err| {
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
            eng.createIoServerChannel(tc) catch |err| {
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
                eng.pool.put(next.?);
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
        .HelloRequest => return eng.sendHelloRequest(),
        .WelcomeRequest => return eng.sendWelcomeRequest(),
        .ByeRequest, .ByeSignal => return eng.sendBye(),
        .ByeResponse => return eng.sendByeResponse(),

        .HelloResponse, .AppRequest, .AppSignal, .AppResponse => return eng.sendToPeer(),

        else => return AmpeError.InvalidMessage,
    }

    return;
}

fn processInternal(eng: *Engine) !void {
    log.debug("processInternal ->", .{});
    defer log.debug("<- processInternal", .{});

    var cmsg = eng.currMsg.?;
    const chnlsimpl: ?*MchnGroup = cmsg.bodyToPtr(MchnGroup);
    const grp = chnlsimpl.?;

    const chgr = eng.acns.channelsGroup(chnlsimpl) catch unreachable;
    defer chgr.deinit();
    _ = eng.acns.removeChannels(chnlsimpl) catch unreachable;

    for (chgr.items) |chN| {
        const trcopt = eng.trgrd_map.getPtr(chN);

        if (trcopt != null) {
            var tc = trcopt.?;

            assert(tc.acn.ctx != null);
            const grpCtx: *MchnGroup = @alignCast(@ptrCast(tc.acn.ctx.?));
            assert(grp == grpCtx);
            tc.resp2ac = false;
            tc.*.deinitTc();
        }
    }

    grp.setReleaseCompleted();
    return;
}

fn sendByeResponse(eng: *Engine) !void {
    // For now - nothing special, just sendToPeer
    // In the future - possibly to disable further sends
    return eng.sendToPeer();
}

fn processMarkedForDelete(eng: *Engine) !bool {
    var removedCount: usize = 0;

    try eng.allTrgChannels(&eng.allChnN);

    for (eng.allChnN.items) |chN| {
        const tcOpt: ?*TriggeredChannel = eng.trgrd_map.getPtr(chN);
        if (tcOpt) |tcPtr| {
            if (tcPtr.mrk4del) {
                log.info("--- delete channel {d}  socket {x}", .{ chN, tcPtr.*.tskt.getSocket() });
                tcPtr.deinitTc();
                _ = eng.trgrd_map.orderedRemove(chN);
                removedCount += 1;
            }
        }
    }

    if (removedCount > 0) {
        log.info("--- removed channels count {d}", .{removedCount});
    }

    return removedCount > 0;
}

fn sendHelloRequest(eng: *Engine) !void {
    eng.createIoClientChannel() catch |err| {
        eng.currMsg.?.bhdr.proto.role = .response;

        const st = status.errorToStatus(err);
        eng.responseFailure(st);
        return;
    };

    return;
}

fn sendWelcomeRequest(eng: *Engine) !void {
    eng.createListenerChannel() catch |err| {
        eng.currMsg.?.bhdr.proto.role = .response;

        const st = status.errorToStatus(err);
        eng.responseFailure(st);
        return;
    };

    return;
}

fn sendBye(eng: *Engine) !void {
    const bye: *Message = eng.currMsg.?;

    if ((bye.bhdr.proto.role == .signal) and (bye.bhdr.proto.oob == .on)) {
        // Initiate close of the channel
        eng.responseFailure(AmpeStatus.channel_closed);
        return;
    }

    return eng.sendToPeer();
}

fn sendToPeer(eng: *Engine) !void {
    const sendMsg: *Message = eng.currMsg.?;
    const chN = sendMsg.bhdr.channel_number;

    var tc = eng.trgrd_map.getPtr(chN);
    if (tc == null) { // Already removed
        return;
    }

    tc.?.tskt.addToSend(sendMsg) catch |err| {
        log.info("addToSend on channel {d} failed with error {any}", .{ chN, err });
        const st = status.errorToStatus(err);
        eng.responseFailure(st);
    };

    eng.currMsg = null;

    return;
}

fn responseFailure(eng: *Engine, failure: AmpeStatus) void {
    defer eng.releaseToPool(&eng.currMsg);

    eng.currMsg.?.bhdr.status = status.status_to_raw(failure);
    eng.currMsg.?.bhdr.proto.origin = .engine;

    const chn = eng.currMsg.?.bhdr.channel_number;
    var trchn = eng.trgrd_map.getPtr(chn);
    assert(trchn != null);
    trchn.?.markForDelete(failure);
    trchn.?.sendToCtx(&eng.currMsg);
    return;
}

fn createDumbChannel(eng: *Engine) TriggeredChannel {
    const ret: TriggeredChannel = .{
        .prnt = eng,
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

fn createIoClientChannel(eng: *Engine) AmpeError!void {
    const hello: *Message = eng.currMsg.?;
    const chN = hello.bhdr.channel_number;
    log.debug("createIoClientChannel -> {d}", .{chN});
    defer log.debug("<- createIoClientChannel {d}", .{chN});

    var tc = createDumbChannel(eng);
    tc.acn = eng.*.acns.activeChannel(chN) catch unreachable;

    try eng.addChannel(tc);

    var sc: internal.SocketCreator = internal.SocketCreator.init(eng.allocator);
    var clSkt: internal.triggeredSkts.IoSkt = .{};
    errdefer clSkt.deinit();

    try clSkt.initClientSide(&eng.pool, hello, &sc);
    eng.currMsg = null;

    _ = try clSkt.tryConnect();

    const tcptr = eng.trgrd_map.getPtr(hello.bhdr.channel_number).?;
    tcptr.disableDelete();
    tcptr.*.resp2ac = true;

    const tskt: internal.triggeredSkts.TriggeredSkt = .{
        .io = clSkt,
    };
    tcptr.*.tskt = tskt;

    return;
}

fn createIoServerChannel(eng: *Engine, lstchn: *TriggeredChannel) AmpeError!void {
    log.debug("createIoServerChannel -> listener channel {d}", .{lstchn.*.acn.chn});

    const chN = lstchn.*.acn.chn;

    defer log.debug("<- createIoServerChannel listener channel {d}", .{chN});

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

    var tc = createDumbChannel(eng);

    const lactChn = lstchn.*.acn;

    // new ActiveChannel for connected client
    // 2DO set mid & inttr  to real values upon receive of HelloRequest/HelloSignal
    const newAcn = eng.createChannelOnT(0, .{}, lactChn.ctx);
    errdefer eng.removeChannelOnT(newAcn.chn);
    tc.acn = newAcn;
    try eng.addChannel(tc);

    var clSkt: internal.triggeredSkts.IoSkt = try internal.triggeredSkts.IoSkt.initServerSide(&eng.pool, newAcn.chn, srvsktOpt.?);
    errdefer clSkt.deinit();

    const srvio: internal.triggeredSkts.TriggeredSkt = .{
        .io = clSkt,
    };

    const tcptr = eng.trgrd_map.getPtr(newAcn.chn).?;
    tcptr.disableDelete();
    tcptr.*.resp2ac = true;
    tcptr.*.tskt = srvio;
    return;
}

fn createListenerChannel(eng: *Engine) AmpeError!void {
    const welcome: *Message = eng.currMsg.?;
    const chN = welcome.bhdr.channel_number;
    log.debug("createListenerChannel -> {d}", .{chN});
    defer log.debug("<- createListenerChannel {d}", .{chN});

    var tc = createDumbChannel(eng);
    tc.acn = eng.*.acns.activeChannel(chN) catch unreachable;

    try eng.addChannel(tc);

    var sc: internal.SocketCreator = internal.SocketCreator.init(eng.allocator);
    var accSkt: internal.triggeredSkts.AcceptSkt = .{};
    errdefer accSkt.deinit();

    accSkt = try internal.triggeredSkts.AcceptSkt.init(welcome, &sc);

    const tcptr = eng.trgrd_map.getPtr(welcome.bhdr.channel_number).?;
    tcptr.disableDelete();
    tcptr.*.resp2ac = true;

    const tskt: internal.triggeredSkts.TriggeredSkt = .{
        .accept = accSkt,
    };
    tcptr.*.tskt = tskt;

    // Listener started, so we can send succ. status to the caller.
    if (tcptr.*.acn.intr.?.role == .request) {
        eng.currMsg.?.bhdr.proto.role = .response;
        eng.currMsg.?.bhdr.status = 0;
        tcptr.sendToCtx(&eng.currMsg);
    }

    return;
}

// Wrappers working with ActiveChannels on the thread
fn removeChannelOnT(eng: *Engine, cn: message.ChannelNumber) void {
    eng.acns.removeChannel(cn);
    var tc = eng.trgrd_map.getPtr(cn);
    if (tc != null) {
        tc.?.markForDelete(status.AmpeStatus.channel_closed);
    }
    return;
}

fn createChannelOnT(eng: *Engine, mid: MessageID, intr: ?message.ProtoFields, ptr: ?*anyopaque) channels.ActiveChannel {
    return eng.acns.createChannel(mid, intr, ptr);
}

fn allTrgChannels(eng: *Engine, chns: *std.ArrayList(message.ChannelNumber)) !void {
    defer log.info(">>> all trg channels count {d}", .{eng.*.trgrd_map.count()});

    chns.resize(0) catch unreachable;

    var it = eng.*.trgrd_map.iterator();
    while (it.next()) |kv_pair| {
        try chns.append(kv_pair.key_ptr.*);
    }

    return;
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

pub const Iterator = struct {
    itrtr: ?Engine.TriggeredChannelsMap.Iterator = null,

    pub fn init(tcm: *Engine.TriggeredChannelsMap) Iterator {
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

const TriggeredChannel = struct {
    prnt: *Engine = undefined,
    acn: channels.ActiveChannel = undefined,
    resp2ac: bool = undefined,
    tskt: TriggeredSkt = undefined,
    exp: internal.triggeredSkts.Triggers = undefined,
    act: internal.triggeredSkts.Triggers = undefined,
    mrk4del: bool = undefined,
    st: ?AmpeStatus = undefined,
    firstRecvFinished: bool = undefined,

    pub fn sendToCtx(tchn: *TriggeredChannel, storedMsg: *?*Message) void {
        if (storedMsg.* == null) {
            return;
        }

        defer tchn.prnt.releaseToPool(storedMsg);

        if ((tchn.acn.ctx == null) or (tchn.resp2ac == false)) {
            return;
        }

        MchnGroup.sendToWaiter(tchn.acn.ctx.?, storedMsg) catch {};

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

        var statusMsg = tchn.prnt.buildStatusSignal(.channel_closed);

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

        const eng = tchn.prnt;

        tchn.tskt.deinit();

        eng.removeChannelOnT(chN);

        if (eng.trgrd_map.orderedRemove(chN)) {
            eng.cnmapChanged = true;
        }

        const trcopt = eng.trgrd_map.getPtr(chN);
        if (trcopt != null) {
            const tc = trcopt.?;
            log.debug("trg channel {d} was not removed", .{tc.*.acn.chn});
        }

        return;
    }

    pub inline fn markForDelete(tchn: *TriggeredChannel, reason: AmpeStatus) void {
        log.debug("marked for delete {d}", .{tchn.*.acn.chn});
        tchn.mrk4del = true;
        tchn.st = reason;
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
        return tchn.tskt.addToSend(sndmsg);
    }

    pub inline fn addForRecv(tchn: *TriggeredChannel, rcvmsg: *Message) !void {
        return tchn.tskt.addForRecv(rcvmsg);
    }

    pub inline fn detach(tchn: *TriggeredChannel) MessageQueue {
        return tchn.tskt.detach();
    }
};

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
const MessageQueue = message.MessageQueue;

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
const Notification = Notifier.Notification;

const Skt = @import("Skt.zig");

const Pool = internal.Pool;

const channels = internal.channels;
const ActiveChannels = channels.ActiveChannels;

const Triggers = internal.triggeredSkts.Triggers;
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;
const UnpackedTriggers = internal.triggeredSkts.UnpackedTriggers;

pub const MchnGroup = @import("MchnGroup.zig");

const poller = internal.poller;

const poll_INFINITE_TIMEOUT: u32 = @import("poller.zig").poll_INFINITE_TIMEOUT;
const poll_SEC_TIMEOUT: u32 = @import("poller.zig").poll_SEC_TIMEOUT;

const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;
const Socket = std.posix.socket_t;
const log = std.log;
const assert = std.debug.assert;

// 2DO  Add processing options for Pool as part of init()
