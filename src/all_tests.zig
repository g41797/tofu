// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    _ = @import("message_tests.zig");
    _ = @import("configurator_tests.zig");
    _ = @import("engine_test.zig");
    _ = @import("engine/Pool_tests.zig");
    _ = @import("engine/Notifier_tests.zig");
    _ = @import("engine/channels_tests.zig");
    @import("std").testing.refAllDecls(@This());
}
