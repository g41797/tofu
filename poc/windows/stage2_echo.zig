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

pub const Stage2Echo = struct {
    poller: afd.AfdPoller,
    listen_socket: Skt,
    listen_port: u16,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = .{
            .poller = try afd.AfdPoller.init(allocator),
            .listen_socket = undefined,
            .listen_port = 23458,
            .allocator = allocator,
        };

        const server_adrs: address.Address = address.Address{ .tcp_server_addr = address.TCPServerAddress.init("127.0.0.1", self.listen_port) };
        var sc: SocketCreator = SocketCreator.init(allocator);
        self.listen_socket = try sc.fromAddress(server_adrs);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.*.listen_socket.deinit();
        self.*.poller.deinit();
    }

    pub fn run(self: *Self) !void {
        const listen_base: windows.HANDLE = try self.*.poller.register(&self.*.listen_socket);
        _ = listen_base;
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
                _ = ws2_32.send(client_skt.socket.?, "Tofu Engine", 11, 0);

                var buf: [1024]u8 = undefined;
                _ = ws2_32.recv(client_skt.socket.?, &buf, buf.len, 0);
            }
        }.run, .{self.*.listen_port});
        defer client_thread.join();

        var entries: [16]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var connection_skt: ?*Skt = null;
        var connection_ctx: ?*poc.SocketContext = null;
        defer {
            if (connection_skt) |s| {
                s.*.deinit();
                self.*.allocator.destroy(s);
            }
            if (connection_ctx) |c| self.*.allocator.destroy(c);
        }

        var done: bool = false;
        while (!done) {
            const removed: u32 = try self.*.poller.poll(5000, &entries);
            if (removed == 0) break;

            for (entries[0..removed]) |entry| {
                const ctx: *poc.SocketContext = @ptrCast(@alignCast(entry.ApcContext.?));

                if (ctx == &listen_ctx) {
                    var addr: ws2_32.sockaddr = undefined;
                    var addr_len: i32 = @sizeOf(ws2_32.sockaddr);
                    const client_sock: ws2_32.SOCKET = ws2_32.accept(ctx.*.skt.*.socket.?, &addr, &addr_len);
                    try ctx.*.arm(ntdllx.AFD_POLL_ACCEPT, ctx);

                    if (client_sock != ws2_32.INVALID_SOCKET) {
                        connection_skt = try self.*.allocator.create(Skt);
                        connection_skt.?.* = .{
                            .socket = client_sock,
                            .address = undefined, // Not needed for echo
                            .server = false,
                        };
                        _ = try self.*.poller.register(connection_skt.?);

                        connection_ctx = try self.*.allocator.create(poc.SocketContext);
                        connection_ctx.?.* = poc.SocketContext.init(connection_skt.?);
                        try connection_ctx.?.arm(ntdllx.AFD_POLL_RECEIVE, connection_ctx.?);
                        std.debug.print("[Echo-POC] Server accepted client.\n", .{});
                    }
                } else {
                    const events: u32 = @intCast(entry.IoStatus.Information); // This is actually the triggered events for AFD_POLL
                    _ = events;

                    var buf: [1024]u8 = undefined;
                    const bytes: i32 = ws2_32.recv(ctx.*.skt.*.socket.?, &buf, buf.len, 0);
                    if (bytes == ws2_32.SOCKET_ERROR) {
                        if (ws2_32.WSAGetLastError() == .WSAEWOULDBLOCK) {
                            try ctx.*.arm(ntdllx.AFD_POLL_RECEIVE, ctx);
                        } else {
                            done = true;
                        }
                    } else if (bytes == 0) {
                        done = true;
                    } else if (bytes > 0) {
                        std.debug.print("[Echo-POC] Server received: {s}\n", .{buf[0..@intCast(bytes)]});
                        _ = ws2_32.send(ctx.*.skt.*.socket.?, &buf, @intCast(bytes), 0);
                        done = true;
                    }
                }
            }
        }
        std.debug.print("[Echo-POC] Finished.\n", .{});
    }
};

pub fn runTest() !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var stage: Stage2Echo = try Stage2Echo.init(gpa.allocator());
    defer stage.deinit();
    try stage.run();
}
