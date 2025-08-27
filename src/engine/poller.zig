// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Poller = union(enum) {
    poll: Poll,

    // it == null means iterator was not changed since previous call, use saved
    pub fn waitTriggers(self: *Poller, it: ?Distributor.Iterator, timeout: i32) AmpeError!Triggers {
        const ret = switch (self.*) {
            .poll => try self.*.poll.waitTriggers(it, timeout),
        };

        if (DBG) {
            const utrgrs = sockets.UnpackedTriggers.fromTriggers(ret);
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
    it: ?Distributor.Iterator = null,

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

    pub fn waitTriggers(pl: *Poll, it: ?Distributor.Iterator, timeout: i32) AmpeError!Triggers {
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
            tcptr = pl.it.?.next();

            tc.exp = try tc.tskt.triggers();
            tc.act = .{};

            var events: i16 = 0;

            if (!tc.exp.off()) {
                if (DBG) {
                    const utrgs = sockets.UnpackedTriggers.fromTriggers(tc.exp);
                    _ = utrgs;
                }

                if ((tc.exp.send == .on) or (tc.exp.connect == .on)) {
                    log.debug("chn {d} send/connect expected fd {x}", .{ tc.acn.chn, tc.tskt.getSocket() });
                    events |= std.posix.POLL.OUT;
                }
                if ((tc.exp.recv == .on) or (tc.exp.notify == .on) or (tc.exp.accept == .on)) {
                    log.debug("chn {d} recv/accept expected fd {x}", .{ tc.acn.chn, tc.tskt.getSocket() });
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
            return AmpeError.CommunicatioinFailure;
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

            tc.act = .{};

            while (true) {
                const revents = pl.pollfdVtor.items[indx].revents;

                if (revents == 0) {
                    break;
                }

                if ((revents & std.posix.POLL.ERR != 0) or (revents & std.posix.POLL.HUP != 0)) {
                    tc.act.err = .on;
                    break;
                }

                if ((revents & std.posix.POLL.IN != 0) or (revents & std.posix.POLL.RDNORM != 0)) {
                    if (tc.exp.recv == .on) {
                        log.debug("chn {d} recv allowed fd {x} ", .{ tc.acn.chn, pl.pollfdVtor.items[indx].fd });
                        tc.act.recv = .on;
                    } else if (tc.exp.notify == .on) {
                        tc.act.notify = .on;
                    } else if (tc.exp.accept == .on) {
                        log.debug("chn {d} accept allowed fd {x} ", .{ tc.acn.chn, pl.pollfdVtor.items[indx].fd });
                        tc.act.accept = .on;
                    }
                }

                if (revents & std.posix.POLL.OUT != 0) {
                    if (tc.exp.send == .on) {
                        log.debug("chn {d} send allowed fd {x} ", .{ tc.acn.chn, pl.pollfdVtor.items[indx].fd });
                        tc.act.send = .on;
                    } else if (tc.exp.connect == .on) {
                        log.debug("chn {d} connect allowed fd {x} ", .{ tc.acn.chn, pl.pollfdVtor.items[indx].fd });
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

const DBG = @import("../engine.zig").DBG;

pub const AmpeError = @import("../status.zig").AmpeError;

pub const ChannelNumber = @import("../message.zig").ChannelNumber;
pub const MessageID = @import("../message.zig").MessageID;

const sockets = @import("sockets.zig");
const Skt = sockets.Skt;
const Trigger = sockets.Trigger;
const Triggers = sockets.Triggers;
const TriggeredSkt = sockets.TriggeredSkt;

const channels = @import("channels.zig");
const ActiveChannel = channels.ActiveChannel;

const Distributor = @import("Distributor.zig");
const TriggeredChannel = Distributor.TriggeredChannel;
const TriggeredChannelsMap = Distributor.TriggeredChannelsMap;
const WaitTriggers = Distributor.WaitTriggers;

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log;
