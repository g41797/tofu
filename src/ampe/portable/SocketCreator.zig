const builtin = @import("builtin");

pub const SocketCreator = switch (builtin.os.tag) {
    .linux => @import("linux/SocketCreator.zig").SocketCreator,
    else => @import("SocketCreator_legacy.zig").SocketCreator,
};
