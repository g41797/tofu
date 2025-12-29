// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Usage examples for tofu message passing library.
//!
//! ## Modules
//!
//! - **`cookbook`** - Examples from basic to advanced (read top to bottom)
//! - **`services`** - Cooperative message processing pattern
//! - **`MultiHomed`** - Multi-listener server (TCP + UDS on one thread)

/// Usage examples from basic to advanced operations.
pub const cookbook = @import("cookbook.zig");

/// Cooperative message processing pattern.
pub const services = @import("services.zig");

/// Multi-listener server implementation.
pub const MultiHomed = @import("MultiHomed.zig");
