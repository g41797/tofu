const builtin = @import("builtin");

pub const SocketCreator = switch (builtin.os.tag) {
    .linux => @import("linux/SocketCreator.zig").SocketCreator,
    .macos => @import("mac/SocketCreator.zig").SocketCreator,
    .windows => @import("win/SocketCreator.zig").SocketCreator,
    else => @compileError("portable backend: unsupported OS"),
};
