// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Gate = @This();

allocator: Allocator = undefined,
options: protocol.Options = undefined,

pub fn init(gt: *Gate, allocator: Allocator, options: Options) !void {
    gt.allocator = allocator;
    gt.options = options;
}

pub fn amp(gt: *Gate) AMP {
    return .{
        .impl = gt,
        .functions = &.{
            .start_send = start_send,
            .wait_receive = wait_receive,
            .deinit = deinit,
            .get = get,
            .put = put,
            .free = free,
        },
    };
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

pub fn deinit(impl: *anyopaque) !void {
    const gt: *Gate = @ptrCast(@alignCast(impl));
    return gt._deinit();
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
    _ = gt;
    _ = force;
    return null;
}

inline fn _put(gt: *Gate, msg: *Message) void {
    _ = gt;
    _ = msg;
    return;
}

inline fn _free(gt: *Gate, msg: *Message) void {
    _ = gt;
    _ = msg;
    return;
}

inline fn _deinit(gt: *Gate) !void {
    _ = gt;
    return;
}

const is_be = builtin.target.cpu.arch.endian() == .big;

pub const protocol = @import("../protocol.zig");
pub const TextHeaderIterator = @import("../TextHeaderIterator.zig");
pub const Appendable = @import("nats").Appendable;

const AMP = protocol.AMP;
const Options = protocol.Options;
const Message = protocol.Message;
const BinaryHeader = protocol.BinaryHeader;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
