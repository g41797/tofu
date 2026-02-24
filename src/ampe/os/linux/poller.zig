// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const poll_INFINITE_TIMEOUT: u32 = std.math.maxInt(i32);
pub const poll_SEC_TIMEOUT: i32 = 1_000;

pub const Poller = union(enum) {
    poll: Poll,

    pub fn waitTriggers(self: *Poller, it: ?TcIterator, timeout: i32) AmpeError!Triggers {
        const ret: Triggers = switch (self.*) {
            .poll => try self.*.poll.waitTriggers(it, timeout),
        };

        if (DBG) {
            const utrgrs: internal.triggeredSkts.UnpackedTriggers = internal.triggeredSkts.UnpackedTriggers.fromTriggers(ret);
            _ = utrgrs;
        }

        return ret;
    }

    pub fn deinit(self: *const Poller) void {
        switch (self.*) {
            .poll => @constCast(&self.*.poll).deinit(),
        }
        return;
    }
};

pub const Poll = struct {
    allocator: Allocator = undefined,
    pollfdVtor: std.ArrayList(std.posix.pollfd) = undefined,
    it: ?TcIterator = null,

    pub fn init(allocator: Allocator) !Poll {
        var ret: Poll = .{
            .it = null,
        };

        ret.allocator = allocator;

        ret.pollfdVtor = try std.ArrayList(std.posix.pollfd).initCapacity(ret.allocator, 256);
        errdefer ret.pollfdVtor.deinit(ret.allocator);

        return ret;
    }

    pub fn deinit(pl: *Poll) void {
        pl.*.pollfdVtor.deinit(pl.*.allocator);
        return;
    }

    pub fn waitTriggers(pl: *Poll, it: ?TcIterator, timeout: i32) AmpeError!Triggers {
        if ((pl.*.it == null) and (it == null)) {
            return AmpeError.NotAllowed;
        }

        if (it != null) {
            pl.*.it = it;
        }

        pl.*.it.?.reset();

        const polln: usize = try pl.*.buildFds();
        if (polln == 0) {
            return .{};
        }

        const tmout: bool = try pl.*.poll(timeout);

        if (tmout) {
            const tmouttrgs: Triggers = .{
                .timeout = .on,
            };
            return tmouttrgs;
        }

        return try pl.*.storeTriggers();
    }

    fn buildFds(pl: *Poll) !usize {
        var notifActivated: bool = false;

        pl.*.pollfdVtor.items.len = 0;

        var tcptr: ?*TriggeredChannel = pl.*.it.?.next();

        while (tcptr != null) {
            const tc: *TriggeredChannel = tcptr.?;

            tc.*.disableDelete();

            tcptr = pl.*.it.?.next();

            tc.*.exp = try tc.*.tskt.triggers();
            tc.*.act = .{};

            var events: i16 = 0;

            if (!tc.*.exp.off()) {
                if (DBG) {
                    const utrgs: internal.triggeredSkts.UnpackedTriggers = internal.triggeredSkts.UnpackedTriggers.fromTriggers(tc.*.exp);
                    _ = utrgs;
                }

                if (tc.*.exp.notify == .on) {
                    assert(tc.*.acn.chn == message.SpecialMaxChannelNumber);
                    notifActivated = true;
                    events |= std.posix.POLL.IN;
                }
                if (tc.*.exp.send == .on) {
                    events |= std.posix.POLL.OUT;
                }
                if (tc.*.exp.connect == .on) {
                    events |= std.posix.POLL.OUT;
                }
                if (tc.*.exp.recv == .on) {
                    events |= std.posix.POLL.IN;
                }
                if (tc.*.exp.accept == .on) {
                    events |= std.posix.POLL.IN;
                }
                if (tc.*.exp.pool == .off) {
                    assert(events != 0);
                }
            }

            const fd = tc.*.tskt.getSocket() orelse -1;
            pl.*.pollfdVtor.append(pl.*.allocator, .{ .fd = fd, .events = events, .revents = 0 }) catch {
                return AmpeError.AllocationFailed;
            };
        }

        if (!notifActivated) {
            return AmpeError.NotificationDisabled;
        }

        return pl.*.pollfdVtor.items.len;
    }

    fn poll(pl: *Poll, timeout: i32) !bool {
        const triggered: usize = std.posix.poll(pl.*.pollfdVtor.items, timeout) catch {
            return AmpeError.CommunicationFailed;
        };

        return triggered == 0;
    }

    fn storeTriggers(pl: *Poll) !Triggers {
        pl.*.it.?.reset();

        var ret: Triggers = .{};

        var tcptr: ?*TriggeredChannel = pl.*.it.?.next();
        var indx: usize = 0;

        while (tcptr != null) : (indx += 1) {
            const tc: *TriggeredChannel = tcptr.?;

            tcptr = pl.*.it.?.next();

            tc.*.act = .{
                .pool = tc.*.exp.pool,
            };

            while (true) {
                const revents: i16 = pl.*.pollfdVtor.items[indx].revents;

                if (revents == 0) {
                    break;
                }

                if ((revents & err_mask) != 0) {
                    tc.*.act.err = .on;
                    if (tc.*.exp.notify == .on) {
                        tc.*.act.notify = .on;
                        break;
                    }
                    if (tc.*.exp.accept == .on) {
                        tc.*.act.accept = .on;
                        break;
                    }
                    if (tc.*.exp.connect == .on) {
                        tc.*.act.connect = .on;
                        break;
                    }
                    if (tc.*.exp.send == .on) {
                        tc.*.act.send = .on;
                    }
                    if (tc.*.exp.recv == .on) {
                        tc.*.act.recv = .on;
                    }
                    break;
                }

                if ((revents & std.posix.POLL.IN != 0) or (revents & std.posix.POLL.RDNORM != 0)) {
                    if (tc.*.exp.recv == .on) {
                        tc.*.act.recv = .on;
                    } else if (tc.*.exp.notify == .on) {
                        tc.*.act.notify = .on;
                    } else if (tc.*.exp.accept == .on) {
                        tc.*.act.accept = .on;
                    }
                }

                if (revents & std.posix.POLL.OUT != 0) {
                    if (tc.*.exp.send == .on) {
                        tc.*.act.send = .on;
                    } else if (tc.*.exp.connect == .on) {
                        tc.*.act.connect = .on;
                    }
                }

                assert(!tc.*.act.off());

                break;
            }

            ret = ret.lor(tc.*.act);
        }

        return ret;
    }
};

const err_mask: i16 = std.posix.POLL.ERR | std.posix.POLL.NVAL | std.posix.POLL.HUP;

pub const PolledTrChnls = struct {
    // [Channel Number = SeqN]
    chn_seqn_map: std.AutoArrayHashMap(message.ChannelNumber, SeqN) = undefined,

    crseqN: SeqN = undefined,

    // [SeqN - TriggeredChannel]
    seqn_trc_map: std.AutoArrayHashMap(SeqN, TriggeredChannel) = undefined,

    pll: Poll = .{},

    pub fn init(alktr: Allocator) AmpeError!PolledTrChnls {
        var chn_seqn_map = std.AutoArrayHashMap(message.ChannelNumber, SeqN).init(alktr);
        errdefer chn_seqn_map.deinit();
        chn_seqn_map.ensureTotalCapacity(256) catch {
            return AmpeError.AllocationFailed;
        };

        var seqn_trc_map = std.AutoArrayHashMap(SeqN, TriggeredChannel).init(alktr);
        errdefer seqn_trc_map.deinit();
        seqn_trc_map.ensureTotalCapacity(256) catch {
            return AmpeError.AllocationFailed;
        };

        const pll: Poll = Poll.init(alktr) catch {
            return AmpeError.AllocationFailed;
        };

        return .{
            .seqn_trc_map = seqn_trc_map,
            .chn_seqn_map = chn_seqn_map,
            .crseqN = 0,
            .pll = pll,
        };
    }

    pub fn waitTriggers(ptcs: *PolledTrChnls, timeout: i32) AmpeError!Triggers {
        return ptcs.*.pll.waitTriggers(ptcs.*.iterator(), timeout);
    }

    pub fn attachChannel(ptcs: *PolledTrChnls, tchn: TriggeredChannel) AmpeError!bool {
        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        const chN: message.ChannelNumber = tchn.acn.chn;

        if (ptcs.*.chn_seqn_map.contains(chN)) {
            log.warn("channel {d} already exists", .{chN});
            return AmpeError.InvalidChannelNumber;
        }

        ptcs.*.crseqN += 1;

        const seqN: SeqN = ptcs.*.crseqN;

        ptcs.*.chn_seqn_map.put(chN, seqN) catch {
            return AmpeError.AllocationFailed;
        };

        ptcs.*.seqn_trc_map.put(seqN, tchn) catch {
            return AmpeError.AllocationFailed;
        };

        assert(ptcs.*.trgChannel(chN) != null);

        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        return true;
    }

    pub inline fn trgChannel(ptcs: *PolledTrChnls, chn: message.ChannelNumber) ?*TriggeredChannel {
        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        const seqN: SeqN = ptcs.*.chn_seqn_map.get(chn) orelse return null;

        return ptcs.*.seqn_trc_map.getPtr(seqN);
    }

    pub fn iterator(ptcs: *PolledTrChnls) TcIterator {
        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        var result: TcIterator = TcIterator.init(&ptcs.*.seqn_trc_map);
        result.reset();
        return result;
    }

    pub fn deleteGroup(ptcs: *PolledTrChnls, chnls: std.ArrayList(message.ChannelNumber)) AmpeError!bool {
        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        var result: bool = false;

        for (chnls.items) |chN| {
            const seqKV = ptcs.*.chn_seqn_map.fetchSwapRemove(chN) orelse continue;
            var kv = ptcs.*.seqn_trc_map.fetchSwapRemove(seqKV.value) orelse unreachable;
            kv.value.tskt.deinit();
            result = true;
        }

        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        return result;
    }

    pub fn deleteMarked(ptcs: *PolledTrChnls) !bool {
        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        var result: bool = false;

        var i: usize = ptcs.*.chn_seqn_map.count();

        while (i > 0) {
            i -= 1;

            const seqN = ptcs.*.chn_seqn_map.values()[i];
            const tcPtr: *TriggeredChannel = ptcs.*.seqn_trc_map.getPtr(seqN) orelse unreachable;

            if (!tcPtr.*.mrk4del) {
                continue;
            }

            tcPtr.*.updateReceiver();
            tcPtr.*.deinit();

            const chN = tcPtr.*.acn.chn;
            tcPtr.*.engine.*.removeChannelOnT(chN);
            _ = ptcs.*.chn_seqn_map.swapRemove(chN);
            _ = ptcs.*.seqn_trc_map.swapRemove(seqN);
            result = true;
        }

        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        return result;
    }

    pub fn deleteAll(ptcs: *PolledTrChnls) void {
        assert(ptcs.*.chn_seqn_map.count() == ptcs.*.seqn_trc_map.count());

        ptcs.*.pll.deinit();

        var itr: TcIterator = ptcs.*.iterator();

        var tcopt: ?*TriggeredChannel = itr.next();

        while (tcopt != null) : (tcopt = itr.next()) {
            tcopt.?.*.tskt.deinit();
        }

        ptcs.*.seqn_trc_map.deinit();
        ptcs.*.chn_seqn_map.deinit();

        return;
    }
};

pub const TcIterator = struct {
    itrtr: ?std.AutoArrayHashMap(SeqN, TriggeredChannel).Iterator = null,

    pub fn init(tcm: anytype) TcIterator {
        return .{
            .itrtr = tcm.iterator(),
        };
    }

    pub fn next(itr: *TcIterator) ?*TriggeredChannel {
        if (itr.itrtr != null) {
            const entry = itr.itrtr.?.next();
            if (entry) |entr| {
                return entr.value_ptr;
            }
        }
        return null;
    }

    pub fn reset(itr: *TcIterator) void {
        if (itr.itrtr != null) {
            itr.itrtr.?.reset();
        }
        return;
    }
};

const SeqN = u64;

const tofu = @import("../../../tofu.zig");
const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;
const message = tofu.message;
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;

const internal = @import("../../internal.zig");
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;
const Triggers = internal.triggeredSkts.Triggers;

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const log = std.log;
