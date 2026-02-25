// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Common types and utilities shared across all poller backends.
//! Contains no OS-specific code.

pub const poll_INFINITE_TIMEOUT: u32 = std.math.maxInt(i32);
pub const poll_SEC_TIMEOUT: i32 = 1_000;
pub const SeqN = u64;

/// Iterator over TriggeredChannel pointers in the sequence-to-channel map.
pub const TcIterator = struct {
    itrtr: std.AutoArrayHashMap(SeqN, *TriggeredChannel).Iterator,

    pub fn init(tcm: *std.AutoArrayHashMap(SeqN, *TriggeredChannel)) TcIterator {
        return .{ .itrtr = tcm.iterator() };
    }

    pub fn next(self: *TcIterator) ?*TriggeredChannel {
        const entry = self.itrtr.next() orelse return null;
        return entry.value_ptr.*;
    }

    pub fn reset(self: *TcIterator) void {
        self.itrtr.reset();
    }
};

/// Check if a socket is set (not null and not INVALID_SOCKET on Windows or -1 on POSIX).
pub fn isSocketSet(skt: ?Socket) bool {
    if (skt) |s| {
        if (builtin.os.tag == .windows) {
            return s != std.os.windows.ws2_32.INVALID_SOCKET;
        } else {
            return s != -1;
        }
    }
    return false;
}

/// Convert socket to appropriate fd type for the platform.
/// Windows: returns usize (for wepoll which expects SOCKET as usize)
/// POSIX: returns i32 (fd_t)
pub fn toFd(skt: Socket) FdType {
    if (builtin.os.tag == .windows) {
        return @intFromPtr(skt);
    } else {
        return @as(std.posix.fd_t, @intCast(skt));
    }
}

/// Platform-appropriate file descriptor type.
pub const FdType = if (builtin.os.tag == .windows) usize else std.posix.fd_t;

const tofu = @import("../../tofu.zig");
const Reactor = tofu.Reactor;
const TriggeredChannel = Reactor.TriggeredChannel;

const internal = @import("../internal.zig");
const Socket = internal.Socket;

const std = @import("std");
const builtin = @import("builtin");
