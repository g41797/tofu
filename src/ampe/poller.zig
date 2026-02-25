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
        seqn_trc_map: std.AutoArrayHashMap(SeqN, *TriggeredChannel),
        crseqN: SeqN = 0,

        handle: switch (backend) {
            .poll => void,
            else => *anyopaque,
        },

        event_buffer: switch (backend) {
            .poll => std.ArrayList(std.posix.pollfd),
            .epoll => std.ArrayList(std.os.linux.epoll_event),
            .wepoll => if (builtin.os.tag == .windows) std.ArrayList(WepollEvent) else std.ArrayList(std.os.linux.epoll_event),
            .kqueue => std.ArrayList(std.posix.kevent),
        },

        allocator: Allocator,

        pub fn init(alktr: Allocator) AmpeError!Self {
            var chn_map = std.AutoArrayHashMap(message.ChannelNumber, SeqN).init(alktr);
            errdefer chn_map.deinit();
            chn_map.ensureTotalCapacity(256) catch return AmpeError.AllocationFailed;

            var seq_map = std.AutoArrayHashMap(SeqN, *TriggeredChannel).init(alktr);
            errdefer seq_map.deinit();
            seq_map.ensureTotalCapacity(256) catch return AmpeError.AllocationFailed;

            const h = switch (backend) {
                .poll => {},
                .epoll => @as(*anyopaque, @ptrFromInt(@as(usize, @intCast(std.posix.epoll_create1(0) catch return AmpeError.AllocationFailed)))),
                .kqueue => @as(*anyopaque, @ptrFromInt(@as(usize, @intCast(std.posix.kqueue() catch return AmpeError.AllocationFailed)))),
                .wepoll => if (builtin.os.tag == .windows) epoll_create1(0) orelse return AmpeError.AllocationFailed else return AmpeError.NotAllowed,
            };

            const buf = switch (backend) {
                .poll => std.ArrayList(std.posix.pollfd).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
                .epoll => std.ArrayList(std.os.linux.epoll_event).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
                .wepoll => if (builtin.os.tag == .windows) std.ArrayList(WepollEvent).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed else std.ArrayList(std.os.linux.epoll_event).initCapacity(alktr, 256) catch return AmpeError.AllocationFailed,
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

        fn osSync(self: *Self, fd: anytype, seq: SeqN, exp: Triggers, op: enum { add, mod, del }) AmpeError!void {
            if (backend == .poll) return;
            switch (backend) {
                .epoll, .wepoll => {
                    var ev = if (backend == .wepoll and builtin.os.tag == .windows)
                        WepollEvent{
                            .events = mapToEpoll(exp),
                            .data = seq,
                        }
                    else
                        std.os.linux.epoll_event{
                            .events = mapToEpoll(exp),
                            .data = .{ .u64 = seq },
                        };
                    const action: i32 = if (backend == .wepoll)
                        switch (op) {
                            .add => 1,
                            .mod => 2,
                            .del => 3,
                        }
                    else switch (op) {
                        .add => std.os.linux.EPOLL.CTL_ADD,
                        .mod => std.os.linux.EPOLL.CTL_MOD,
                        .del => std.os.linux.EPOLL.CTL_DEL,
                    };
                    if (backend == .epoll) {
                        const ep_ev: *std.os.linux.epoll_event = @ptrCast(&ev);
                        std.posix.epoll_ctl(@intCast(@intFromPtr(self.handle)), @intCast(action), @intCast(fd), if (op == .del) null else ep_ev) catch |e| {
                            switch (e) {
                                // MOD on fd not yet registered -> fall back to ADD
                                error.FileDescriptorNotRegistered => {
                                    if (op == .del) return; // nothing to remove
                                    if (op == .mod) {
                                        std.posix.epoll_ctl(@intCast(@intFromPtr(self.handle)), std.os.linux.EPOLL.CTL_ADD, @intCast(fd), ep_ev) catch return AmpeError.CommunicationFailed;
                                        return;
                                    }
                                    return AmpeError.CommunicationFailed;
                                },
                                // ADD on fd already registered -> fall back to MOD
                                error.FileDescriptorAlreadyPresentInSet => {
                                    if (op == .add) {
                                        std.posix.epoll_ctl(@intCast(@intFromPtr(self.handle)), std.os.linux.EPOLL.CTL_MOD, @intCast(fd), ep_ev) catch return AmpeError.CommunicationFailed;
                                        return;
                                    }
                                    return AmpeError.CommunicationFailed;
                                },
                                else => return AmpeError.CommunicationFailed,
                            }
                        };
                    } else {
                        if (builtin.os.tag == .windows) {
                            const ep_ev: *WepollEvent = @ptrCast(&ev);
                            const res = epoll_ctl(self.handle, action, @intCast(fd), ep_ev);
                            if (res != 0) {
                                const err = std.os.windows.kernel32.GetLastError();
                                if (@intFromEnum(err) == 1168) { // ERROR_NOT_FOUND
                                    if (op == .del) return;
                                    if (op == .mod) {
                                        if (epoll_ctl(self.handle, 1, @intCast(fd), ep_ev) == 0) return;
                                    }
                                }
                                log.warn("epoll_ctl failed: op={d} fd={d} err={any}", .{ action, fd, err });
                                return AmpeError.CommunicationFailed;
                            }
                        }
                    }
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

            // Allocate a stable heap copy
            const tchn_heap = self.allocator.create(TriggeredChannel) catch return AmpeError.AllocationFailed;
            tchn_heap.* = tchn.*;

            if (backend != .poll) {
                // Dumb channels have no socket yet; they will be registered
                // with epoll on first reconciliation in waitTriggers.
                if (tchn_heap.tskt.getSocket()) |socket| {
                    try self.osSync(toFd(socket), seqN, tchn_heap.tskt.triggers() catch Triggers{}, .add);
                }
            }

            self.chn_seqn_map.put(chN, seqN) catch {
                self.allocator.destroy(tchn_heap);
                return AmpeError.AllocationFailed;
            };
            self.seqn_trc_map.put(seqN, tchn_heap) catch {
                _ = self.chn_seqn_map.swapRemove(chN);
                self.allocator.destroy(tchn_heap);
                return AmpeError.AllocationFailed;
            };
            return true;
        }

        pub inline fn trgChannel(self: *Self, chn: message.ChannelNumber) ?*TriggeredChannel {
            const seqN = self.chn_seqn_map.get(chn) orelse return null;
            return self.seqn_trc_map.get(seqN) orelse null;
        }

        pub fn deleteGroup(self: *Self, chnls: std.ArrayList(message.ChannelNumber)) AmpeError!bool {
            var result = false;
            for (chnls.items) |chN| {
                const seqKV = self.chn_seqn_map.fetchSwapRemove(chN) orelse continue;
                var kv = self.seqn_trc_map.fetchSwapRemove(seqKV.value) orelse unreachable;
                if (backend != .poll) {
                    const socket = kv.value.tskt.getSocket();
                    if (isSocketSet(socket)) try self.osSync(toFd(socket.?), seqKV.value, .{}, .del);
                }
                kv.value.tskt.deinit();
                self.allocator.destroy(kv.value);
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
                const tcPtr = self.seqn_trc_map.get(seqN).?;
                if (!tcPtr.mrk4del) continue;

                if (backend != .poll) {
                    const socket = tcPtr.tskt.getSocket();
                    if (isSocketSet(socket)) try self.osSync(toFd(socket.?), seqN, .{}, .del);
                }
                tcPtr.updateReceiver();
                tcPtr.deinit();
                tcPtr.engine.removeChannelOnT(chN);
                _ = self.chn_seqn_map.swapRemove(chN);
                _ = self.seqn_trc_map.swapRemove(seqN);
                self.allocator.destroy(tcPtr);
                result = true;
            }
            return result;
        }

        pub fn deleteAll(self: *Self) void {
            const vals = self.seqn_trc_map.values();
            for (vals) |tc| {
                if (backend != .poll) {
                    const socket = tc.tskt.getSocket();
                    if (isSocketSet(socket)) {
                        const seq = self.chn_seqn_map.get(tc.acn.chn) orelse 0;
                        self.osSync(toFd(socket.?), seq, .{}, .del) catch {};
                    }
                }
                tc.tskt.deinit();
                self.allocator.destroy(tc);
            }
            self.event_buffer.deinit(self.allocator);
            if (backend != .poll) {
                if (backend == .wepoll) {
                    if (builtin.os.tag == .windows) {
                        _ = epoll_close(self.handle);
                    }
                } else if (backend == .epoll or backend == .kqueue) {
                    std.posix.close(@intCast(@intFromPtr(self.handle)));
                }
            }
            self.seqn_trc_map.deinit();
            self.chn_seqn_map.deinit();
            self.crseqN = 0;
        }

        pub fn waitTriggers(self: *Self, timeout: i32) AmpeError!Triggers {
            self.event_buffer.clearRetainingCapacity();

            var total_act = Triggers{};

            // RECONCILIATION LOOP
            const values = self.seqn_trc_map.values();
            for (values) |tc| {
                tc.tskt.refreshPointers();
                tc.disableDelete();

                // triggers() is now allowed to modify the socket (e.g., pulling from pool)
                const new_exp = tc.tskt.triggers() catch Triggers{};

                // Initialize activity with internal triggers (e.g., pool readiness)
                tc.act = .{ .pool = new_exp.pool };
                total_act = total_act.lor(tc.act);

                if (backend == .poll) {
                    const socket = tc.tskt.getSocket();
                    self.event_buffer.append(self.allocator, .{
                        .fd = if (isSocketSet(socket)) toFd(socket.?) else -1,
                        .events = mapToPoll(new_exp),
                        .revents = 0,
                    }) catch return AmpeError.AllocationFailed;
                    tc.exp = new_exp;
                } else if (!tc.exp.eql(new_exp)) {
                    const socket = tc.tskt.getSocket();
                    if (isSocketSet(socket)) {
                        const seq = self.chn_seqn_map.get(tc.acn.chn).?;
                        try self.osSync(toFd(socket.?), seq, new_exp, .mod);
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
                        for (self.event_buffer.items, self.seqn_trc_map.values()) |pfd, tc| {
                            const os_act = mapFromPoll(pfd.revents, tc.exp);
                            tc.act = tc.act.lor(os_act);
                            total_act = total_act.lor(tc.act);
                        }
                    }
                },
                .epoll, .wepoll => {
                    self.event_buffer.ensureTotalCapacity(self.allocator, self.seqn_trc_map.count()) catch return AmpeError.AllocationFailed;
                    const n: usize = if (backend == .epoll)
                        std.posix.epoll_wait(@intCast(@intFromPtr(self.handle)), self.event_buffer.unusedCapacitySlice(), wait_timeout)
                    else if (builtin.os.tag == .windows)
                        @intCast(epoll_wait(self.handle, @ptrCast(self.event_buffer.unusedCapacitySlice().ptr), @intCast(self.event_buffer.unusedCapacitySlice().len), wait_timeout))
                    else
                        return AmpeError.NotAllowed;

                    if (n == 0) {
                        total_act.timeout = .on;
                    } else {
                        if (backend == .wepoll and builtin.os.tag == .windows) {
                            for (self.event_buffer.unusedCapacitySlice()[0..n]) |ev| {
                                if (self.seqn_trc_map.get(ev.data)) |tc| {
                                    const os_act = mapFromEpoll(ev.events, tc.exp);
                                    tc.act = tc.act.lor(os_act);
                                    total_act = total_act.lor(tc.act);
                                }
                            }
                        } else {
                            for (self.event_buffer.unusedCapacitySlice()[0..n]) |ev| {
                                if (self.seqn_trc_map.get(ev.data.u64)) |tc| {
                                    const os_act = mapFromEpoll(ev.events, tc.exp);
                                    tc.act = tc.act.lor(os_act);
                                    total_act = total_act.lor(tc.act);
                                }
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
                            if (self.seqn_trc_map.get(@intCast(ev.udata))) |tc| {
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

extern fn epoll_create1(flags: i32) ?*anyopaque;
extern fn epoll_close(ephnd: *anyopaque) i32;
extern fn epoll_ctl(ephnd: *anyopaque, op: i32, sock: usize, event: *WepollEvent) i32;
extern fn epoll_wait(ephnd: *anyopaque, events: [*]WepollEvent, maxevents: i32, timeout: i32) i32;

const WepollEvent = extern struct {
    events: u32,
    data: u64,
};

pub const TcIterator = struct {
    itrtr: std.AutoArrayHashMap(SeqN, *TriggeredChannel).Iterator,
    pub fn init(tcm: *std.AutoArrayHashMap(SeqN, *TriggeredChannel)) TcIterator {
        return .{ .itrtr = tcm.iterator() };
    }
    pub fn next(self: *TcIterator) ?*TriggeredChannel {
        const entry = self.itrtr.next() orelse return null;
        return entry.value_ptr.*;
    }
    pub fn reset(self: *TcIterator) void {
        self.itrtr.reset();
    }
};

fn isSocketSet(skt: ?internal.Socket) bool {
    if (skt) |s| {
        if (builtin.os.tag == .windows) {
            return s != std.os.windows.ws2_32.INVALID_SOCKET;
        } else {
            return s != -1;
        }
    }
    return false;
}

fn toFd(skt: internal.Socket) (if (builtin.os.tag == .windows) usize else std.posix.fd_t) {
    if (builtin.os.tag == .windows) {
        return @intFromPtr(skt);
    } else {
        return @as(std.posix.fd_t, @intCast(skt));
    }
}

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
