// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const protocol = @import("protocol.zig");
pub const MessageType = protocol.MessageType;
pub const MessageMode = protocol.MessageMode;
pub const OriginFlag = protocol.OriginFlag;
pub const MoreMessagesFlag = protocol.MoreMessagesFlag;
pub const ProtoFields = protocol.ProtoFields;
pub const BinaryHeader = protocol.BinaryHeader;
pub const TextHeader = protocol.TextHeader;
pub const TextHeaderIterator = @import("TextHeaderIterator.zig");
pub const TextHeaders = protocol.TextHeaders;
pub const Message = protocol.Message;
pub const Options = protocol.Options;
pub const Ampe = protocol.Ampe;
pub const Sr = protocol.Sr;

pub const status = @import("status.zig");
pub const AMPStatus = status.AMPStatus;
pub const AMPError = status.AMPError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;

pub const configurator = @import("configurator.zig");
pub const TCPClientConfigurator = configurator.TCPClientConfigurator;
pub const TCPServerConfigurator = configurator.TCPServerConfigurator;
pub const UDSClientConfigurator = configurator.UDSClientConfigurator;
pub const UDSServerConfigurator = configurator.UDSServerConfigurator;
pub const Configurator = configurator.Configurator;

pub const Poller = @import("protocol/Poller.zig");

pub const Appendable = @import("nats").Appendable;

const std = @import("std");
