// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const AmpeVTable = struct {
    get: *const fn (ptr: ?*anyopaque, strategy: AllocationStrategy) AmpeError!?*message.Message,

    put: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) void,

    create: *const fn (ptr: ?*anyopaque) AmpeError!MessageChannelGroup,

    destroy: *const fn (ptr: ?*anyopaque, mcgimpl: ?*anyopaque) AmpeError!void,
};

pub const MCGVTable = struct {
    asyncSend: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!message.BinaryHeader,

    waitReceive: *const fn (ptr: ?*anyopaque, timeout_ns: u64) AmpeError!?*message.Message,

    interruptWait: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) AmpeError!void,
};

const AllocationStrategy = @import("../ampe.zig").AllocationStrategy;
const MessageChannelGroup = @import("../ampe.zig").MessageChannelGroup;
const message = @import("../message.zig");
const status = @import("../message.zig");
const AmpeError = status.AmpeError;
