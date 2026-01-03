// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Async message passing over TCP/UDS.

pub const Ampe = @import("ampe.zig").Ampe;
pub const AllocationStrategy = @import("ampe.zig").AllocationStrategy;
pub const ChannelGroup = @import("ampe.zig").ChannelGroup;
pub const Options = @import("ampe.zig").Options;
pub const DefaultOptions = @import("ampe.zig").DefaultOptions;
pub const waitReceive_INFINITE_TIMEOUT = @import("ampe.zig").waitReceive_INFINITE_TIMEOUT;
pub const waitReceive_SEC_TIMEOUT = @import("ampe.zig").waitReceive_SEC_TIMEOUT;
pub const DBG = @import("ampe.zig").DBG;
pub const address = @import("address.zig");
pub const message = @import("message.zig");
pub const Message = message.Message;
pub const BinaryHeader = message.BinaryHeader;
pub const OpCode = message.OpCode;
pub const status = @import("status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;
pub const Reactor = @import("ampe/Reactor.zig");
pub const TempUdsPath = @import("ampe/testHelpers.zig").TempUdsPath;
pub const FindFreeTcpPort = @import("ampe/testHelpers.zig").FindFreeTcpPort;
pub const DestroyChannels = @import("ampe/testHelpers.zig").DestroyChannels;
pub const RunTasks = @import("ampe/testHelpers.zig").RunTasks;
pub const @"internal usage" = @import("ampe/internal.zig");
