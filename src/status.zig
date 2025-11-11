// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const AmpeStatus = enum(u8) {
    success = 0,
    wrong_configuration,
    not_allowed,
    not_implemented_yet,
    null_message,
    invalid_message,
    invalid_message_type,
    invalid_message_mode,
    invalid_headers_len,
    invalid_body_len,
    invalid_more_usage,
    invalid_channel_number,
    invelid_mchn_group,
    invalid_message_id,
    invalid_address,
    uds_path_not_found,
    notification_disabled,
    notification_failed,
    peer_disconnected,
    communication_failed,
    pool_empty,
    allocation_failed,
    waiter_update,
    channel_closed,
    shutdown_started,
    connect_failed,
    listen_failed,
    accept_failed,
    send_failed,
    recv_failed,
    setsockopt_failed,
    processing_failed, // You can use it as application status
    unknown_error,
};

pub const AmpeError = error{
    NotImplementedYet,
    WrongConfiguration,
    NotAllowed,
    NullMessage,
    InvalidMessage,
    InvalidMessageType,
    InvalidMessageMode,
    InvalidHeadersLen,
    InvalidBodyLen,
    InvalidMoreUsage,
    InvalidChannelNumber,
    InvalidMessageChannelGroup,
    InvalidMessageId,
    InvalidAddress,
    UDSPathNotFound,
    NotificationDisabled,
    NotificationFailed,
    PeerDisconnected,
    CommunicationFailed,
    PoolEmpty,
    AllocationFailed,
    WaiterUpdate,
    ChannelClosed,
    ShutdownStarted,
    ConnectFailed,
    ListenFailed,
    AcceptFailed,
    SendFailed,
    RecvFailed,
    SetsockoptFailed,
    ProcessingFailed, // You can use it as application error
    UnknownError,
};

// Comptime mapping from AmpeStatus to AmpeError.
var StatusToErrorMap = std.enums.EnumMap(AmpeStatus, AmpeError).init(.{
    .not_implemented_yet = AmpeError.NotImplementedYet,
    .wrong_configuration = AmpeError.WrongConfiguration,
    .not_allowed = AmpeError.NotAllowed,
    .null_message = AmpeError.NullMessage,
    .invalid_message = AmpeError.InvalidMessage,
    .invalid_message_type = AmpeError.InvalidMessageType,
    .invalid_message_mode = AmpeError.InvalidMessageMode,
    .invalid_headers_len = AmpeError.InvalidHeadersLen,
    .invalid_body_len = AmpeError.InvalidBodyLen,
    .invalid_channel_number = AmpeError.InvalidChannelNumber,
    .invelid_mchn_group = AmpeError.InvalidMessageChannelGroup,
    .invalid_message_id = AmpeError.InvalidMessageId,
    .invalid_address = AmpeError.InvalidAddress,
    .uds_path_not_found = AmpeError.UDSPathNotFound,
    .invalid_more_usage = AmpeError.InvalidMoreUsage,
    .notification_disabled = AmpeError.NotificationDisabled,
    .notification_failed = AmpeError.NotificationFailed,
    .peer_disconnected = AmpeError.PeerDisconnected,
    .communication_failed = AmpeError.CommunicationFailed,
    .pool_empty = AmpeError.PoolEmpty,
    .allocation_failed = AmpeError.AllocationFailed,
    .waiter_update = AmpeError.WaiterUpdate, // not exactly error
    .channel_closed = AmpeError.ChannelClosed,
    .connect_failed = AmpeError.ConnectFailed,
    .listen_failed = AmpeError.ListenFailed,
    .accept_failed = AmpeError.AcceptFailed,
    .send_failed = AmpeError.SendFailed,
    .recv_failed = AmpeError.RecvFailed,
    .shutdown_started = AmpeError.ShutdownStarted,
    .setsockopt_failed = AmpeError.SetsockoptFailed,
    .processing_failed = AmpeError.ProcessingFailed,
});

pub fn errorToStatus(err: AmpeError) AmpeStatus {
    var iter = StatusToErrorMap.iterator();
    while (iter.next()) |item| {
        if (item.value.* == err) {
            return item.key;
        }
    }

    return AmpeStatus.unknown_error;
}

pub inline fn raw_to_status(rs: u8) AmpeStatus {
    if (rs >= @intFromEnum(AmpeStatus.unknown_error)) {
        return .unknown_error;
    }
    return @enumFromInt(rs);
}

pub inline fn raw_to_error(rs: u8) AmpeError!void {
    if (rs == 0) {
        return;
    }
    if (rs >= @intFromEnum(AmpeStatus.unknown_error)) {
        return AmpeError.UnknownError;
    }

    return StatusToErrorMap.get(@enumFromInt(rs)).?;
}

pub inline fn status_to_raw(status: AmpeStatus) u8 {
    return (@intFromEnum(status));
}

pub inline fn status_to_error(status: AmpeStatus) AmpeError!void {
    return raw_to_error(@intFromEnum(status));
}

const std = @import("std");
