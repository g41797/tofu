// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const AmpeStatus = enum(u8) {
    success = 0,
    wrong_configuration,
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
    pool_empty,
    allocation_failed,
    wait_interrupted,
    unknown_error,
};

pub const AmpeError = error{
    NotImplementedYet,
    WrongConfiguration,
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
    PoolEmpty,
    AllocationFailed,
    WaitInterrupted,
    UnknownError,
};

// Comptime mapping from AmpeStatus to AmpeError.
const StatusToErrorMap = std.enums.EnumMap(AmpeStatus, AmpeError).init(.{
    .not_implemented_yet = .NotImplementedYet,
    .wrong_configuration = .WrongConfiguration,
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
    .pool_empty = .PoolEmpty,
    .allocation_failed = .AllocationFailed,
    .wait_interrupted = .WaitInterrupted,
});

pub inline fn raw_to_status(rs: u8) AmpeStatus {
    if (rs >= @intFromEnum(AmpeStatus.unknown_error)) {
        return .UnknownError;
    }
    return @enumFromInt(rs);
}

pub inline fn raw_to_error(rs: u8) AmpeError!void {
    if (rs == 0) {
        return;
    }
    if (rs >= @intFromEnum(AmpeStatus.unknown_error)) {
        return .UnknownError;
    }

    return StatusToErrorMap.get(@enumFromInt(rs)).?;
}

pub inline fn status_to_raw(status: AmpeStatus) u8 {
    return (@intFromEnum(status));
}

const std = @import("std");
