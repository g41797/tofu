// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Tofu Recipes - Usage examples and patterns for building message-based applications.
//!
//! This module provides comprehensive examples and reusable patterns for working with
//! the tofu asynchronous message passing library. Examples progress from simple to complex,
//! demonstrating the message-as-cube philosophy throughout.
//!
//! ## Quick Start
//!
//! Start with `cookbook` for step-by-step examples:
//! - Basic engine setup and teardown
//! - Message pool management
//! - Connection handling (TCP and UDS)
//! - Complete client-server systems
//!
//! Then explore `services` for the cooperative message processing pattern,
//! and `MultiHomed` for advanced multi-listener server architecture.
//!
//! ## Core Philosophy: Message-as-Cube
//!
//! Every example treats messages as independent cubes:
//! 1. Get cube from pool
//! 2. Configure cube (headers, body)
//! 3. Send cube (ownership transfers)
//! 4. Receive cube
//! 5. Return cube to pool
//!
//! This simple pattern scales from basic echo servers to complex multi-threaded systems.
//!
//! ## Module Overview
//!
//! - **`cookbook`**: Complete collection of usage examples from simple to complex
//! - **`services`**: Cooperative message processing pattern and implementations
//! - **`MultiHomed`**: Multi-listener server pattern (TCP + UDS on one thread)
//!
//! ## Learning Path
//!
//! 1. Read `cookbook` examples in order (top to bottom)
//! 2. Study `services` pattern for cooperative message handling
//! 3. Examine `MultiHomed` for advanced server architectures
//!
//! Each module includes extensive documentation and working examples you can build upon.

/// Complete collection of usage examples from simple to complex.
///
/// Start here to learn tofu step-by-step. Examples build on each other,
/// progressing from basic engine creation to production-like client-server systems.
pub const cookbook = @import("cookbook.zig");

/// Services interface pattern for cooperative message processing.
///
/// Demonstrates how to build modular services that process messages cooperatively.
/// Includes EchoService implementation and complete client-server examples.
pub const services = @import("services.zig");

/// Multihomed server implementation supporting multiple listeners.
///
/// Shows how to build servers with multiple listeners (TCP + UDS) running on
/// a single thread with cooperative message dispatch.
pub const MultiHomed = @import("MultiHomed.zig");

/// Import of the tofu module.
pub const tofu = @import("tofu");

