const builtin = @import("builtin");

pub const Skt = switch (builtin.os.tag) {
    .linux => @import("linux/Skt.zig").Skt,
    else => @import("Skt_legacy.zig").Skt,
};
