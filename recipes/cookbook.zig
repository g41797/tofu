const std = @import("std");
const Allocator = std.mem.Allocator;

pub const tofu = @import("tofu");
pub const Distributor = tofu.Distributor;
pub const Options = tofu.Options;
pub const DefaultOptions = tofu.DefaultOptions;

pub fn createDestroyMainStruct(gpa: Allocator) !void {
    var dtr = try Distributor.Create(gpa, DefaultOptions);
    defer dtr.Destroy();
}

pub fn createDestroyMsgEngine(gpa: Allocator) !void {
    var dtr = try Distributor.Create(gpa, DefaultOptions);
    defer dtr.Destroy();

    const ampe = try dtr.ampe();

    // You don't need to destroy/deinit ampe - it's just interface implemented by Distributor
    _ = ampe;
}

pub fn createDestroyMessageChannelGroup(gpa: Allocator) !void {
    var dtr = try Distributor.Create(gpa, DefaultOptions);
    defer dtr.Destroy();

    const ampe = try dtr.ampe();

    const mcg = try ampe.acquire();

    // You destroy MessageChannelGroup via release it by ampe
    try ampe.release(mcg);
}

pub fn hi() void {
    if (tofu.DBG) {
        std.log.debug("   ****  tofu HI (DEBUG MODE)  ****", .{});
    } else {
        std.log.debug("   ****  tofu HI (NON-DEBUG MODE)  ****", .{});
    }
}

pub fn bye() void {
    std.log.debug("   ****  tofu BYE  ****", .{});
}
