const builtin = @import("builtin");

pub const Skt = switch (builtin.os.tag) {
    .linux => @import("linux/Skt.zig").Skt,
    .macos => @import("mac/Skt.zig").Skt,
    .windows => @import("win/Skt.zig").Skt,
    else => @compileError("portable backend: unsupported OS"),
};
