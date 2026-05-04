// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const tofu = @import("../../tofu.zig");
const AmpeError = tofu.status.AmpeError;

pub const Skt = @This();

socket: ?std.posix.fd_t = null,
address: std.net.Address = undefined,
server: bool = false,

pub fn isSet(skt: *const Skt) bool {
    return skt.socket != null;
}

pub fn listen(skt: *Skt) !void {
    _ = skt;
    return error.NotImplemented;
}

pub fn accept(askt: *Skt) AmpeError!?Skt {
    _ = askt;
    return AmpeError.NotImplementedYet;
}

pub fn connect(skt: *Skt) AmpeError!bool {
    _ = skt;
    return AmpeError.NotImplementedYet;
}

pub fn setREUSE(skt: *Skt) !void {
    _ = skt;
    return error.NotImplemented;
}

pub fn setLingerAbort(skt: *Skt) AmpeError!void {
    _ = skt;
    return AmpeError.NotImplementedYet;
}

pub fn disableNagle(skt: *Skt) !void {
    _ = skt;
    return error.NotImplemented;
}

pub fn findFreeTcpPort() !u16 {
    return error.NotImplemented;
}

pub fn sendBufFd(socket: std.posix.fd_t, buf: []const u8) AmpeError!?usize {
    _ = socket;
    _ = buf;
    return AmpeError.NotImplementedYet;
}

pub fn recvToBufFd(socket: std.posix.fd_t, buf: []u8) AmpeError!?usize {
    _ = socket;
    _ = buf;
    return AmpeError.NotImplementedYet;
}

pub fn sendBuf(skt: *Skt, buf: []const u8) AmpeError!?usize {
    _ = skt;
    _ = buf;
    return AmpeError.NotImplementedYet;
}

pub fn recvToBuf(skt: *Skt, buf: []u8) AmpeError!?usize {
    _ = skt;
    _ = buf;
    return AmpeError.NotImplementedYet;
}

pub fn deinit(skt: *Skt) void {
    _ = skt;
}

pub fn close(skt: *Skt) void {
    _ = skt;
}
