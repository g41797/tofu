// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Pool = @This();

pub const InitialMsgs: u16 = 16;
pub const MaxMsgs: u16 = 128;

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
        .initialMsgs = InitialMsgs,
        .maxMsgs = MaxMsgs,
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

    return ret;
}

pub fn get(pool: *Pool, ac: AllocationStrategy) !*Message {
    pool.mutex.lock();
    defer pool.mutex.unlock();
    if (pool.closed) {
        return error.ClosedPool;
    }

    var result: ?*Message = null;
    if (pool.first != null) {
        result = pool.first;
        pool.first = result.?.next;
        result.?.next = null;
        result.?.prev = null;
        result.?.reset();
        return result.?;
    }

    if (ac == .poolOnly) {
        pool.emptyWasReturned = true;
        return error.EmptyPool;
    }

    const msg = Message.create(pool.allocator) catch |err| {
        return err;
    };

    return msg;
}

pub fn put(pool: *Pool, msg: *Message) void {
    pool.mutex.lock();
    defer pool.mutex.unlock();

    if ((pool.closed) or (pool.currMsgs == pool.maxMsgs)) {
        pool.free(msg);
        return;
    }

    msg.prev = null;
    msg.next = null;

    msg.reset();

    if (pool.first == null) {
        pool.first = msg;
        if ((pool.emptyWasReturned) and (pool.alerter != null)) {
            pool.alerter.?.send_alert(.freedMemory) catch {};
        }
        pool.emptyWasReturned = false;
    } else {
        msg.next = pool.first;
        pool.first = msg;
    }

    pool.currMsgs += 1;

    return;
}

pub fn free(pool: *Pool, msg: *Message) void {
    msg.thdrs.deinit();
    msg.body.deinit();
    pool.allocator.destroy(msg);
    return;
}

pub fn freeAll(pool: *Pool) void {
    pool.mutex.lock();
    defer pool.mutex.unlock();
    if (pool.closed) {
        return;
    }
    pool._freeAll();
    return;
}

pub fn close(pool: *Pool) void {
    pool.mutex.lock();
    defer pool.mutex.unlock();
    if (pool.closed) {
        return;
    }
    pool._freeAll();
    pool.closed = true;
    return;
}

fn _freeAll(pool: *Pool) void {
    var chain = pool.first;
    while (chain != null) {
        const next = chain.?.next;
        pool.free(chain.?);
        pool.currMsgs -= 1;
        chain = next;
    }
    pool.first = null;
    return;
}

const Appendable = @import("nats").Appendable;
const message = @import("../message.zig");
const Message = message.Message;
const AllocationStrategy = @import("../engine.zig").AllocationStrategy;
const Notifier = @import("Notifier.zig");
const Alert = Notifier.Alert;

const AmpeError = @import("../status.zig").AmpeError;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

// 2DO  Add options: initial msgs number/max msgs number
// 2DO  Support restrictions -  max msgs number
