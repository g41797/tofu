// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Core poller structure and logic shared by epoll/wepoll/kqueue backends.
//! Provides the dual-map management and common attach/delete operations.

/// Generic PollerCore that composes with a backend-specific implementation.
/// Backend must implement:
///   - fn init(allocator: Allocator) AmpeError!Backend
///   - fn deinit(self: *Backend) void
///   - fn register(self: *Backend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void
///   - fn modify(self: *Backend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void
///   - fn unregister(self: *Backend, fd: FdType) void
///   - fn wait(self: *Backend, timeout: i32, seqn_trc_map: *SeqnTrcMap) AmpeError!Triggers
pub fn PollerCore(comptime Backend: type) type {
    return struct {
        const Self = @This();

        chn_seqn_map: ChnSeqnMap,
        seqn_trc_map: SeqnTrcMap,
        crseqN: SeqN = 0,
        allocator: Allocator,
        backend: Backend,

        pub fn init(alktr: Allocator) AmpeError!Self {
            var chn_map = ChnSeqnMap.init(alktr);
            errdefer chn_map.deinit();
            chn_map.ensureTotalCapacity(256) catch return AmpeError.AllocationFailed;

            var seq_map = SeqnTrcMap.init(alktr);
            errdefer seq_map.deinit();
            seq_map.ensureTotalCapacity(256) catch return AmpeError.AllocationFailed;

            const backend = try Backend.init(alktr);

            return .{
                .allocator = alktr,
                .chn_seqn_map = chn_map,
                .seqn_trc_map = seq_map,
                .backend = backend,
            };
        }

        pub fn attachChannel(self: *Self, tchn: *TriggeredChannel) AmpeError!bool {
            const chN = tchn.acn.chn;
            if (self.chn_seqn_map.contains(chN)) return AmpeError.InvalidChannelNumber;

            self.crseqN += 1;
            const seqN = self.crseqN;

            // Allocate a stable heap copy
            const tchn_heap = self.allocator.create(TriggeredChannel) catch return AmpeError.AllocationFailed;
            tchn_heap.* = tchn.*;

            // Dumb channels have no socket yet; they will be registered
            // with the backend on first reconciliation in waitTriggers.
            if (tchn_heap.tskt.getSocket()) |socket| {
                if (common.isSocketSet(socket)) {
                    try self.backend.register(common.toFd(socket), seqN, tchn_heap.tskt.triggers() catch Triggers{});
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
                const socket = kv.value.tskt.getSocket();
                if (common.isSocketSet(socket)) {
                    self.backend.unregister(common.toFd(socket.?));
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

                const socket = tcPtr.tskt.getSocket();
                if (common.isSocketSet(socket)) {
                    self.backend.unregister(common.toFd(socket.?));
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
                const socket = tc.tskt.getSocket();
                if (common.isSocketSet(socket)) {
                    self.backend.unregister(common.toFd(socket.?));
                }
                tc.tskt.deinit();
                self.allocator.destroy(tc);
            }
            self.backend.deinit();
            self.seqn_trc_map.deinit();
            self.chn_seqn_map.deinit();
            self.crseqN = 0;
        }

        pub fn waitTriggers(self: *Self, timeout: i32) AmpeError!Triggers {
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

                if (!tc.exp.eql(new_exp)) {
                    const socket = tc.tskt.getSocket();
                    if (common.isSocketSet(socket)) {
                        const seq = self.chn_seqn_map.get(tc.acn.chn).?;
                        try self.backend.modify(common.toFd(socket.?), seq, new_exp);
                    }
                    tc.exp = new_exp;
                }
            }

            if (self.seqn_trc_map.count() == 0) return .{};

            // If we already have internal activity (like pool readiness), don't block in the OS wait.
            const wait_timeout = if (total_act.off()) timeout else 0;

            const os_triggers = try self.backend.wait(wait_timeout, &self.seqn_trc_map);
            total_act = total_act.lor(os_triggers);

            return total_act;
        }

        pub fn iterator(self: *Self) common.TcIterator {
            var res = common.TcIterator.init(&self.seqn_trc_map);
            res.reset();
            return res;
        }
    };
}

pub const ChnSeqnMap = std.AutoArrayHashMap(message.ChannelNumber, SeqN);
pub const SeqnTrcMap = std.AutoArrayHashMap(SeqN, *TriggeredChannel);

const common = @import("common.zig");
const SeqN = common.SeqN;

const tofu = @import("../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
const message = tofu.message;
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;

const internal = @import("../internal.zig");
const Triggers = internal.triggeredSkts.Triggers;

const std = @import("std");
const Allocator = std.mem.Allocator;
