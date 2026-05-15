//! Portable backend implementation using posix_net (uSockets).
//! Shape mirrors epoll_backend.zig: SeqN stored in pollExt at register time;
//! dispatch looks up TC via seqn_trc_map.get(seq) — no pre-wiring before each tick.

const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("../common.zig");
const SeqN = common.SeqN;
const core = @import("../core.zig");
const triggers_mod = @import("triggers.zig");

const internal = @import("../internal.zig");
const Triggers = internal.triggeredSkts.Triggers;

const tofu = @import("../../tofu.zig");
const TriggeredChannel = tofu.Reactor.TriggeredChannel;
const AmpeError = tofu.status.AmpeError;

const pn = @import("posix_net");

// Thread-local loop slot — one per reactor thread.
threadlocal var g_loop: ?*anyopaque = null;

pub fn getLoop() ?*anyopaque {
    return g_loop;
}

// Thread-local wait context — published for the duration of one tick.
threadlocal var g_wait_state: ?*WaitState = null;

const WaitState = struct {
    map: *core.SeqnTrcMap,
    total_act: Triggers,
};

/// Override of forked uSockets weak symbol.
/// Reads SeqN from pollExt (set at register time), looks up TC in the current map.
/// Mirrors epoll_backend: ev.data.u64 ↔ pollExt SeqN; seqn_trc_map.get(seq) ↔ same.
export fn us_internal_dispatch_ready_poll(
    poll: *anyopaque,
    err: c_int,
    events: c_int,
) callconv(.c) void {
    const ws = g_wait_state orelse return;
    if (pn.poll.pollType(poll) != pn.POLL_TYPE_SOCKET) return;

    const seq_ptr: *SeqN = @ptrCast(@alignCast(pn.poll.pollExt(poll)));
    const tc = ws.map.get(seq_ptr.*) orelse {
        std.log.err("Dispatch lookup failed for seq: {d}", .{seq_ptr.*});
        return;
    };

    const act = triggers_mod.usockets.fromEvents(events, err, tc.exp);
    tc.act = tc.act.lor(act);
    ws.total_act = ws.total_act.lor(act);
}

// fd → poll handle; SeqN lives in pollExt, not here.
const PollMap = std.AutoHashMap(common.FdType, *anyopaque);

/// Portable backend using posix_net (uSockets event loop).
const PosixNetBackend = struct {
    loop: *anyopaque,
    polls: PollMap,
    allocator: Allocator,

    pub fn init(alktr: Allocator) AmpeError!PosixNetBackend {
        if (g_loop != null) @panic("PosixNetBackend init called twice on same thread");

        g_loop = pn.poll.createLoop() orelse return AmpeError.CommunicationFailed;

        return .{
            .loop = g_loop.?,
            .polls = PollMap.init(alktr),
            .allocator = alktr,
        };
    }

    pub fn deinit(self: *PosixNetBackend) void {
        var it = self.polls.iterator();
        while (it.next()) |entry| {
            pn.poll.stopPoll(entry.value_ptr.*, self.loop);
            pn.poll.freePoll(entry.value_ptr.*, self.loop);
        }
        self.polls.deinit();

        if (g_loop) |loop| {
            pn.poll.freeLoop(loop);
            g_loop = null;
        }
    }

    pub fn register(self: *PosixNetBackend, fd: common.FdType, seq: SeqN, exp: Triggers) AmpeError!void {
        if (self.polls.get(fd)) |poll| {
            // Already registered — update events only, seq is stable.
            pn.poll.changePoll(poll, self.loop, triggers_mod.usockets.toEvents(exp));
            return;
        }

        const poll = pn.poll.createPoll(self.loop, @sizeOf(SeqN)) orelse return AmpeError.AllocationFailed;
        pn.poll.initPoll(poll, fd, pn.POLL_TYPE_SOCKET);

        const seq_ptr: *SeqN = @ptrCast(@alignCast(pn.poll.pollExt(poll)));
        seq_ptr.* = seq;

        pn.poll.startPoll(poll, self.loop, triggers_mod.usockets.toEvents(exp));
        self.polls.put(fd, poll) catch {
            pn.poll.stopPoll(poll, self.loop);
            pn.poll.freePoll(poll, self.loop);
            return AmpeError.AllocationFailed;
        };
    }

    pub fn modify(self: *PosixNetBackend, fd: common.FdType, seq: SeqN, exp: Triggers) AmpeError!void {
        const poll = self.polls.get(fd) orelse {
            return self.register(fd, seq, exp);
        };
        pn.poll.changePoll(poll, self.loop, triggers_mod.usockets.toEvents(exp));
    }

    pub fn unregister(self: *PosixNetBackend, fd: common.FdType) void {
        if (self.polls.fetchRemove(fd)) |entry| {
            pn.poll.stopPoll(entry.value, self.loop);
            pn.poll.freePoll(entry.value, self.loop);
        }
    }

    pub fn wait(self: *PosixNetBackend, timeout: i32, seqn_trc_map: *core.SeqnTrcMap) AmpeError!Triggers {
        if (g_wait_state != null) @panic("wait() called recursively or from two reactors on the same thread");

        var ws = WaitState{ .map = seqn_trc_map, .total_act = Triggers{} };
        g_wait_state = &ws;
        defer g_wait_state = null;

        const wait_ms: c_int = if (timeout == common.poll_INFINITE_TIMEOUT) -1 else @intCast(timeout);
        pn.poll.tick(self.loop, wait_ms);

        if (ws.total_act.off()) ws.total_act.timeout = .on;
        return ws.total_act;
    }
};

/// Complete portable Poller type using PollerCore.
pub const Poller = core.PollerCore(PosixNetBackend);
