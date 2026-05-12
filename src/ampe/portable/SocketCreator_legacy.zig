const std = @import("std");
const Allocator = std.mem.Allocator;
const tofu = @import("../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
const Skt = @import("Skt.zig").Skt;
const message = tofu.message;
const Message = message.Message;
const pn = @import("posix_net");
const address = tofu.address;
const Address = address.Address;
const TCPServerAddress = address.TCPServerAddress;
const TCPClientAddress = address.TCPClientAddress;
const UDSServerAddress = address.UDSServerAddress;
const UDSClientAddress = address.UDSClientAddress;
const TempUdsPath = tofu.TempUdsPath;
const log = std.log;
const builtin = @import("builtin");

pub const SocketCreator = @This();

allocator: Allocator = undefined,
addrs: Address = .wrong,

pub fn init(allocator: Allocator) SocketCreator {
    return .{ .allocator = allocator };
}

pub fn parse(sc: *SocketCreator, msg: *Message) AmpeError!Skt {
    const addrs = Address.parse(msg);
    return sc.fromAddress(addrs);
}

pub fn fromAddress(sc: *SocketCreator, addrs: Address) AmpeError!Skt {
    sc.addrs = addrs;
    return switch (sc.addrs) {
        .wrong => AmpeError.InvalidAddress,
        .tcp_server_addr => sc.createTcpServer(),
        .tcp_client_addr => sc.createTcpClient(),
        .uds_server_addr => sc.createUdsServer(),
        .uds_client_addr => sc.createUdsClient(),
    };
}

pub fn createTcpServer(sc: *SocketCreator) AmpeError!Skt {
    const cnf = &sc.addrs.tcp_server_addr;
    const host = cnf.addrToSlice();
    const fd = pn.createListenSocket(@ptrCast(host.ptr), cnf.port orelse 0, 0) catch |e| {
        log.warn("createTcpServer failed: {s}", .{@errorName(e)});
        return AmpeError.ListenFailed;
    };
    return Skt{ .fd = fd, .server = true };
}

pub fn createTcpClient(sc: *SocketCreator) AmpeError!Skt {
    const cnf = &sc.addrs.tcp_client_addr;
    const host = cnf.addrToSlice();
    const fd = pn.resolveConnect(host.ptr[0..host.len :0], cnf.port orelse 0) catch |e| {
        log.warn("createTcpClient failed: {s}", .{@errorName(e)});
        return if (e == pn.PnError.InvalidAddress) AmpeError.InvalidAddress else AmpeError.ConnectFailed;
    };
    return Skt{ .fd = fd };
}

pub fn createUdsServer(sc: *SocketCreator) AmpeError!Skt {
    return createUdsListener(sc.allocator, sc.addrs.uds_server_addr.addrToSlice());
}

pub fn createUdsListener(allocator: Allocator, path: []const u8) AmpeError!Skt {
    var udsPath = path;
    var tup: ?TempUdsPath = null;
    if (udsPath.len == 0) {
        tup = TempUdsPath{};
        udsPath = tup.?.buildPath(allocator) catch return AmpeError.UnknownError;
    }

    const fd = pn.createListenSocketUnix(udsPath.ptr, udsPath.len, 0) catch |e| {
        log.warn("createUdsListener failed: {s}", .{@errorName(e)});
        return AmpeError.ListenFailed;
    };

    var skt = Skt{ .fd = fd, .server = true, .uds_server_path = [_]u8{0} ** pn.UDS_PATH_SIZE };
    if (udsPath.len > 0 and udsPath[0] != 0) {
        const copy_len = @min(udsPath.len, pn.UDS_PATH_SIZE);
        @memcpy(skt.uds_server_path.?[0..copy_len], udsPath[0..copy_len]);
    }
    return skt;
}

pub fn createUdsClient(sc: *SocketCreator) AmpeError!Skt {
    return createUdsSocket(sc.addrs.uds_client_addr.addrToSlice());
}

pub fn createUdsSocket(path: []const u8) AmpeError!Skt {
    const fd = pn.createSocket(pn.AF_UNIX, pn.SOCK_STREAM, 0) catch |e| {
        log.warn("createUdsSocket createSocket failed: {s}", .{@errorName(e)});
        return AmpeError.InvalidAddress;
    };
    var skt = Skt{ .fd = fd, .uds_server_path = [_]u8{0} ** pn.UDS_PATH_SIZE };
    const copy_len = @min(path.len, pn.UDS_PATH_SIZE);
    @memcpy(skt.uds_server_path.?[0..copy_len], path[0..copy_len]);
    return skt;
}

pub fn createListenerSocket(_: *const std.net.Address) !Skt {
    return AmpeError.NotImplementedYet;
}

pub fn createConnectSocket(addr: *const std.net.Address) !Skt {
    const fd = pn.createClientSocket(@intCast(addr.any.family)) catch return AmpeError.ConnectFailed;
    return Skt{ .fd = fd };
}
