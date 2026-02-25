// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const poll_INFINITE_TIMEOUT: u32 = std.math.maxInt(i32);
pub const poll_SEC_TIMEOUT: i32 = 1_000;
pub const SeqN = u64;

pub const PollType = enum {
    poll,
    epoll,
    wepoll,
    kqueue,
};

// PollerOs provides a unified interface for multiple OS backends.
// This implementation allows for MUTABLE trigger checks during reconciliation.
pub fn PollerOs(comptime backend: PollType) type {
    return struct {
        const Self = @This();

        chn_seqn_map: std.AutoArrayHashMap(message.ChannelNumber, SeqN),
        seqn_trc_map: std.AutoArrayHashMap(SeqN, TriggeredChannel),
        crseqN: SeqN = 0,

        handle: switch (backend) {
            .poll => void,
            else => std.posix.fd_t,
        },

        event_buffer: switch (backend) {
            .poll => std.ArrayList(std.posix.pollfd),
            .epoll, .wepoll => std.ArrayList(std.os.linux.epoll_event),
            .kqueue => std.ArrayList(std.posix.kevent),
        },

        allocator: Allocator,

        pub fn init(alktr: Allocator) AmpeError!Self {
            var chn_map = std.AutoArrayHashMap(message.ChannelNumber, SeqN).init(alktr);
            errdefer chn_map.deinit();
            chn_map.ensureTotalCapacity(256) catch return AmpeError.AllocationFailed;

            var seq_map = std.AutoArrayHashMap(SeqN, TriggeredChannel).init(alktr);
            errdefer seq_map.deinit();
            seq_map.ensureTotalCapacity(256) catch return AmpeError.AllocationFailed;

            const h = switch (backend) {
                .poll => {},
                .epoll => std.posix.epoll_create1(0) catch return AmpeError.AllocationFailed,
                .kqueue => std.posix.kqueue() catch return AmpeError.AllocationFailed,
                .wepoll => epoll_shim_create(),
            };

            const buf = switch (backend) {
                .poll => std.ArrayList(std.posix.pollfd).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
                .epoll, .wepoll => std.ArrayList(std.os.linux.epoll_event).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
                .kqueue => std.ArrayList(std.posix.kevent).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
            };

            return .{
                .allocator = alktr,
                .chn_seqn_map = chn_map,
                .seqn_trc_map = seq_map,
                .handle = h,
                .event_buffer = buf,
            };
        }

        fn osSync(self: *Self, fd: std.posix.fd_t, seq: SeqN, exp: Triggers, op: enum { add, mod, del }) AmpeError!void {
            if (backend == .poll) return;
            switch (backend) {
                .epoll, .wepoll => {
                    var ev = std.os.linux.epoll_event{
                        .events = mapToEpoll(exp),
                        .data = .{ .u64 = seq },
                    };
                    const action: u32 = switch (op) {
                        .add => std.os.linux.EPOLL.CTL_ADD,
                        .mod => std.os.linux.EPOLL.CTL_MOD,
                        .del => std.os.linux.EPOLL.CTL_DEL,
                    };
                    std.posix.epoll_ctl(self.handle, action, fd, if (op == .del) null else &ev) catch |e| {
                        switch (e) {
                            // MOD on fd not yet registered -> fall back to ADD
                            error.FileDescriptorNotRegistered => {
                                if (op == .del) return; // nothing to remove
                                if (op == .mod) {
                                    std.posix.epoll_ctl(self.handle, std.os.linux.EPOLL.CTL_ADD, fd, &ev) catch return AmpeError.CommunicationFailed;
                                    return;
                                }
                                return AmpeError.CommunicationFailed;
                            },
                            // ADD on fd already registered -> fall back to MOD
                            error.FileDescriptorAlreadyPresentInSet => {
                                if (op == .add) {
                                    std.posix.epoll_ctl(self.handle, std.os.linux.EPOLL.CTL_MOD, fd, &ev) catch return AmpeError.CommunicationFailed;
                                    return;
                                }
                                return AmpeError.CommunicationFailed;
                            },
                            else => return AmpeError.CommunicationFailed,
                        }
                    };
                },
                .kqueue => {
                    // kqueue EV_ADD is idempotent (adds or modifies)
                    var evs: [2]std.posix.kevent = undefined;
                    const count = mapToKqueue(exp, seq, fd, &evs, op == .del);
                    if (count > 0) std.posix.kevent(self.handle, evs[0..count], &.{}, null) catch return AmpeError.CommunicationFailed;
                },
                else => unreachable,
            }
        }

        pub fn attachChannel(self: *Self, tchn: *TriggeredChannel) AmpeError!bool {
            const chN = tchn.acn.chn;
            if (self.chn_seqn_map.contains(chN)) return AmpeError.InvalidChannelNumber;

            self.crseqN += 1;
            const seqN = self.crseqN;

            if (backend != .poll) {
                // Dumb channels have no socket yet; they will be registered
                // with epoll on first reconciliation in waitTriggers.
                if (tchn.tskt.getSocket()) |socket| {
                    try self.osSync(@intCast(socket), seqN, tchn.tskt.triggers() catch Triggers{}, .add);
                }
            }

            self.chn_seqn_map.put(chN, seqN) catch return AmpeError.AllocationFailed;
            self.seqn_trc_map.put(seqN, tchn.*) catch return AmpeError.AllocationFailed;
            return true;
        }

        pub inline fn trgChannel(self: *Self, chn: message.ChannelNumber) ?*TriggeredChannel {
            const seqN = self.chn_seqn_map.get(chn) orelse return null;
            return self.seqn_trc_map.getPtr(seqN);
        }

        pub fn deleteGroup(self: *Self, chnls: std.ArrayList(message.ChannelNumber)) AmpeError!bool {
            var result = false;
            for (chnls.items) |chN| {
                const seqKV = self.chn_seqn_map.fetchSwapRemove(chN) orelse continue;
                var kv = self.seqn_trc_map.fetchSwapRemove(seqKV.value) orelse unreachable;
                if (backend != .poll) {
                    const socket = kv.value.tskt.getSocket() orelse 0;
                    if (socket != 0) try self.osSync(@intCast(socket), seqKV.value, .{}, .del);
                }
                kv.value.tskt.deinit();
                result = true;
            }
            return result;
        }

        pub fn deleteMarked(self: *Self) !bool {
            var result = false;
            var i: usize = self.chn_seqn_map.count();
            while (i > 0) {
                i -= 1;
                const chN = self.chn_seqn_map.keys()[i];
                const seqN = self.chn_seqn_map.values()[i];
                const tcPtr = self.seqn_trc_map.getPtr(seqN).?;
                if (!tcPtr.mrk4del) continue;

                if (backend != .poll) {
                    const socket = tcPtr.tskt.getSocket() orelse 0;
                    if (socket != 0) try self.osSync(@intCast(socket), seqN, .{}, .del);
                }
                tcPtr.updateReceiver();
                tcPtr.deinit();
                tcPtr.engine.removeChannelOnT(chN);
                _ = self.chn_seqn_map.swapRemove(chN);
                _ = self.seqn_trc_map.swapRemove(seqN);
                result = true;
            }
            return result;
        }

        pub fn deleteAll(self: *Self) void {
            const vals = self.seqn_trc_map.values();
            for (vals) |*tc| {
                if (backend != .poll) {
                    const socket = tc.tskt.getSocket() orelse 0;
                    if (socket != 0) {
                        const seqN = self.chn_seqn_map.get(tc.acn.chn) orelse 0;
                        self.osSync(@intCast(socket), seqN, .{}, .del) catch {};
                    }
                }
                tc.tskt.deinit();
            }
            self.event_buffer.deinit(self.allocator);
            if (backend != .poll) std.posix.close(self.handle);
            self.seqn_trc_map.deinit();
            self.chn_seqn_map.deinit();
        }

        pub fn waitTriggers(self: *Self, timeout: i32) AmpeError!Triggers {
            if (backend == .poll) self.event_buffer.clearRetainingCapacity();

            var total_act = Triggers{};

            // RECONCILIATION LOOP: Using pointer iteration to allow MUTABLE triggers()
            const values = self.seqn_trc_map.values();
            for (values) |*tc| {
                tc.disableDelete();

                // triggers() is now allowed to modify the socket (e.g., pulling from pool)
                const new_exp = tc.tskt.triggers() catch Triggers{};

                // Initialize activity with internal triggers (e.g., pool readiness)
                tc.act = .{ .pool = new_exp.pool };
                total_act = total_act.lor(tc.act);

                if (backend == .poll) {
                    const socket = tc.tskt.getSocket() orelse 0;
                    self.event_buffer.append(self.allocator, .{
                        .fd = if (socket != 0) @intCast(socket) else -1,
                        .events = mapToPoll(new_exp),
                        .revents = 0,
                    }) catch return AmpeError.AllocationFailed;
                    tc.exp = new_exp;
                } else if (!tc.exp.eql(new_exp)) {
                    const socket = tc.tskt.getSocket() orelse 0;
                    if (socket != 0) {
                        const seq = self.chn_seqn_map.get(tc.acn.chn).?;
                        try self.osSync(@intCast(socket), seq, new_exp, .mod);
                    }
                    tc.exp = new_exp;
                }
            }

            if (self.seqn_trc_map.count() == 0) return .{};

            // If we already have internal activity (like pool readiness), don't block in the OS wait.
            const wait_timeout = if (total_act.off()) timeout else 0;

            switch (backend) {
                .poll => {
                    const n = std.posix.poll(self.event_buffer.items, wait_timeout) catch return AmpeError.CommunicationFailed;
                    if (n == 0) {
                        total_act.timeout = .on;
                    } else {
                        for (self.event_buffer.items, self.seqn_trc_map.values()) |pfd, *tc| {
                            const os_act = mapFromPoll(pfd.revents, tc.exp);
                            tc.act = tc.act.lor(os_act);
                            total_act = total_act.lor(tc.act);
                        }
                    }
                },
                .epoll, .wepoll => {
                    self.event_buffer.ensureTotalCapacity(self.allocator, self.seqn_trc_map.count()) catch return AmpeError.AllocationFailed;
                    const n = std.posix.epoll_wait(self.handle, self.event_buffer.unusedCapacitySlice(), wait_timeout);
                    if (n == 0) {
                        total_act.timeout = .on;
                    } else {
                        for (self.event_buffer.unusedCapacitySlice()[0..n]) |ev| {
                            if (self.seqn_trc_map.getPtr(ev.data.u64)) |tc| {
                                const os_act = mapFromEpoll(ev.events, tc.exp);
                                tc.act = tc.act.lor(os_act);
                                total_act = total_act.lor(tc.act);
                            }
                        }
                    }
                },
                .kqueue => {
                    self.event_buffer.ensureTotalCapacity(self.allocator, self.seqn_trc_map.count()) catch return AmpeError.AllocationFailed;
                    const n = std.posix.kevent(self.handle, &.{}, self.event_buffer.unusedCapacitySlice(), null) catch return AmpeError.CommunicationFailed;
                    if (n == 0) {
                        total_act.timeout = .on;
                    } else {
                        for (self.event_buffer.unusedCapacitySlice()[0..n]) |ev| {
                            if (self.seqn_trc_map.getPtr(@intCast(ev.udata))) |tc| {
                                const os_act = mapFromKqueue(ev, tc.exp);
                                tc.act = tc.act.lor(os_act);
                                total_act = total_act.lor(tc.act);
                            }
                        }
                    }
                },
            }
            return total_act;
        }

        pub fn iterator(self: *Self) TcIterator {
            var res = TcIterator.init(&self.seqn_trc_map);
            res.reset();
            return res;
        }
    };
}

// --- Mask Mapping ---

fn mapToPoll(exp: Triggers) i16 {
    var ev: i16 = 0;
    if (exp.recv == .on or exp.accept == .on or exp.notify == .on) ev |= std.posix.POLL.IN;
    if (exp.send == .on or exp.connect == .on) ev |= std.posix.POLL.OUT;
    return ev;
}

fn mapFromPoll(rev: i16, exp: Triggers) Triggers {
    var act = Triggers{ .pool = exp.pool };
    if ((rev & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) act.err = .on;
    if ((rev & std.posix.POLL.IN) != 0) {
        if (exp.recv == .on) act.recv = .on else if (exp.notify == .on) act.notify = .on else if (exp.accept == .on) act.accept = .on;
    }
    if ((rev & std.posix.POLL.OUT) != 0) {
        if (exp.send == .on) act.send = .on else if (exp.connect == .on) act.connect = .on;
    }
    return act;
}

fn mapToEpoll(exp: Triggers) u32 {
    var ev: u32 = 0;
    if (exp.recv == .on or exp.accept == .on or exp.notify == .on) ev |= std.os.linux.EPOLL.IN;
    if (exp.send == .on or exp.connect == .on) ev |= std.os.linux.EPOLL.OUT;
    ev |= (std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.PRI);
    return ev;
}

fn mapFromEpoll(rev: u32, exp: Triggers) Triggers {
    var act = Triggers{ .pool = exp.pool };
    if ((rev & (std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.RDHUP)) != 0) act.err = .on;
    if ((rev & std.os.linux.EPOLL.IN) != 0) {
        if (exp.recv == .on) act.recv = .on else if (exp.notify == .on) act.notify = .on else if (exp.accept == .on) act.accept = .on;
    }
    if ((rev & std.os.linux.EPOLL.OUT) != 0) {
        if (exp.send == .on) act.send = .on else if (exp.connect == .on) act.connect = .on;
    }
    return act;
}

fn mapToKqueue(exp: Triggers, seq: SeqN, fd: std.posix.fd_t, evs: []std.posix.kevent, is_del: bool) usize {
    var i: usize = 0;
    const flags = if (is_del) std.posix.system.EV.DELETE else std.posix.system.EV.ADD | std.posix.system.EV.ENABLE;
    if (exp.recv == .on or exp.accept == .on or exp.notify == .on) {
        evs[i] = .{ .ident = @intCast(fd), .filter = std.posix.system.EVFILT.READ, .flags = flags, .fflags = 0, .data = 0, .udata = @intCast(seq) };
        i += 1;
    }
    if (exp.send == .on or exp.connect == .on) {
        evs[i] = .{ .ident = @intCast(fd), .filter = std.posix.system.EVFILT.WRITE, .flags = flags, .fflags = 0, .data = 0, .udata = @intCast(seq) };
        i += 1;
    }
    return i;
}

fn mapFromKqueue(ev: std.posix.kevent, exp: Triggers) Triggers {
    var act = Triggers{ .pool = exp.pool };
    if (ev.flags & std.posix.system.EV.ERROR != 0) act.err = .on;
    if (ev.filter == std.posix.system.EVFILT.READ) {
        if (exp.recv == .on) act.recv = .on else if (exp.notify == .on) act.notify = .on else if (exp.accept == .on) act.accept = .on;
    }
    if (ev.filter == std.posix.system.EVFILT.WRITE) {
        if (exp.send == .on) act.send = .on else if (exp.connect == .on) act.connect = .on;
    }
    return act;
}

fn epoll_shim_create() std.posix.fd_t {
    return -1;
}

pub const TcIterator = struct {
    itrtr: std.AutoArrayHashMap(SeqN, TriggeredChannel).Iterator,
    pub fn init(tcm: *std.AutoArrayHashMap(SeqN, TriggeredChannel)) TcIterator {
        return .{ .itrtr = tcm.iterator() };
    }
    pub fn next(self: *TcIterator) ?*TriggeredChannel {
        const entry = self.itrtr.next() orelse return null;
        return entry.value_ptr;
    }
    pub fn reset(self: *TcIterator) void {
        self.itrtr.reset();
    }
};

const tofu = @import("../tofu.zig");
const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;
const message = tofu.message;
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;

const internal = @import("internal.zig");
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;
const Triggers = internal.triggeredSkts.Triggers;

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const log = std.log;
