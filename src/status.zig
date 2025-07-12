// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const AMPStatus = enum(u8) {
    success = 0,
    invalid_order = 1,
    insufficient_funds = 2,
    market_closed = 3,
    network_error = 4,
    unknown_error,
};

pub const AMPError = error{
    InvalidOrder,
    InsufficientFunds,
    MarketClosed,
    NetworkError,
    UnknownError,
};

// Comptime mapping from AMPStatus to AMPError.
const StatusToErrorMap = std.enums.EnumMap(AMPStatus, AMPError).init(.{
    .invalid_order = .InvalidOrder,
    .insufficient_funds = .InsufficientFunds,
    .market_closed = .MarketClosed,
    .network_error = .NetworkError,
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

const std = @import("std");
