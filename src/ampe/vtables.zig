// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const AmpeVTable = struct {
    get: *const fn (ptr: ?*anyopaque, strategy: AllocationStrategy) AmpeError!?*message.Message,

    put: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) void,

    create: *const fn (ptr: ?*anyopaque) AmpeError!Channels,

    destroy: *const fn (ptr: ?*anyopaque, chnlsimpl: ?*anyopaque) AmpeError!void,

    getAllocator: *const fn (ptr: ?*anyopaque) Allocator,
};

pub const CHNLSVTable = struct {
    sendToPeer: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!message.BinaryHeader,

    waitReceive: *const fn (ptr: ?*anyopaque, timeout_ns: u64) AmpeError!?*message.Message,

    updateWaiter: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!void,
};

const AllocationStrategy = @import("../ampe.zig").AllocationStrategy;
const Channels = @import("../ampe.zig").Channels;
const message = @import("../message.zig");
const AmpeError = @import("../status.zig").AmpeError;

const std = @import("std");
const Allocator = std.mem.Allocator;
