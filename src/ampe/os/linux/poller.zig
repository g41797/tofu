// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const poll_INFINITE_TIMEOUT: u32 = std.math.maxInt(i32);
pub const poll_SEC_TIMEOUT: i32 = 1_000;

pub const Poller = union(enum) {
    poll: Poll,

    pub fn waitTriggers(self: *Poller, it: ?Reactor.Iterator, timeout: i32) AmpeError!Triggers {
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
    it: ?Reactor.Iterator = null,

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

    pub fn waitTriggers(pl: *Poll, it: ?Reactor.Iterator, timeout: i32) AmpeError!Triggers {
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

            pl.*.pollfdVtor.append(pl.*.allocator, .{ .fd = tc.*.tskt.getSocket(), .events = events, .revents = 0 }) catch {
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

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const log = std.log;

const tofu = @import("../../../tofu.zig");
const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;
const message = tofu.message;
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;

const internal = @import("../../internal.zig");
const TriggeredSkt = internal.triggeredSkts.TriggeredSkt;
const Triggers = internal.triggeredSkts.Triggers;
