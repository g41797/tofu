// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Asynchronous message passing library for Zig.
//!
//! Peer-to-peer communication over TCP/IP and Unix Domain Sockets.
//!
//! ## Message Lifecycle
//!
//! Get message from pool → configure headers/body → send → receive → return to pool.
//!
//! ## Core Components
//!
//! - **Ampe** - Engine interface for message and channel management
//! - **ChannelGroup** - Interface for message exchange between peers
//! - **Message** - Data structure: binary header, text headers, body
//! - **Reactor** - Implementation: event-driven I/O on dedicated thread
//! - **Configurator** - TCP/UDS connection configuration
//!
//! ## Threading
//!
//! Thread-safe: `get()`, `put()`, `enqueueToPeer()`, `updateReceiver()`, `create()`, `destroy()`
//!
//! Single-threaded: `waitReceive()` must be called from one thread per ChannelGroup.
//!
//! Use multiple ChannelGroups for parallel processing across threads.

/// Async message passing engine interface for managing messages and channels.
pub const Ampe = @import("ampe.zig").Ampe;

/// Strategy for allocating messages from the pool.
pub const AllocationStrategy = @import("ampe.zig").AllocationStrategy;

/// Interface for managing a group of communication channels.
pub const ChannelGroup = @import("ampe.zig").ChannelGroup;

/// Configuration options for the message pool.
pub const Options = @import("ampe.zig").Options;

/// Default configuration options for the message pool.
pub const DefaultOptions = @import("ampe.zig").DefaultOptions;

/// Timeout value for indefinite wait in waitReceive operations.
pub const waitReceive_INFINITE_TIMEOUT = @import("ampe.zig").waitReceive_INFINITE_TIMEOUT;

/// One-second timeout value for waitReceive operations.
pub const waitReceive_SEC_TIMEOUT = @import("ampe.zig").waitReceive_SEC_TIMEOUT;

/// Debug flag indicating whether the build is in debug mode.
pub const DBG = @import("ampe.zig").DBG;

/// Configuration helpers for TCP and UDS connections.
pub const configurator = @import("configurator.zig");

/// Message structure and protocol definitions module.
pub const message = @import("message.zig");

/// Core message structure for asynchronous communication.
pub const Message = message.Message;

/// Binary header containing message metadata.
pub const BinaryHeader = message.BinaryHeader;

/// Status codes and error handling module.
pub const status = @import("status.zig");

/// Status codes for tofu operations.
pub const AmpeStatus = status.AmpeStatus;

/// Error set for tofu operations.
pub const AmpeError = status.AmpeError;

/// Reactor implementation of the Ampe interface using the Reactor pattern.
pub const Reactor = @import("ampe/Reactor.zig");

/// Utility for generating temporary UDS file paths for testing.
pub const TempUdsPath = @import("ampe/testHelpers.zig").TempUdsPath;

/// Helper function to find a free TCP port for testing.
pub const FindFreeTcpPort = @import("ampe/testHelpers.zig").FindFreeTcpPort;

/// Helper function to destroy a ChannelGroup with automatic error handling.
pub const DestroyChannels = @import("ampe/testHelpers.zig").DestroyChannels;

/// Helper function to run multiple tasks concurrently on separate threads.
pub const RunTasks = @import("ampe/testHelpers.zig").RunTasks;

/// Internal APIs not intended for public use.
pub const @"internal usage" = @import("ampe/internal.zig");
