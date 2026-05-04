// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const tofu = @import("../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
const Skt = @import("Skt.zig").Skt;
const message = tofu.message;
const Message = message.Message;

pub const SocketCreator = @This();

allocator: Allocator = undefined,

pub fn init(_: Allocator) SocketCreator {
    return .{};
}

pub fn parse(_: *SocketCreator, _: *Message) AmpeError!Skt {
    return AmpeError.NotImplementedYet;
}

pub fn fromAddress(_: *SocketCreator, _: tofu.address.Address) AmpeError!Skt {
    return AmpeError.NotImplementedYet;
}

pub fn createUdsListener(_: Allocator, _: []const u8) AmpeError!Skt {
    return AmpeError.NotImplementedYet;
}

pub fn createUdsSocket(_: []const u8) AmpeError!Skt {
    return AmpeError.NotImplementedYet;
}

pub fn createListenerSocket(_: *const std.net.Address) !Skt {
    return AmpeError.NotImplementedYet;
}

pub fn createConnectSocket(_: *const std.net.Address) !Skt {
    return AmpeError.NotImplementedYet;
}
