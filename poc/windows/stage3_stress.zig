// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

pub const Stage3Stress = struct {
    poller: afd.AfdPoller,
    listen_socket: Skt,
    client_addr: address.Address,
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*poc.SocketContext),
    skts: std.ArrayList(*Skt),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, server_addr: address.Address, client_addr: address.Address) !Self {
        var self: Self = .{
            .poller = try afd.AfdPoller.init(allocator),
            .listen_socket = undefined,
            .client_addr = client_addr,
            .allocator = allocator,
            .connections = try std.ArrayList(*poc.SocketContext).initCapacity(allocator, 16),
            .skts = try std.ArrayList(*Skt).initCapacity(allocator, 16),
        };

        var sc: SocketCreator = SocketCreator.init(allocator);
        self.listen_socket = try sc.fromAddress(server_addr);

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
                fn run(client_addr: address.Address, id: usize) void {
                    const allocator = std.heap.page_allocator;

                    var local_poller = afd.AfdPoller.init(allocator) catch {
                        std.debug.print("[Client-{d}] Poller init failed\n", .{id});
                        return;
                    };
                    defer local_poller.deinit();

                    var sc: SocketCreator = SocketCreator.init(allocator);
                    const client_skt_val: Skt = sc.fromAddress(client_addr) catch {
                        std.debug.print("[Client-{d}] Creation failed\n", .{id});
                        return;
                    };
                    // Move Skt to heap so we can point to it in SocketContext
                    const client_skt = allocator.create(Skt) catch return;
                    client_skt.* = client_skt_val;
                    defer {
                        client_skt.deinit();
                        allocator.destroy(client_skt);
                    }

                    _ = local_poller.register(client_skt) catch {
                        std.debug.print("[Client-{d}] Register failed\n", .{id});
                        return;
                    };

                    var ctx = poc.SocketContext.init(client_skt);
                    var entries: [1]ntdllx.FILE_COMPLETION_INFORMATION = undefined;

                    // 1. Initial Connection Reactor step
                    std.debug.print("[Client-{d}] Starting connect...\n", .{id});
                    if (client_skt.connect() catch |err| {
                        std.debug.print("[Client-{d}] Connect error: {any}\n", .{ id, err });
                        return;
                    }) {
                        std.debug.print("[Client-{d}] Connected immediately!\n", .{id});
                    } else {
                        while (true) {
                            ctx.arm(ntdllx.AFD_POLL_CONNECT, &ctx) catch return;
                            _ = local_poller.poll(5000, &entries) catch return;
                            if (ctx.poll_info.Handles[0].Events == 0) continue;
                            if (client_skt.connect() catch |err| {
                                std.debug.print("[Client-{d}] connect retry error: {any}\n", .{ id, err });
                                return;
                            }) {
                                std.debug.print("[Client-{d}] Connected async!\n", .{id});
                                break;
                            }
                        }
                    }

                    // 2. Data Exchange Reactor Loop
                    var pings_sent: usize = 0;
                    var pongs_recvd: usize = 0;
                    const TOTAL_PINGS: usize = 10;

                    while (pongs_recvd < TOTAL_PINGS) {
                        // Determine what we are interested in
                        var interest: u32 = ntdllx.AFD_POLL_RECEIVE;
                        if (pings_sent < TOTAL_PINGS and pings_sent == pongs_recvd) {
                            interest |= ntdllx.AFD_POLL_SEND;
                        }

                        ctx.arm(interest, &ctx) catch |err| {
                            std.debug.print("[Client-{d}] Arm error: {any}\n", .{ id, err });
                            break;
                        };

                        const removed = local_poller.poll(5000, &entries) catch |err| {
                            std.debug.print("[Client-{d}] Poll error: {any}\n", .{ id, err });
                            break;
                        };

                        if (removed == 0) continue;

                        const events = ctx.poll_info.Handles[0].Events;
                        if (events == 0) continue;

                        // Process SEND readiness
                        if ((events & ntdllx.AFD_POLL_SEND) != 0) {
                            if (pings_sent < TOTAL_PINGS and pings_sent == pongs_recvd) {
                                _ = client_skt.send("Ping") catch |err| {
                                    std.debug.print("[Client-{d}] Send error: {any}\n", .{ id, err });
                                    break;
                                };
                                std.debug.print("[Client-{d}] Sent ping {d}\n", .{ id, pings_sent });
                                pings_sent += 1;
                            }
                        }

                        // Process RECEIVE readiness
                        if ((events & ntdllx.AFD_POLL_RECEIVE) != 0) {
                            var buf: [16]u8 = undefined;
                            const bytes = client_skt.recv(&buf) catch |err| {
                                if (err == error.WouldBlock) continue;
                                std.debug.print("[Client-{d}] Recv error: {any}\n", .{ id, err });
                                break;
                            };

                            if (bytes > 0) {
                                std.debug.print("[Client-{d}] Received pong {d} ({d} bytes)\n", .{ id, pongs_recvd, bytes });
                                pongs_recvd += 1;
                            }
                        }

                        // Handle errors/disconnects
                        if ((events & (ntdllx.AFD_POLL_ABORT | ntdllx.AFD_POLL_LOCAL_CLOSE)) != 0) {
                            std.debug.print("[Client-{d}] Disconnected by peer\n", .{id});
                            break;
                        }
                    }
                    std.debug.print("[Client-{d}] Finished\n", .{id});
                }
            }.run, .{ self.*.client_addr, i });
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
                // Real events are in the poll_info structure
                const events: u32 = ctx.poll_info.Handles[0].Events;

                if (events == 0) {
                    // Spurious wakeup (AFD timeout)
                    // Re-arm immediately with original mask
                    if (ctx == &listen_ctx) {
                        try ctx.*.arm(ntdllx.AFD_POLL_ACCEPT, ctx);
                    } else {
                        try ctx.*.arm(ntdllx.AFD_POLL_RECEIVE, ctx);
                    }
                    continue;
                }

                if (ctx == &listen_ctx) {
                    std.debug.print("[Stress-POC] Listen event: {X}\n", .{events});
                    while (true) {
                        const client_skt = ctx.skt.accept() catch |err| {
                            std.debug.print("[Stress-POC] Accept error: {any}\n", .{err});
                            break;
                        };

                        if (client_skt) |skt| {
                            std.debug.print("[Stress-POC] Accepted new client socket: {any}\n", .{skt.socket.?});
                            const s: *Skt = try self.*.allocator.create(Skt);
                            s.* = skt;
                            try self.*.skts.append(self.*.allocator, s);
                            _ = try self.*.poller.register(s);

                            const c: *poc.SocketContext = try self.*.allocator.create(poc.SocketContext);
                            c.* = poc.SocketContext.init(s);
                            try self.*.connections.append(self.*.allocator, c);
                            try c.*.arm(ntdllx.AFD_POLL_RECEIVE, c);
                            clients_accepted += 1;
                        } else {
                            break; // WouldBlock
                        }
                    }
                    try ctx.*.arm(ntdllx.AFD_POLL_ACCEPT, ctx);
                } else {
                    if ((events & (ntdllx.AFD_POLL_ABORT | ntdllx.AFD_POLL_LOCAL_CLOSE | ntdllx.AFD_POLL_CONNECT_FAIL)) != 0) {
                        std.debug.print("[Stress-POC] Client closed/error event: {X}\n", .{events});
                        continue;
                    }

                    var buf: [1024]u8 = undefined;
                    const bytes = ctx.skt.recv(&buf) catch |err| {
                        if (err != error.PeerDisconnected) {
                            std.debug.print("[Stress-POC] recv error: {any}\n", .{err});
                        } else {
                            std.debug.print("[Stress-POC] Peer disconnected\n", .{});
                        }
                        continue;
                    };

                    if (bytes > 0) {
                        std.debug.print("[Stress-POC] Received {d} bytes, sending pong...\n", .{bytes});
                        _ = ctx.skt.send(buf[0..bytes]) catch |err| {
                            std.debug.print("[Stress-POC] send error: {any}\n", .{err});
                        };
                        messages_handled += @divFloor(bytes, 4); // each "Ping" = 4 bytes
                        try ctx.*.arm(ntdllx.AFD_POLL_RECEIVE, ctx);
                    } else {
                        // WouldBlock (spurious)
                        std.debug.print("[Stress-POC] recv returned WouldBlock (0) despite event mask {X}\n", .{events});
                        try ctx.*.arm(ntdllx.AFD_POLL_RECEIVE, ctx);
                    }
                }
            }
        }

        for (client_threads) |t| t.join();
        std.debug.print("[Stress-POC] Finished. Handled {d} messages.\n", .{messages_handled});
    }
};

pub fn runStressTest(allocator: std.mem.Allocator, server_addr: address.Address, client_addr: address.Address) !void {
    var stage: Stage3Stress = try Stage3Stress.init(allocator, server_addr, client_addr);
    defer stage.deinit();
    try stage.run();
}

pub fn runTcpTest(allocator: std.mem.Allocator) !void {
    const port: u16 = try tofu.FindFreeTcpPort();
    const server_addr: address.Address = .{ .tcp_server_addr = address.TCPServerAddress.init("127.0.0.1", port) };
    const client_addr: address.Address = .{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", port) };
    try runStressTest(allocator, server_addr, client_addr);
}

pub fn runUdsTest(allocator: std.mem.Allocator) !void {
    var tup: tofu.TempUdsPath = .{};
    const filePath: []u8 = try tup.buildPath(allocator);
    const server_addr: address.Address = .{ .uds_server_addr = address.UDSServerAddress.init(filePath) };
    const client_addr: address.Address = .{ .uds_client_addr = address.UDSClientAddress.init(filePath) };
    try runStressTest(allocator, server_addr, client_addr);
}

pub fn runTest(allocator: std.mem.Allocator) !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    try runTcpTest(allocator);
    try runUdsTest(allocator);
}

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
