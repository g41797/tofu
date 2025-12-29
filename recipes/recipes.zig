// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! Usage examples for tofu message passing library.
//!
//! ## Modules
//!
//! - **`cookbook`** - Examples from basic to advanced (read top to bottom)
//! - **`services`** - Cooperative message processing pattern
//! - **`MultiHomed`** - Multi-listener server (TCP + UDS on one thread)

pub const cookbook = @import("cookbook.zig");
pub const services = @import("services.zig");
pub const MultiHomed = @import("MultiHomed.zig");
