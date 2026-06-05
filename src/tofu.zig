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
pub const address = @import("address.zig");
pub const message = @import("message.zig");
pub const Message = message.Message;
pub const BinaryHeader = message.BinaryHeader;
pub const OpCode = message.OpCode;
pub const status = @import("status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;

// Ampe factory/implementation
pub const Reactor = @import("ampe/Reactor.zig");

// Mostly for tests
pub const TempUdsPath = @import("ampe/helpers.zig").TempUdsPath;
pub const FindFreeTcpPort = @import("ampe/helpers.zig").FindFreeTcpPort;
pub const DestroyChannels = @import("ampe/helpers.zig").DestroyChannels;
pub const RunTasks = @import("ampe/helpers.zig").RunTasks;
pub const SleepMlsec = @import("ampe/helpers.zig").SleepMlsec;
pub const AutoArrayHashMap = @import("ampe/helpers.zig").AutoArrayHashMap;

// Allow access to internals
pub const @"internal usage" = @import("ampe/internal.zig");

pub const DBG = @import("ampe.zig").DBG;
