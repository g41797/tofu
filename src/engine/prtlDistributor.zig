// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub fn processWelcomeRequest(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn processHelloRequest(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.ShutdownStarted;
}

pub fn processHelloResponse(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn processByeRequest(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn processByeResponse(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn processByeSignal(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn processAppRequest(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn processAppResponse(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn processAppSignal(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn processTimeOut(dtr: *Distributor) void {
    // 2DO - Add processing
    _ = dtr;
    return;
}

pub fn processWaitTriggersFailure(dtr: *Distributor) void {
    // 2DO - Add failure processing
    _ = dtr;
    return;
}

pub fn processMarkedForDelete(dtr: *Distributor) !bool {
    _ = dtr;
    return false;
}

pub fn processAlarm(dtr: *Distributor) !void {
    _ = dtr;
    return;
}

pub fn addNotificationChannel(dtr: *Distributor) !void {
    const nSkt = dtr.ntfr.receiver;

    const ntcn: Distributor.TriggeredChannel = .{
        .acn = .{
            .chn = 0,
            .mid = 0,
            .ctx = null,
        },
        .tskt = .{
            .notification = sockets.NotificationSkt.init(nSkt),
        },
        .exp = sockets.TriggersOff,
        .act = sockets.TriggersOff,
    };

    dtr.trgrd_map.put(ntcn.acn.chn, ntcn) catch {
        return AmpeError.AllocationFailed;
    };

    dtr.ntfsEnabled = true;
    dtr.cnmapChanged = false;
    return;
}

const Distributor = @import("Distributor.zig");

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageMode = message.MessageMode;
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

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Thread = std.Thread;
const log = std.log;
const assert = std.debug.assert;
