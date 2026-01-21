//! Working examples - all are used in the tests.
//!
// ! ## Modules
//!
//! - **`cookbook`** - Examples from basic to advanced
//! - **`services`** - Example of dumb message processing
//! - **`MultiHomed`** - Multi-listener server (TCP + UDS on one thread)

pub const cookbook = @import("cookbook.zig");
pub const services = @import("services.zig");
pub const MultiHomed = @import("MultiHomed.zig");
