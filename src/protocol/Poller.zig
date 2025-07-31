// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Poller = @This();

allocator: Allocator = undefined,
options: protocol.Options = undefined,

pub fn ampe(plr: *Poller) Ampe {
    const result: Ampe = .{
        .ptr = plr,
        .vtable = &.{
            .create = create,
            .destroy = destroy,
        },
    };
    return result;
}

pub fn init(gpa: Allocator, options: Options) !Poller {
    const plr: Poller = .{
        .allocator = gpa,
        .options = options,
    };

    return plr;
}

pub fn deinit(plr: *Poller) void {
    const gpa = plr.allocator;
    _ = gpa;
    plr.* = undefined;
}

pub fn create(ptr: ?*anyopaque) anyerror!*Sr {
    const plr: *Poller = @alignCast(@ptrCast(ptr));
    return plr._create();
}

pub fn destroy(ptr: ?*anyopaque, sr: *Sr) anyerror!void {
    const plr: *Poller = @alignCast(@ptrCast(ptr));
    return plr._destroy(sr);
}

inline fn _create(plr: *Poller) anyerror!*Sr {
    _ = plr;
    return error.NotImplementedYet;
}

inline fn _destroy(plr: *Poller, sr: *Sr) anyerror!void {
    _ = plr;
    _ = sr;
    return error.NotImplementedYet;
}

pub const message = @import("../message.zig");
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = @import("../TextHeaderIterator.zig");
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const VC = message.ValidCombination;

pub const protocol = @import("../protocol.zig");
pub const Options = protocol.Options;
pub const Ampe = protocol.Ampe;
pub const Sr = protocol.Sr;

pub const status = @import("../status.zig");
pub const AMPStatus = status.AMPStatus;
pub const AMPError = status.AMPError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const Pool = @import("Pool.zig");
const Notifier = @import("Notifier.zig");

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

pub const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
pub const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
