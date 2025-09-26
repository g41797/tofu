// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub fn sendWelcome(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn sendHello(dtr: *Distributor) !void {
    // 2DO - Add processing

    const cnfgr = engine.configurator.Configurator.fromMessage(dtr.currMsg.?);
    switch (cnfgr) {
        .wrong => {
            try dtr.responseFailure(AmpeStatus.wrong_configuration);
        },
        else => {
            return AmpeError.ShutdownStarted;
        },
    }

    return AmpeError.ShutdownStarted;
}

pub fn sendBye(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn sendByeResponse(dtr: *Distributor) !void {
    // 2DO - Add processing
    _ = dtr;
    return AmpeError.NotImplementedYet;
}

pub fn sendToPeer(dtr: *Distributor) !void {
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

pub fn processInternal(dtr: *Distributor) !void {
    // Temporary - only one internal msg - destroy
    // mcg(Gate) : Signal with status == shutdown_started
    // body has *Gate
    var cmsg = dtr.currMsg.?;
    const mcgimpl: ?*Gate = cmsg.bodyToPtr(Gate);
    const gt = mcgimpl.?;

    const chgr = dtr.acns.channelsGroup(mcgimpl) catch unreachable;
    defer chgr.deinit();
    _ = dtr.acns.removeChannels(mcgimpl) catch unreachable;

    for (chgr.items) |chN| {
        const trcopt = dtr.trgrd_map.getPtr(chN);

        if (trcopt != null) {
            var tc = trcopt.?;

            assert(tc.acn.ctx != null);
            const gtCtx: *Gate = @alignCast(@ptrCast(tc.acn.ctx.?));
            assert(gt == gtCtx);
            tc.acn.ctx = null; // Prevents notifications during tc.deinit()

            tc.deinit();

            _ = dtr.trgrd_map.orderedRemove(chN);
        }
    }

    gt.setReleaseCompleted();
    return;
}

pub fn addNotificationChannel(dtr: *Distributor) !void {
    const ntcn = try TriggeredChannel.createNotificationChannel(dtr);

    dtr.trgrd_map.put(ntcn.acn.chn, ntcn) catch {
        return AmpeError.AllocationFailed;
    };

    dtr.ntfcsEnabled = true;
    dtr.cnmapChanged = false;
    return;
}

pub fn responseFailure(dtr: *Distributor, failure: AmpeStatus) !void {
    dtr.currMsg.?.bhdr.status = status.status_to_raw(failure);
    const chn = dtr.currMsg.?.bhdr.channel_number;
    const trchn = dtr.trgrd_map.getPtr(chn);
    if (trchn == null) {
        log.info("channel {d} does not exists", .{
            chn,
        });
        return; // or Message.DestroySendMsg(&dtr.currMsg)
    }

    // 2DO - check implementation, add notification etc, mark for delete !!
    trchn.?.act.err = .on;
    return;
}

pub fn markForDelete(dtr: *Distributor, chn: message.ChannelNumber) !void {
    const trchn = dtr.trgrd_map.getPtr(chn);
    if (trchn) |ch| {
        ch.mrk4del = true;
    }

    return;
}

const Distributor = @import("Distributor.zig");

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

const TriggeredChannel = @import("TriggeredChannel.zig");

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
