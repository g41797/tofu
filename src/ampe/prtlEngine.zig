// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub fn sendHello(eng: *Engine) !void {
    TriggeredChannel.createIoClientChannel(eng) catch |err| {
        if (eng.currMsg.?.bhdr.proto.role == .request) {
            eng.currMsg.?.bhdr.proto.role = .response;
        } else {
            eng.currMsg.?.bhdr.proto.role = .signal;
            eng.currMsg.?.bhdr.proto.mtype = .regular;
        }

        const st = status.errorToStatus(err);
        eng.responseFailure(st) catch {};
        return;
    };

    return;
}

pub fn sendWelcome(eng: *Engine) !void {
    TriggeredChannel.createListenerChannel(eng) catch |err| {
        if (eng.currMsg.?.bhdr.proto.role == .request) {
            eng.currMsg.?.bhdr.proto.role = .response;
        } else {
            eng.currMsg.?.bhdr.proto.role = .signal;
            eng.currMsg.?.bhdr.proto.mtype = .regular;
        }

        const st = status.errorToStatus(err);
        eng.responseFailure(st) catch {};
        return;
    };

    return;
}

pub fn sendBye(eng: *Engine) !void {
    // 2DO - Add processing
    _ = eng;
    return AmpeError.NotImplementedYet;
}

pub fn sendByeResponse(eng: *Engine) !void {
    // 2DO - Add processing
    _ = eng;
    return AmpeError.NotImplementedYet;
}

pub fn sendToPeer(eng: *Engine) !void {
    const sendMsg: *Message = eng.currMsg.?;
    const chN = sendMsg.bhdr.channel_number;

    var tc = eng.trgrd_map.getPtr(chN);
    if (tc == null) { // Already removed
        return;
    }

    tc.?.tskt.addToSend(sendMsg) catch |err| {
        log.info("addToSend on channel {d} failed with error {any}", .{ chN, err });
        const st = status.errorToStatus(err);
        eng.responseFailure(st) catch {};
    };

    eng.currMsg = null;

    return;
}

pub fn processMarkedForDelete(eng: *Engine) !bool {
    var wasRemoved: bool = false;

    try eng.acns.allChannels(&eng.allChnN);

    for (eng.allChnN.items) |chN| {
        const tcOpt = eng.trgrd_map.getPtr(chN);
        if (tcOpt) |tcPtr| {
            if (tcPtr.mrk4del) {
                tcPtr.deinit();
                wasRemoved = true;
            }
        }
    }

    return wasRemoved;
}

pub fn processInternal(eng: *Engine) !void {
    // Temporary - only one internal msg - destroy
    // chnls(MchnGroup) : Signal with status == shutdown_started
    // body has *MchnGroup
    var cmsg = eng.currMsg.?;
    const chnlsimpl: ?*MchnGroup = cmsg.bodyToPtr(MchnGroup);
    const grp = chnlsimpl.?;

    const chgr = eng.acns.channelsGroup(chnlsimpl) catch unreachable;
    defer chgr.deinit();
    _ = eng.acns.removeChannels(chnlsimpl) catch unreachable;

    for (chgr.items) |chN| {
        const trcopt = eng.trgrd_map.getPtr(chN);

        if (trcopt != null) {
            var tc = trcopt.?;

            assert(tc.acn.ctx != null);
            const grpCtx: *MchnGroup = @alignCast(@ptrCast(tc.acn.ctx.?));
            assert(grp == grpCtx);
            tc.resp2ac = false;
            tc.deinit();
        }
    }

    grp.setReleaseCompleted();
    return;
}

pub fn responseFailure(eng: *Engine, failure: AmpeStatus) !void {
    defer eng.releaseToPool(&eng.currMsg);

    eng.currMsg.?.bhdr.status = status.status_to_raw(failure);
    eng.currMsg.?.bhdr.proto.origin = .engine;

    const chn = eng.currMsg.?.bhdr.channel_number;
    var trchn = eng.trgrd_map.getPtr(chn);
    assert(trchn != null);
    trchn.?.markForDelete(failure);
    trchn.?.sendToCtx(&eng.currMsg);
    return;
}

pub fn processTimeOut(eng: *Engine) void {
    // Placeholder for idle processing
    _ = eng;
    return;
}

pub fn processWaitTriggersFailure(eng: *Engine) void {
    // 2DO - Add failure processing
    _ = eng;
    return;
}

const tofu = @import("../tofu.zig");

const Engine = tofu.Engine;

const message = tofu.message;
const MessageType = message.MessageType;
const MessageRole = message.MessageRole;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = message.TextHeaderIterator;
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageID = message.MessageID;
const VC = message.ValidCombination;

const Options = tofu.Options;
const Ampe = tofu.Ampe;
const Channels = tofu.Channels;

const status = tofu.status;
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const configurator = tofu.configurator;
const Configurator = configurator.Configurator;

const internal = @import("internal.zig");

const Notifier = internal.Notifier;

const Pool = internal.Pool;

const channels = internal.channels;
const ActiveChannels = channels.ActiveChannels;

// const sockets = @import("sockets");
const TriggeredSkt = internal.TriggeredSkt;

const TriggeredChannel = internal.TriggeredChannel;

const MchnGroup = internal.MchnGroup;

const poller = internal.poller;

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
