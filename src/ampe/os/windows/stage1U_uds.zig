// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const poc = @import("poc.zig");
const afd = poc.afd;
const ntdllx = poc.ntdllx;
const tofu = @import("tofu");
const Skt = tofu.Skt;
const SocketCreator = tofu.SocketCreator;
const address = tofu.address;

pub const Stage1UUds = struct {
    poller: afd.AfdPoller,
    listen_socket: Skt,
    listen_port: u16,
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*poc.SocketContext),
    skts: std.ArrayList(*Skt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = .{
            .poller = try afd.AfdPoller.init(allocator),
            .listen_socket = undefined,
            .listen_port = 23459,
            .allocator = allocator,
            .connections = try std.ArrayList(*poc.SocketContext).initCapacity(allocator, 4),
            .skts = try std.ArrayList(*Skt).initCapacity(allocator, 4),
        };

        const server_adrs: address.Address = address.Address{ .tcp_server_addr = address.TCPServerAddress.init("127.0.0.1", self.listen_port) };
        var sc: SocketCreator = SocketCreator.init(allocator);
        self.listen_socket = try sc.fromAddress(server_adrs);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.*.listen_socket.deinit();
        for (self.*.connections.items) |c| self.*.allocator.destroy(c);
        for (self.*.skts.items) |s| {
            s.*.deinit();
            self.*.allocator.destroy(s);
        }
        self.*.connections.deinit(self.*.allocator);
        self.*.skts.deinit(self.*.allocator);
        self.*.poller.deinit();
    }

    pub fn run(self: *Self) !void {
        _ = try self.*.poller.register(&self.*.listen_socket);
        var listen_ctx: poc.SocketContext = poc.SocketContext.init(&self.*.listen_socket);
        try listen_ctx.arm(ntdllx.AFD_POLL_ACCEPT, &listen_ctx);

        // Client
        const client_thread: std.Thread = try std.Thread.spawn(.{}, struct {
            fn run(port: u16) void {
                var wsa_data: ws2_32.WSADATA = undefined;
                _ = ws2_32.WSAStartup(0x0202, &wsa_data);
                defer _ = ws2_32.WSACleanup();

                var sc: SocketCreator = SocketCreator.init(std.heap.page_allocator);
                var client_skt: Skt = sc.fromAddress(.{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", port) }) catch return;
                defer client_skt.deinit();

                const server_addr_in: ws2_32.sockaddr.in = .{
                    .family = ws2_32.AF.INET,
                    .port = std.mem.nativeToBig(u16, port),
                    .addr = std.mem.nativeToBig(u32, 0x7f000001),
                    .zero = .{0} ** 8,
                };
                _ = ws2_32.connect(client_skt.socket.?, @ptrCast(&server_addr_in), @sizeOf(ws2_32.sockaddr.in));
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }.run, .{self.*.listen_port});
        defer client_thread.join();

        var entries: [16]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var done: bool = false;
        while (!done) {
            const removed: u32 = try self.*.poller.poll(2000, &entries);
            if (removed == 0) break;

            for (entries[0..removed]) |entry| {
                const ctx: *poc.SocketContext = @ptrCast(@alignCast(entry.ApcContext.?));
                if (ctx == &listen_ctx) {
                    var addr: ws2_32.sockaddr = undefined;
                    var addr_len: i32 = @sizeOf(ws2_32.sockaddr);
                    const client_sock: ws2_32.SOCKET = ws2_32.accept(ctx.*.skt.*.socket.?, &addr, &addr_len);
                    try ctx.*.arm(ntdllx.AFD_POLL_ACCEPT, ctx);

                    if (client_sock != ws2_32.INVALID_SOCKET) {
                        const s: *Skt = try self.*.allocator.create(Skt);
                        s.* = .{ .socket = client_sock, .address = undefined, .server = false };
                        try self.*.skts.append(self.*.allocator, s);
                        _ = try self.*.poller.register(s);
                        
                        const c: *poc.SocketContext = try self.*.allocator.create(poc.SocketContext);
                        c.* = poc.SocketContext.init(s);
                        try self.*.connections.append(self.*.allocator, c);
                        try c.*.arm(ntdllx.AFD_POLL_RECEIVE, c);
                        std.debug.print("[UDS-POC] Server accepted client (simulated via TCP).\n", .{});
                        done = true;
                    }
                }
            }
        }
    }
};

pub fn runTest() !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var stage: Stage1UUds = try Stage1UUds.init(gpa.allocator());
    defer stage.deinit();
    try stage.run();
}
