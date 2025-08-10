// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const AMPStatus = enum(u8) {
    success = 0,
    not_allowed,
    not_implemented_yet,
    invalid_message,
    invalid_message_type,
    invalid_message_mode,
    invalid_headers_len,
    invalid_body_len,
    invalid_more_usage,
    invalid_channel_number,
    invalid_message_id,
    invalid_address,
    notification_disabled,
    notification_failed,
    peer_disconnected,
    communication_failed,
    unknown_error,
};

pub const AMPError = error{
    NotImplementedYet,
    NotAllowed,
    InvalidMessage,
    InvalidMessageType,
    InvalidMessageMode,
    InvalidHeadersLen,
    InvalidBodyLen,
    InvalidMoreUsage,
    InvalidChannelNumber,
    InvalidMessageId,
    InvalidAddress,
    NotificationDisabled,
    NotificationFailed,
    PeerDisconnected,
    CommunicatioinFailure,
    UnknownError,
};

// Comptime mapping from AMPStatus to AMPError.
const StatusToErrorMap = std.enums.EnumMap(AMPStatus, AMPError).init(.{
    .not_implemented_yet = .NotImplementedYet,
    .not_allowed = .NotAllowed,
    .invalid_message = .InvalidMessage,
    .invalid_message_type = .InvalidMessageType,
    .invalid_message_mode = .InvalidMessageMode,
    .invalid_headers_len = .InvalidHeadersLen,
    .invalid_body_len = .InvalidBodyLen,
    .invalid_channel_number = .InvalieChannelNumber,
    .invalid_message_id = .InvalieMessageId,
    .invalid_address = .InvalidAddress,
    .invalid_more_usage = .InvalidMoreUsage,
    .notification_disabled = .NotificationDisabled,
    .notification_failed = .NotificationFailed,
    .peer_disconnected = .PeerDisconnected,
    .communication_failed = .CommunicationFailed,
});

pub inline fn raw_to_status(rs: u8) AMPStatus {
    if (rs >= @intFromEnum(AMPStatus.unknown_error)) {
        return .UnknownError;
    }
    return @enumFromInt(rs);
}

pub inline fn raw_to_error(rs: u8) AMPError!void {
    if (rs == 0) {
        return;
    }
    if (rs >= @intFromEnum(AMPStatus.unknown_error)) {
        return .UnknownError;
    }

    return StatusToErrorMap.get(@enumFromInt(rs)).?;
}

pub inline fn status_to_raw(status: AMPStatus) u8 {
    return (@intFromEnum(status));
}

pub const engine = @import("engine.zig");

const std = @import("std");
