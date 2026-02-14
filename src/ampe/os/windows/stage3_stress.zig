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

pub const Stage3Stress = struct {
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
            .listen_port = 23460,
            .allocator = allocator,
            .connections = try std.ArrayList(*poc.SocketContext).initCapacity(allocator, 16),
            .skts = try std.ArrayList(*Skt).initCapacity(allocator, 16),
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

        const NUM_CLIENTS: usize = 5;
        const MESSAGES_PER_CLIENT: usize = 10;
        const TARGET_MESSAGES: usize = NUM_CLIENTS * MESSAGES_PER_CLIENT;

        std.debug.print("[Stress-POC] Starting {d} clients, target messages: {d}\n", .{ NUM_CLIENTS, TARGET_MESSAGES });

        var client_threads: [NUM_CLIENTS]std.Thread = undefined;
        for (0..NUM_CLIENTS) |i| {
            client_threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(port: u16, id: usize) void {
                    var wsa_data: ws2_32.WSADATA = undefined;
                    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
                    defer _ = ws2_32.WSACleanup();

                    var sc: SocketCreator = SocketCreator.init(std.heap.page_allocator);
                    var client_skt: Skt = sc.fromAddress(.{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", port) }) catch {
                        std.debug.print("[Client-{d}] Creation failed\n", .{id});
                        return;
                    };
                    defer client_skt.deinit();

                    // Use Skt.connect() retry loop — handles WSAEWOULDBLOCK/WSAEISCONN safely
                    var connected: bool = client_skt.connect() catch |err| {
                        std.debug.print("[Client-{d}] connect error: {any}\n", .{id, err});
                        return;
                    };
                    while (!connected) {
                        std.Thread.sleep(10 * std.time.ns_per_ms);
                        connected = client_skt.connect() catch |err| {
                            std.debug.print("[Client-{d}] retry connect error: {any}\n", .{id, err});
                            return;
                        };
                    }

                    std.debug.print("[Client-{d}] Connected!\n", .{id});

                    for (0..10) |m| {
                        const sent = ws2_32.send(client_skt.socket.?, "Ping", 4, 0);
                        if (sent == ws2_32.SOCKET_ERROR) {
                            std.debug.print("[Client-{d}] send error: {any}\n", .{id, ws2_32.WSAGetLastError()});
                            break;
                        }
                        
                        var buf: [16]u8 = undefined;
                        const recvd = ws2_32.recv(client_skt.socket.?, &buf, buf.len, 0);
                        if (recvd <= 0) {
                            if (ws2_32.WSAGetLastError() == .WSAEWOULDBLOCK) {
                                std.Thread.sleep(10 * std.time.ns_per_ms);
                                // Simple retry for POC
                                const recvd2 = ws2_32.recv(client_skt.socket.?, &buf, buf.len, 0);
                                if (recvd2 <= 0) {
                                    std.debug.print("[Client-{d}] recv retry failed: {any}\n", .{id, ws2_32.WSAGetLastError()});
                                    break;
                                }
                            } else {
                                std.debug.print("[Client-{d}] recv error: {any}\n", .{id, ws2_32.WSAGetLastError()});
                                break;
                            }
                        }
                        _ = m;
                    }
                    std.debug.print("[Client-{d}] Finished\n", .{id});
                }
            }.run, .{self.*.listen_port, i});
        }

        var entries: [32]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var messages_handled: usize = 0;
        var clients_accepted: usize = 0;
        var consecutive_idle_timeouts: usize = 0;
        var last_handled: usize = 0;

        while (messages_handled < TARGET_MESSAGES) {
            std.debug.print("[Stress-POC] Polling... (handled {d}/{d}, accepted {d}/{d})\n", .{ messages_handled, TARGET_MESSAGES, clients_accepted, NUM_CLIENTS });
            const removed: u32 = try self.*.poller.poll(5000, &entries);
            if (removed == 0) {
                std.debug.print("[Stress-POC] Poll timeout, handled: {d}/{d}, accepted: {d}/{d}\n", .{ messages_handled, TARGET_MESSAGES, clients_accepted, NUM_CLIENTS });
                if (messages_handled == last_handled) {
                    consecutive_idle_timeouts += 1;
                } else {
                    consecutive_idle_timeouts = 0;
                    last_handled = messages_handled;
                }
                // After all clients accepted and 3 consecutive timeouts with no progress, exit
                if (clients_accepted == NUM_CLIENTS and consecutive_idle_timeouts >= 3) {
                    std.debug.print("[Stress-POC] Stalled after {d} messages, exiting.\n", .{messages_handled});
                    break;
                }
                continue;
            }

            for (entries[0..removed]) |entry| {
                const ctx: *poc.SocketContext = @ptrCast(@alignCast(entry.ApcContext.?));
                const events: u32 = @intCast(entry.IoStatus.Information);

                if (ctx == &listen_ctx) {
                    var addr: ws2_32.sockaddr = undefined;
                    var addr_len: i32 = @sizeOf(ws2_32.sockaddr);
                    const client_sock: ws2_32.SOCKET = ws2_32.accept(ctx.*.skt.*.socket.?, &addr, &addr_len);
                    if (client_sock == ws2_32.INVALID_SOCKET) {
                        std.debug.print("[Stress-POC] Accept returned INVALID_SOCKET, error: {any}\n", .{ws2_32.WSAGetLastError()});
                    }
                    try ctx.*.arm(ntdllx.AFD_POLL_ACCEPT, ctx);

                    if (client_sock != ws2_32.INVALID_SOCKET) {
                        std.debug.print("[Stress-POC] Accepted new client socket: {any}\n", .{client_sock});
                        const s: *Skt = try self.*.allocator.create(Skt);
                        s.* = .{ .socket = client_sock, .address = undefined, .server = false };
                        try self.*.skts.append(self.*.allocator, s);
                        _ = try self.*.poller.register(s);
                        
                        const c: *poc.SocketContext = try self.*.allocator.create(poc.SocketContext);
                        c.* = poc.SocketContext.init(s);
                        try self.*.connections.append(self.*.allocator, c);
                        try c.*.arm(ntdllx.AFD_POLL_RECEIVE, c);
                        clients_accepted += 1;
                    }
                } else {
                    if ((events & (ntdllx.AFD_POLL_ABORT | ntdllx.AFD_POLL_LOCAL_CLOSE | ntdllx.AFD_POLL_CONNECT_FAIL)) != 0) {
                        continue; 
                    }

                    var buf: [1024]u8 = undefined;
                    const bytes: i32 = ws2_32.recv(ctx.*.skt.*.socket.?, &buf, buf.len, 0);
                    
                    if (bytes > 0) {
                        _ = ws2_32.send(ctx.*.skt.*.socket.?, &buf, @intCast(bytes), 0);
                        messages_handled += @divFloor(@as(usize, @intCast(bytes)), 4); // each "Ping" = 4 bytes
                        try ctx.*.arm(ntdllx.AFD_POLL_RECEIVE, ctx);
                    } else if (bytes == 0) {
                        // Client closed
                    } else {
                        const err = ws2_32.WSAGetLastError();
                        if (err == .WSAEWOULDBLOCK) {
                            try ctx.*.arm(ntdllx.AFD_POLL_RECEIVE, ctx);
                        }
                    }
                }
            }
        }

        for (client_threads) |t| t.join();
        std.debug.print("[Stress-POC] Finished. Handled {d} messages.\n", .{ messages_handled });
    }
};

pub fn runTest() !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var stage: Stage3Stress = try Stage3Stress.init(gpa.allocator());
    defer stage.deinit();
    stage.run() catch |err| {
        std.debug.print("[Stress-POC] Failed with error: {s}\n", .{@errorName(err)});
        return err;
    };
}
