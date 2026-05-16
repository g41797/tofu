// Windows portable SocketCreator: std.net.Address.initUnix is unavailable on Windows.
// TCP uses std.net.Address + pn_create_listen_socket_from_sockaddr (same as linux/mac).
// UDS uses pn.createListenSocketUnix / pn.createClientSocket with uds_path field in Skt.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const tofu = @import("../../../tofu.zig");
const AmpeError = tofu.status.AmpeError;
const Skt = @import("Skt.zig").Skt;
const message = tofu.message;
const Message = message.Message;
const pn = @import("posix_net");
const address = tofu.address;
const Address = address.Address;
const TCPServerAddress = address.TCPServerAddress;
const TCPClientAddress = address.TCPClientAddress;
const TempUdsPath = tofu.TempUdsPath;

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
    const addr = if (cnf.addrToSlice().len == 0)
        std.net.Address.initIp4(.{ 0, 0, 0, 0 }, cnf.port orelse 0)
    else
        std.net.Address.resolveIp(cnf.addrToSlice(), cnf.port orelse 0) catch |e| {
            log.warn("createTcpServer resolveIp failed: {s}", .{@errorName(e)});
            return AmpeError.InvalidAddress;
        };
    return createListenerSocket(&addr) catch AmpeError.ListenFailed;
}

pub fn createTcpClient(sc: *SocketCreator) AmpeError!Skt {
    const cnf = &sc.addrs.tcp_client_addr;
    var list = std.net.getAddressList(sc.allocator, cnf.addrToSlice(), cnf.port orelse 0) catch {
        return AmpeError.InvalidAddress;
    };
    defer list.deinit();
    if (list.addrs.len == 0) return AmpeError.InvalidAddress;
    for (list.addrs) |addr| {
        const skt = createConnectSocket(&addr) catch continue;
        return skt;
    }
    return AmpeError.InvalidAddress;
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
    var skt = Skt{ .fd = fd, .server = true, .uds_path = [_]u8{0} ** pn.UDS_PATH_SIZE };
    if (udsPath.len > 0 and udsPath[0] != 0) {
        const copy_len = @min(udsPath.len, pn.UDS_PATH_SIZE);
        @memcpy(skt.uds_path.?[0..copy_len], udsPath[0..copy_len]);
    }
    return skt;
}

pub fn createUdsClient(sc: *SocketCreator) AmpeError!Skt {
    return createUdsSocket(sc.addrs.uds_client_addr.addrToSlice());
}

pub fn createUdsSocket(path: []const u8) AmpeError!Skt {
    const fd = pn.createClientSocket(pn.AF_UNIX) catch return AmpeError.ConnectFailed;
    pn.setLingerAbort(fd);
    var skt = Skt{ .fd = fd, .uds_path = [_]u8{0} ** pn.UDS_PATH_SIZE };
    const copy_len = @min(path.len, pn.UDS_PATH_SIZE);
    @memcpy(skt.uds_path.?[0..copy_len], path[0..copy_len]);
    return skt;
}

/// Create a TCP/IP listening socket from std.net.Address (IPv4 or IPv6).
pub fn createListenerSocket(addr: *const std.net.Address) !Skt {
    const fd = pn.createListenSocketFromSockaddr(&addr.any, addr.getOsSockLen()) catch return AmpeError.ListenFailed;
    return Skt{ .fd = fd, .address = addr.*, .server = true };
}

/// Create a non-blocking client socket (no connect). Caller calls Skt.connect() next.
pub fn createConnectSocket(addr: *const std.net.Address) !Skt {
    const fd = pn.createClientSocket(@intCast(addr.any.family)) catch return AmpeError.ConnectFailed;
    pn.setLingerAbort(fd);
    return Skt{ .fd = fd, .address = addr.* };
}
