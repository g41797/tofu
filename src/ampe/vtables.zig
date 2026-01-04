// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const AmpeVTable = struct {
    get: *const fn (ptr: ?*anyopaque, strategy: AllocationStrategy) AmpeError!?*message.Message,

    put: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) void,

    create: *const fn (ptr: ?*anyopaque) AmpeError!ChannelGroup,

    destroy: *const fn (ptr: ?*anyopaque, chnlsimpl: ?*anyopaque) AmpeError!void,

    getAllocator: *const fn (ptr: ?*anyopaque) Allocator,
};

pub const CHNLSVTable = struct {
    post: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!message.BinaryHeader,

    waitReceive: *const fn (ptr: ?*anyopaque, timeout_ns: u64) AmpeError!?*message.Message,

    updateReceiver: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!void,
};

const AllocationStrategy = @import("../ampe.zig").AllocationStrategy;
const ChannelGroup = @import("../ampe.zig").ChannelGroup;
const message = @import("../message.zig");
const AmpeError = @import("../status.zig").AmpeError;

const std = @import("std");
const Allocator = std.mem.Allocator;
