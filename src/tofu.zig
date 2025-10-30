// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Ampe = @import("ampe.zig").Ampe;
pub const AllocationStrategy = @import("ampe.zig").AllocationStrategy;
pub const Channels = @import("ampe.zig").Channels;
pub const Options = @import("ampe.zig").Options;
pub const DefaultOptions = @import("ampe.zig").DefaultOptions;

pub const waitReceive_INFINITE_TIMEOUT = @import("ampe.zig").waitReceive_INFINITE_TIMEOUT;
pub const waitReceive_SEC_TIMEOUT = @import("ampe.zig").waitReceive_SEC_TIMEOUT;

pub const DBG = @import("ampe.zig").DBG;

pub const configurator = @import("configurator.zig");
pub const message = @import("message.zig");
pub const status = @import("status.zig");
pub const Engine = @import("ampe/Engine.zig");

// For test lovers
pub const TempUdsPath = @import("ampe/testHelpers.zig").TempUdsPath;
pub const FindFreeTcpPort = @import("ampe/testHelpers.zig").FindFreeTcpPort;
pub const DestroyChannels = @import("ampe/testHelpers.zig").DestroyChannels;
pub const @"internal usage" = @import("ampe/internal.zig");
