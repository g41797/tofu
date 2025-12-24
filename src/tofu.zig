// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! # Tofu - Asynchronous Message Passing for Zig
//!
//! Tofu is an asynchronous message passing library providing peer-to-peer, duplex communication
//! over TCP/IP and Unix Domain Sockets. Built on the Reactor pattern, it enables non-blocking,
//! message-based communication with a focus on simplicity and gradual complexity.
//!
//! ## Core Philosophy
//!
//! **Message as both data and API** - Messages are discrete units ("cubes") that flow through
//! the system. Get cube from pool → configure → send → receive → return to pool.
//!
//! **Gradual evolution** - Start simple (single-threaded echo server), grow to complex
//! (multi-threaded, multi-listener systems) using the same patterns.
//!
//! **Stream-oriented transport** - TCP/IP and Unix Domain Sockets for reliable, ordered delivery.
//!
//! **Multithread-friendly** - Thread-safe APIs with internal message pooling and backpressure management.
//!
//! ## Quick Start
//!
//! 1. Create a Reactor (the async message passing engine)
//! 2. Get the Ampe interface for message/channel management
//! 3. Create a ChannelGroup for message exchange
//! 4. Get messages from pool, configure, send/receive
//! 5. Clean up: return messages to pool, destroy channels, destroy reactor
//!
//! See the recipes module for comprehensive examples from basic to advanced patterns.
//!
//! ## Key Components
//!
//! - **Ampe** - Async message passing engine interface (get/put messages, create/destroy channels)
//! - **ChannelGroup** - Interface for message exchange (enqueueToPeer, waitReceive)
//! - **Message** - Core data structure with binary header, text headers, and body
//! - **Reactor** - Concrete implementation using Reactor pattern with event-driven I/O
//! - **Configurator** - Helpers for TCP/UDS connection setup
//!
//! ## Architecture Highlights
//!
//! - **Reactor Pattern**: Single-threaded event loop handles all I/O
//! - **Message Pool**: Pre-allocated messages reduce allocation overhead
//! - **Backpressure**: Pool control prevents memory exhaustion
//! - **Thread Safety**: Application threads safely interact with reactor thread
//! - **Intrusive Data Structures**: Zero-allocation message queuing
//!
//! ## Threading Model
//!
//! Thread-safe operations:
//! - `get()`, `put()` - Message pool access
//! - `enqueueToPeer()` - Send messages
//! - `updateReceiver()` - Wake receiver or send notifications
//! - `create()`, `destroy()` - Channel group lifecycle
//!
//! Single-threaded constraint:
//! - `waitReceive()` - Must be called from ONE thread per ChannelGroup
//!
//! Multiple ChannelGroups can be used from different threads for parallel message processing.

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
