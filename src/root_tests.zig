// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    _ = @import("root.zig");
    @import("std").testing.refAllDecls(@This());
}

const std = @import("std");
