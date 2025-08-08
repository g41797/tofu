// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const PolledSkt = union(enum) {
    notification: ?*NotificationSkt,
    accept: ?*AcceptSkt,
    io: ?*IoSkt,
};

pub const NotificationSkt = struct {
    prnt: *Poller = undefined,
};

pub const AcceptSkt = struct {
    prnt: *Poller = undefined,
    root: channels.ActiveChannel = undefined,
};

pub const Side = enum(u1) {
    client = 0,
    server = 1,
};

pub const IoSkt = struct {
    prnt: *Poller = undefined,
    side: Side = undefined,
    root: channels.ActiveChannel = undefined,
    messageQ : MessageQueue = undefined,
    currSend: ?*Message = undefined,
    currRecv: ?*Message = undefined,

};

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageMode = message.MessageMode;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = @import("../TextHeaderIterator.zig");
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageQueue = message.MessageQueue;

const MessageID = message.MessageID;
const VC = message.ValidCombination;

const Poller = @import("Poller.zig");

const protocol = @import("../protocol.zig");
const Options = protocol.Options;
const Sr = protocol.Sr;
const AllocationStrategy = protocol.AllocationStrategy;

const status = @import("../status.zig");
const AMPStatus = status.AMPStatus;
const AMPError = status.AMPError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

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
