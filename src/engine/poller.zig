// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Poller = union(enum) {
    poll: Poll,

    pub fn waitTriggers(self: *Poller, it: Distributor.Iterator, timeout: i32) AmpeError!Triggers {
        return switch (self.*) {
            inline else => |plr| try plr.waitTriggers(it, timeout),
        };
    }

    pub fn deinit(self: *const Poller) void {
        switch (self.*) {
            inline else => |plr| plr.deinit(),
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

    pub fn waitTriggers(ptr: ?*anyopaque, it: Distributor.Iterator, timeout: i32) AmpeError!Triggers {
        const pl: *Poll = @alignCast(@ptrCast(ptr));

        pl.it = it;

        const polln = try pl.buildFds();
        if (polln == 0) {
            return .{};
        }

        const tmout = try pl.poll(timeout);

        if (tmout) {
            return .{
                .timeout = .on,
            };
        }

        return try pl.storeTriggers();
    }

    fn buildFds(pl: *Poll) !usize {
        _ = pl;
        return AmpeError.NotImplementedYet;
    }

    fn poll(pl: *Poll, timeout: i32) !bool {
        _ = pl;
        _ = timeout;
        return AmpeError.NotImplementedYet;
    }

    fn storeTriggers(pl: *Poll) !Triggers {
        _ = pl;
        return AmpeError.NotImplementedYet;
    }
};

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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
