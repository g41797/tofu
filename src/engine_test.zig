// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test "Ampe create/destroy" {
    var dtr = Distributor.Create(std.testing.allocator, .{}) catch unreachable;
    defer dtr.Destroy();

    const ampe = try dtr.ampe();

    const mcg = try ampe.acquire();

    try ampe.release(mcg);
}

const std = @import("std");
const testing = std.testing;

const engine = @import("engine.zig");
const Ampe = engine.Ampe;
const MessageChannelGroup = engine.MessageChannelGroup;

pub const message = @import("message.zig");
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = message.TextHeaderIterator;
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;
pub const MessageID = message.MessageID;
pub const VC = message.ValidCombination;

pub const status = @import("status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;

pub const Distributor = @import("engine/Distributor.zig");
