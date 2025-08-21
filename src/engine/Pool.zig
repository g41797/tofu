// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Pool = @This();

first: ?*Message = undefined,
allocator: Allocator = undefined,
mutex: Mutex = undefined,
closed: bool = undefined,
alerter: ?Notifier.Alerter = undefined,
emptyWasReturned: bool = undefined,

// pub fn create(gpa: Allocator) !*Pool {
//     const pool = try gpa.create(Pool);
//     errdefer gpa.destroy(pool);
//     try pool.*.init(gpa, null);
//     return pool;
// }
//
// pub fn destroy(pool: *Pool) void {
//     const gpa = pool.allocator;
//     pool.close();
//     gpa.destroy(pool);
// }

pub fn init(gpa: Allocator, alrtr: ?Notifier.Alerter) !Pool {
    return .{
        .allocator = gpa,
        .first = null,
        .mutex = .{},
        .closed = false,
        .alerter = alrtr,
        .emptyWasReturned = false,
    };
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
    if (pool.closed) {
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
        return;
    }

    msg.next = pool.first;
    pool.first = msg;

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
        chain = next;
    }
    pool.first = null;
    return;
}

pub const Appendable = @import("nats").Appendable;

pub const message = @import("../message.zig");
const Message = message.Message;

pub const engine = @import("../engine.zig");
pub const AllocationStrategy = engine.AllocationStrategy;

const Notifier = @import("Notifier.zig");
const Alert = Notifier.Alert;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

// 2DO  Add options: initial msgs number/max msgs number
// 2DO  Support restrictions -  max msgs number
