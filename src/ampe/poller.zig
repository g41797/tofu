// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const poll_INFINITE_TIMEOUT: u32 = std.math.maxInt(i32);
pub const poll_SEC_TIMEOUT: i32 = 1_000;

pub const Poller = union(enum) {
    poll: Poll,

    // it == null means iterator was not changed since previous call, use saved
    pub fn waitTriggers(self: *Poller, it: ?Engine.Iterator, timeout: i32) AmpeError!Triggers {
        const ret = switch (self.*) {
            .poll => try self.*.poll.waitTriggers(it, timeout),
        };

        if (DBG) {
            const utrgrs = internal.triggeredSkts.UnpackedTriggers.fromTriggers(ret);
            _ = utrgrs;
        }

        return ret;
    }

    pub fn deinit(self: *const Poller) void {
        switch (self.*) {
            .poll => self.*.poll.deinit(),
        }
        return;
    }
};

pub const Poll = struct {
    allocator: Allocator = undefined,
    pollfdVtor: std.ArrayList(std.posix.pollfd) = undefined,
    it: ?Engine.Iterator = null,

    pub fn init(allocator: Allocator) !Poll {
        var ret: Poll = .{
            .it = null,
        };

        ret.allocator = allocator;

        ret.pollfdVtor = try std.ArrayList(std.posix.pollfd).initCapacity(ret.allocator, 256);
        errdefer ret.pollfdVtor.deinit();

        return ret;
    }

    pub fn deinit(pl: *const Poll) void {
        pl.pollfdVtor.deinit();
        return;
    }

    pub fn waitTriggers(pl: *Poll, it: ?Engine.Iterator, timeout: i32) AmpeError!Triggers {
        // const pl: *Poll = @alignCast(@ptrCast(ptr));

        if ((pl.it == null) and (it == null)) {
            return AmpeError.NotAllowed;
        }

        if (it != null) {
            pl.it = it;
        }

        pl.it.?.reset();

        const polln = try pl.buildFds();
        if (polln == 0) {
            return .{};
        }

        const tmout = try pl.poll(timeout);

        if (tmout) {
            const tmouttrgs: Triggers = .{
                .timeout = .on,
            };
            return tmouttrgs;
        }

        return try pl.storeTriggers();
    }

    fn buildFds(pl: *Poll) !usize {
        pl.pollfdVtor.items.len = 0;

        var tcptr = pl.it.?.next();

        while (tcptr != null) {
            const tc = tcptr.?;

            tc.disableDelete();

            tcptr = pl.it.?.next();

            tc.exp = try tc.tskt.triggers();
            tc.act = .{};

            var events: i16 = 0;

            if (!tc.exp.off()) {
                if (DBG) {
                    const utrgs = internal.triggeredSkts.UnpackedTriggers.fromTriggers(tc.exp);
                    _ = utrgs;
                }

                // const nSkt = tc.tskt.getSocket();
                // const chN = tc.acn.chn;

                if (tc.exp.notify == .on) {
                    events |= std.posix.POLL.IN;
                }
                if (tc.exp.send == .on) {
                    // log.debug("chn {d} send expected fd {x}", .{ chN, nSkt });
                    events |= std.posix.POLL.OUT;
                }
                if (tc.exp.connect == .on) {
                    // log.debug("chn {d} connect expected fd {x}", .{ chN, nSkt });
                    events |= std.posix.POLL.OUT;
                }
                if (tc.exp.recv == .on) {
                    // log.debug("chn {d} recv expected fd {x}", .{ chN, nSkt });
                    events |= std.posix.POLL.IN;
                }
                if (tc.exp.accept == .on) {
                    // log.debug("chn {d} accept expected fd {x}", .{ chN, nSkt });
                    events |= std.posix.POLL.IN;
                }
                if (tc.exp.pool == .off) {
                    assert(events != 0);
                }
            }

            pl.pollfdVtor.append(.{ .fd = tc.tskt.getSocket(), .events = events, .revents = 0 }) catch {
                return AmpeError.AllocationFailed;
            };
        }

        return pl.pollfdVtor.items.len;
    }

    fn poll(pl: *Poll, timeout: i32) !bool {
        const triggered = std.posix.poll(pl.pollfdVtor.items, timeout) catch {
            return AmpeError.CommunicationFailed;
        };

        return triggered == 0;
    }

    fn storeTriggers(pl: *Poll) !Triggers {
        pl.it.?.reset();

        var ret: Triggers = .{};

        var tcptr = pl.it.?.next();
        var indx: usize = 0;

        while (tcptr != null) : (indx += 1) {
            const tc = tcptr.?;
            tcptr = pl.it.?.next();

            tc.act = .{
                .pool = tc.exp.pool,
            };

            while (true) {
                const revents = pl.pollfdVtor.items[indx].revents;

                if (revents == 0) {
                    break;
                }

                if ((revents & err_mask) != 0) {
                    log.info("indx {d} poll error on chn {d} fd {x} ", .{ indx, tc.acn.chn, pl.pollfdVtor.items[indx].fd });

                    tc.act.err = .on;
                    if (tc.exp.notify == .on) {
                        tc.act.notify = .on;
                        break;
                    }
                    if (tc.exp.accept == .on) {
                        tc.act.accept = .on;
                        break;
                    }
                    if (tc.exp.connect == .on) {
                        tc.act.connect = .on;
                        break;
                    }
                    if (tc.exp.send == .on) {
                        tc.act.send = .on;
                    }
                    if (tc.exp.recv == .on) {
                        tc.act.recv = .on;
                    }
                    break;
                }

                if ((revents & std.posix.POLL.IN != 0) or (revents & std.posix.POLL.RDNORM != 0)) {
                    if (tc.exp.recv == .on) {
                        // log.debug("chn {d} recv allowed fd {x} ", .{ tc.acn.chn, pl.pollfdVtor.items[indx].fd });
                        tc.act.recv = .on;
                    } else if (tc.exp.notify == .on) {
                        tc.act.notify = .on;
                    } else if (tc.exp.accept == .on) {
                        // log.debug("chn {d} accept allowed fd {x} ", .{ tc.acn.chn, pl.pollfdVtor.items[indx].fd });
                        tc.act.accept = .on;
                    }
                }

                if (revents & std.posix.POLL.OUT != 0) {
                    if (tc.exp.send == .on) {
                        // log.debug("chn {d} send allowed fd {x} ", .{ tc.acn.chn, pl.pollfdVtor.items[indx].fd });
                        tc.act.send = .on;
                    } else if (tc.exp.connect == .on) {
                        // log.debug("chn {d} connect allowed fd {x} ", .{ tc.acn.chn, pl.pollfdVtor.items[indx].fd });
                        tc.act.connect = .on;
                    }
                }

                assert(!tc.act.off());

                break;
            }

            ret = ret.lor(tc.act);
        }

        return ret;
    }
};

const err_mask = std.posix.POLL.ERR | std.posix.POLL.NVAL | std.posix.POLL.HUP;

const tofu = @import("../tofu.zig");
const DBG = tofu.DBG;

pub const AmpeError = tofu.status.AmpeError;

pub const ChannelNumber = tofu.message.ChannelNumber;
pub const MessageID = tofu.message.MessageID;

const internal = @import("internal.zig");
const Skt = internal.Skt;
const Trigger = internal.Trigger;
const Triggers = internal.triggeredSkts.Triggers;
const TriggeredSkt = internal.TriggeredSkt;

const ActiveChannel = @import("channels.zig").ActiveChannel;

const Engine = tofu.Engine;
const TriggeredChannel = Engine.TriggeredChannel;
const TriggeredChannelsMap = Engine.TriggeredChannelsMap;

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log;
