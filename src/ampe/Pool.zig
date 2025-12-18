// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Pool = @This();

first: ?*Message = undefined,
allocator: Allocator = undefined,
mutex: Mutex = undefined,
closed: bool = undefined,
alerter: ?Notifier.Alerter = undefined,
emptyWasReturned: bool = undefined,
initialMsgs: u16 = undefined,
maxMsgs: u16 = undefined,
currMsgs: u16 = undefined,

pub fn init(gpa: Allocator, initialMsgs: ?u16, maxMsgs: ?u16, alrtr: ?Notifier.Alerter) AmpeError!Pool {
    var ret: Pool = .{
        .allocator = gpa,
        .first = null,
        .mutex = .{},
        .closed = false,
        .alerter = alrtr,
        .emptyWasReturned = false,
        .currMsgs = 0,
        .initialMsgs = DefaultOptions.initialPoolMsgs.?,
        .maxMsgs = DefaultOptions.maxPoolMsgs.?,
    };

    if (initialMsgs) |im| {
        if (im != 0) {
            ret.initialMsgs = im;
        }
    }

    if (maxMsgs) |mm| {
        if (mm != 0) {
            ret.maxMsgs = mm;
        }
    }

    if (ret.maxMsgs < ret.initialMsgs) {
        ret.maxMsgs = ret.initialMsgs;
    }

    errdefer ret.close();

    for (0..ret.initialMsgs) |_| {
        ret.put(Message.create(ret.allocator) catch {
            return AmpeError.AllocationFailed;
        });
    }

    ret.currMsgs = ret.initialMsgs;

    ret.inform();

    return ret;
}

pub fn get(pool: *Pool, ac: AllocationStrategy) AmpeError!*Message {
    pool.mutex.lock();
    defer pool.*.inform();
    defer pool.mutex.unlock();
    if (pool.closed) {
        return AmpeError.NotAllowed;
    }

    var result: ?*Message = null;
    if (pool.first != null) {
        result = pool.first;
        pool.first = result.?.*.next;
        result.?.*.next = null;
        result.?.*.prev = null;
        result.?.*.reset();
        pool.*.currMsgs -= 1;
        return result.?;
    }

    if (ac == .poolOnly) {
        assert(pool.*.currMsgs == 0);
        pool.emptyWasReturned = true;
        return AmpeError.PoolEmpty;
    }

    const msg: *Message = Message.create(pool.allocator) catch {
        return AmpeError.AllocationFailed;
    };

    return msg;
}

pub fn put(pool: *Pool, msg: *Message) void {
    pool.mutex.lock();
    defer pool.*.inform();
    defer pool.mutex.unlock();

    if ((pool.closed) or (pool.currMsgs == pool.maxMsgs)) {
        pool.free(msg);
        return;
    }

    msg.*.prev = null;
    msg.*.next = null;

    msg.*.reset();

    if (pool.first == null) {
        assert(pool.*.currMsgs == 0);
        pool.first = msg;
        if ((pool.emptyWasReturned) and (pool.alerter != null)) {
            pool.alerter.?.send_alert(.freedMemory) catch {};
        }
        pool.emptyWasReturned = false;
    } else {
        msg.*.next = pool.first;
        pool.first = msg;
    }

    pool.currMsgs += 1;

    return;
}

pub fn free(pool: *Pool, msg: *Message) void {
    msg.*.thdrs.deinit();
    msg.*.body.deinit();
    pool.allocator.destroy(msg);
    return;
}

pub fn freeAll(pool: *Pool) void {
    pool.mutex.lock();
    defer pool.*.inform();
    defer pool.mutex.unlock();
    if (pool.closed) {
        return;
    }
    pool._freeAll();
    return;
}

pub fn close(pool: *Pool) void {
    pool.mutex.lock();
    defer pool.*.inform();
    defer pool.mutex.unlock();
    if (pool.closed) {
        return;
    }
    pool._freeAll();
    pool.closed = true;
    return;
}

fn _freeAll(pool: *Pool) void {
    var chain: ?*Message = pool.first;
    while (chain != null) {
        const next: ?*Message = chain.?.*.next;
        pool.free(chain.?);
        pool.currMsgs -= 1;
        chain = next;
    }
    pool.first = null;
    assert(pool.currMsgs == 0);
    return;
}

inline fn inform(pool: *Pool) void {
    if (DBG) {
        if (pool.*.currMsgs > 0) {
            // log.debug("pool msgs {d}", .{pool.*.currMsgs});
        }
    }
}

const Appendable = @import("nats").Appendable;

const tofu = @import("../tofu.zig");
const DBG = tofu.DBG;
const message = tofu.message;
const Message = message.Message;
const AllocationStrategy = tofu.AllocationStrategy;
const DefaultOptions = tofu.DefaultOptions;
const AmpeError = tofu.status.AmpeError;

const Notifier = @import("Notifier.zig");
const Alert = Notifier.Alert;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

const assert = std.debug.assert;
const log = std.log;

// 2DO  Timeout for Alerts - restrict number of alerts per sec
