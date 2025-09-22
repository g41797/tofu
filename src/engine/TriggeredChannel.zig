// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const TriggeredChannel = @This();

prnt: *Distributor = undefined,
acn: channels.ActiveChannel = undefined,
ntfcEnabled: bool = undefined,
tskt: TriggeredSkt = undefined,
exp: sockets.Triggers = undefined,
act: sockets.Triggers = undefined,
mrk4del: bool = undefined,

pub fn createNotificationChannel(prnt: *Distributor) !TriggeredChannel {
    const ret: Distributor.TriggeredChannel = .{
        .prnt = prnt,
        .acn = .{
            .chn = 0,
            .mid = 0,
            .ctx = null,
        },
        .tskt = .{
            .notification = sockets.NotificationSkt.init(prnt.ntfr.receiver),
        },
        .exp = sockets.TriggersOff,
        .act = sockets.TriggersOff,
        .mrk4del = false,
        .ntfcEnabled = false,
    };
    return ret;
}

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageRole = message.MessageRole;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = @import("../message.zig").TextHeaderIterator;
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageID = message.MessageID;
const VC = message.ValidCombination;

const engine = @import("../engine.zig");
const Options = engine.Options;
const Ampe = engine.Ampe;
const MessageChannelGroup = engine.MessageChannelGroup;

const status = @import("../status.zig");
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const Notifier = @import("Notifier.zig");

const Pool = @import("Pool.zig");

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

const sockets = @import("sockets.zig");
const TriggeredSkt = @import("triggeredSkts.zig").TriggeredSkt;

const Gate = @import("Gate.zig");

const poller = @import("poller.zig");

const Appendable = @import("nats").Appendable;

const mailbox = @import("mailbox");
const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const Distributor = @import("Distributor.zig");

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;
const log = std.log;
const assert = std.debug.assert;
