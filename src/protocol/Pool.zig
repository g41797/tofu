// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Pool = @This();

const blen: u16 = 256;
const tlen: u16 = 64;

first: ?*Message = undefined,
allocator: Allocator = undefined,
mutex: Mutex = undefined,
closed: bool = undefined,
pub fn init(allocator: Allocator) !Pool {
    return .{
        .allocator = allocator,
        .first = null,
        .mutex = .{},
        .closed = false,
    };
}

pub fn get(pool: *Pool, force: bool) ?*Message {
    pool.mutex.lock();
    defer pool.mutex.unlock();
    if (pool.closed) {
        return null;
    }

    var result: ?*Message = null;
    if (pool.first != null) {
        result = pool.first;
        pool.first = result.?.next;
        result.?.next = null;
        result.?.prev = null;
        return result;
    }

    if (!force) {
        return null;
    }

    result = pool.alloc() catch return null;

    return result;
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
        return;
    }

    msg.next = pool.first;
    pool.first = msg;

    return;
}

inline fn alloc(pool: *Pool) !*Message {
    var msg = try pool.allocator.create(Message);
    msg.* = .{};
    msg.bhdr = .{};
    try msg.thdrs.init(pool.allocator, tlen);
    try msg.body.init(pool.allocator, blen, null);
    return msg;
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

pub const protocol = @import("../protocol.zig");
const Message = protocol.Message;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
