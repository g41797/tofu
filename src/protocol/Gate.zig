// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Gate = @This();

allocator: Allocator = undefined,
options: protocol.Options = undefined,
pool: Pool = undefined,
mutex: Mutex = undefined,

pub fn init(gt: *Gate, allocator: Allocator, options: Options) !void {
    gt.allocator = allocator;
    gt.options = options;
    gt.pool = Pool.init(gt.allocator);
    gt.mutex = .{};
    return;
}

pub fn amp(gt: *Gate) AMP {
    const result: AMP = .{
        .impl = gt,
        .functions = &.{
            .start_send = start_send,
            .wait_receive = wait_receive,
            .shutdown = shutdown,
            .get = get,
            .put = put,
        },
        .running = Atomic(bool).init(true),
        .shutdown_finished = Atomic(bool).init(false),
    };
    return result;
}

pub fn start_send(impl: *anyopaque, msg: *Message) !BinaryHeader {
    const gt: *Gate = @ptrCast(@alignCast(impl));
    return gt._start_send(msg);
}

pub fn wait_receive(impl: *anyopaque, timeout_ns: u64) anyerror!?*Message {
    const gt: *Gate = @ptrCast(@alignCast(impl));
    return gt._wait_receive(timeout_ns);
}

pub fn get(impl: *anyopaque, force: bool) ?*Message {
    const gt: *Gate = @ptrCast(@alignCast(impl));
    return gt._get(force);
}

pub fn put(impl: *anyopaque, msg: *Message) void {
    const gt: *Gate = @ptrCast(@alignCast(impl));
    return gt._put(msg);
}

pub fn free(impl: *anyopaque, msg: *Message) void {
    const gt: *Gate = @ptrCast(@alignCast(impl));
    return gt._free(msg);
}

pub fn shutdown(impl: *anyopaque) !void {
    const gt: *Gate = @ptrCast(@alignCast(impl));

    try gt._shutdown();
    var allocator = gt.allocator;
    allocator.destroy(gt);
    return;
}

inline fn _start_send(gt: *Gate, msg: *Message) !BinaryHeader {
    _ = gt;
    _ = msg;
    return .{};
}

inline fn _wait_receive(gt: *Gate, timeout_ns: u64) !?*Message {
    _ = gt;
    _ = timeout_ns;
    return null;
}

inline fn _get(gt: *Gate, force: bool) ?*Message {
    return gt.pool.get(force);
}

inline fn _put(gt: *Gate, msg: *Message) void {
    gt.pool.put(msg);

    return;
}

inline fn _free(gt: *Gate, msg: *Message) void {
    gt.pool.free(msg);

    return;
}

inline fn _shutdown(gt: *Gate) !void {
    gt.pool.close();

    return;
}

pub fn _freeMsg(msg: *Message) void {
    const allocator = msg.thdrs.buffer.allocator;
    msg.thdrs.deinit();
    msg.body.deinit();
    allocator.destroy(msg);
    return;
}

pub const protocol = @import("../protocol.zig");
pub const TextHeaderIterator = @import("../TextHeaderIterator.zig");
pub const Appendable = @import("nats").Appendable;

const Pool = @import("Pool.zig");
const AMP = protocol.AMP;
const Options = protocol.Options;
const Message = protocol.Message;
const BinaryHeader = protocol.BinaryHeader;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
