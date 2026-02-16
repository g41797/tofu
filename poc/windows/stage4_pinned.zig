// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

//! Stage 4 POC: Validates the PinnedState indirection pattern.
//!
//! Instead of passing a pointer to a movable struct as ApcContext,
//! we pass a ChannelNumber (u16 cast to usize/PVOID). On completion,
//! cast back to u16 and look up the stable, heap-allocated PinnedState.
//! This proves that HashMap growth and swapRemove cannot cause
//! use-after-free because the kernel only holds:
//!   - A stable *PinnedState (heap-allocated, never moves)
//!   - An integer ID as ApcContext (not a pointer to movable memory)

pub const PinnedState = struct {
    io_status: windows.IO_STATUS_BLOCK = undefined,
    poll_info: ntdllx.AFD_POLL_INFO = undefined,
    is_pending: bool = false,
    expected_events: u32 = 0,
};

pub const Stage4Pinned = struct {
    poller: afd.AfdPoller,
    listen_socket: Skt,
    client_addr: address.Address,
    allocator: std.mem.Allocator,
    pinned_states: std.AutoArrayHashMap(u16, *PinnedState),
    skts: std.AutoArrayHashMap(u16, *Skt),
    next_id: u16 = 1,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, server_addr: address.Address, client_addr: address.Address) !Self {
        var self: Self = .{
            .poller = try afd.AfdPoller.init(allocator),
            .listen_socket = undefined,
            .client_addr = client_addr,
            .allocator = allocator,
            .pinned_states = std.AutoArrayHashMap(u16, *PinnedState).init(allocator),
            .skts = std.AutoArrayHashMap(u16, *Skt).init(allocator),
        };

        var sc: SocketCreator = SocketCreator.init(allocator);
        self.listen_socket = try sc.fromAddress(server_addr);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.*.listen_socket.deinit();
        for (self.*.pinned_states.values()) |ps| {
            self.*.allocator.destroy(ps);
        }
        self.*.pinned_states.deinit();
        for (self.*.skts.values()) |s| {
            s.*.deinit();
            self.*.allocator.destroy(s);
        }
        self.*.skts.deinit();
        self.*.poller.deinit();
    }

    fn allocId(self: *Self) u16 {
        const id: u16 = self.*.next_id;
        self.*.next_id += 1;
        return id;
    }

    fn armSkt(self: *Self, skt: *Skt, events: u32, id: u16) !void {
        const gop = try self.*.pinned_states.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = try self.*.allocator.create(PinnedState);
            gop.value_ptr.*.* = PinnedState{};
        }
        const state: *PinnedState = gop.value_ptr.*;

        state.*.poll_info = ntdllx.AFD_POLL_INFO{
            .Timeout = @as(windows.LARGE_INTEGER, @bitCast(@as(u64, 0x7FFFFFFFFFFFFFFF))),
            .NumberOfHandles = 1,
            .Exclusive = 0,
            .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                .{ .Handle = skt.*.base_handle, .Events = events, .Status = .SUCCESS },
            },
        };

        const status: ntdllx.NTSTATUS = windows.ntdll.NtDeviceIoControlFile(
            skt.*.base_handle,
            null,
            null,
            @ptrFromInt(@as(usize, id)),
            &state.*.io_status,
            ntdllx.IOCTL_AFD_POLL,
            &state.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
            &state.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
        );

        if (status != .SUCCESS and status != .PENDING) {
            return error.AfdPollFailed;
        }
        state.*.is_pending = true;
        state.*.expected_events = events;
    }

    pub fn run(self: *Self) !void {
        _ = try self.*.poller.register(&self.*.listen_socket);

        const LISTEN_ID: u16 = self.*.allocId();
        try self.*.armSkt(&self.*.listen_socket, ntdllx.AFD_POLL_ACCEPT, LISTEN_ID);

        const NUM_CLIENTS: usize = 5;
        const MESSAGES_PER_CLIENT: usize = 10;
        const TARGET_MESSAGES: usize = NUM_CLIENTS * MESSAGES_PER_CLIENT;

        std.debug.print("[Stage4-Pinned] Starting {d} clients, target messages: {d}\n", .{ NUM_CLIENTS, TARGET_MESSAGES });

        var client_threads: [NUM_CLIENTS]std.Thread = undefined;
        for (0..NUM_CLIENTS) |i| {
            client_threads[i] = try std.Thread.spawn(.{}, struct {
                fn run_client(client_addr: address.Address, id: usize) void {
                    const alloc = std.heap.page_allocator;

                    var local_poller: afd.AfdPoller = afd.AfdPoller.init(alloc) catch {
                        std.debug.print("[Client-{d}] Poller init failed\n", .{id});
                        return;
                    };
                    defer local_poller.deinit();

                    var sc: SocketCreator = SocketCreator.init(alloc);
                    const client_skt_val: Skt = sc.fromAddress(client_addr) catch {
                        std.debug.print("[Client-{d}] Creation failed\n", .{id});
                        return;
                    };
                    const client_skt: *Skt = alloc.create(Skt) catch return;
                    client_skt.* = client_skt_val;
                    defer {
                        client_skt.*.deinit();
                        alloc.destroy(client_skt);
                    }

                    _ = local_poller.register(client_skt) catch {
                        std.debug.print("[Client-{d}] Register failed\n", .{id});
                        return;
                    };

                    var ctx: poc.SocketContext = poc.SocketContext.init(client_skt);

                    if (client_skt.*.connect() catch |err| {
                        std.debug.print("[Client-{d}] Connect error: {any}\n", .{ id, err });
                        return;
                    }) {
                        // connected immediately
                    } else {
                        var entries: [1]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
                        while (true) {
                            ctx.arm(ntdllx.AFD_POLL_CONNECT, &ctx) catch return;
                            _ = local_poller.poll(5000, &entries) catch return;
                            if (ctx.poll_info.Handles[0].Events == 0) continue;
                            if (client_skt.*.connect() catch return) break;
                        }
                    }

                    var pings_sent: usize = 0;
                    var pongs_recvd: usize = 0;
                    const TOTAL_PINGS: usize = 10;
                    var entries: [1]ntdllx.FILE_COMPLETION_INFORMATION = undefined;

                    while (pongs_recvd < TOTAL_PINGS) {
                        var interest: u32 = ntdllx.AFD_POLL_RECEIVE;
                        if (pings_sent < TOTAL_PINGS and pings_sent == pongs_recvd) {
                            interest |= ntdllx.AFD_POLL_SEND;
                        }

                        ctx.arm(interest, &ctx) catch break;
                        const removed: u32 = local_poller.poll(5000, &entries) catch break;
                        if (removed == 0) continue;

                        const events: u32 = ctx.poll_info.Handles[0].Events;
                        if (events == 0) continue;

                        if ((events & ntdllx.AFD_POLL_SEND) != 0) {
                            if (pings_sent < TOTAL_PINGS and pings_sent == pongs_recvd) {
                                _ = client_skt.*.send("Ping") catch break;
                                pings_sent += 1;
                            }
                        }

                        if ((events & ntdllx.AFD_POLL_RECEIVE) != 0) {
                            var buf: [16]u8 = undefined;
                            const bytes: usize = client_skt.*.recv(&buf) catch |err| {
                                if (err == error.WouldBlock) continue;
                                break;
                            };
                            if (bytes > 0) pongs_recvd += 1;
                        }

                        if ((events & (ntdllx.AFD_POLL_ABORT | ntdllx.AFD_POLL_LOCAL_CLOSE)) != 0) break;
                    }
                    std.debug.print("[Client-{d}] Finished ({d} pongs)\n", .{ id, pongs_recvd });
                }
            }.run_client, .{ self.*.client_addr, i });
        }

        var entries: [32]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var messages_handled: usize = 0;
        var clients_accepted: usize = 0;
        var consecutive_idle_timeouts: usize = 0;
        var last_handled: usize = 0;

        while (messages_handled < TARGET_MESSAGES) {
            const removed: u32 = try self.*.poller.poll(5000, &entries);
            if (removed == 0) {
                if (messages_handled == last_handled) {
                    consecutive_idle_timeouts += 1;
                } else {
                    consecutive_idle_timeouts = 0;
                    last_handled = messages_handled;
                }
                if (clients_accepted == NUM_CLIENTS and consecutive_idle_timeouts >= 3) {
                    std.debug.print("[Stage4-Pinned] Stalled after {d} messages, exiting.\n", .{messages_handled});
                    break;
                }
                continue;
            }

            for (entries[0..removed]) |entry| {
                if (entry.ApcContext == null) continue;

                // KEY PATTERN: Cast ApcContext back to ID, then look up PinnedState
                const id: u16 = @intCast(@intFromPtr(entry.ApcContext.?));
                const state: *PinnedState = self.*.pinned_states.get(id) orelse continue;
                state.*.is_pending = false;

                const events: u32 = state.*.poll_info.Handles[0].Events;

                if (id == LISTEN_ID) {
                    if (events == 0) {
                        try self.*.armSkt(&self.*.listen_socket, ntdllx.AFD_POLL_ACCEPT, LISTEN_ID);
                        continue;
                    }

                    while (true) {
                        const client_skt_opt: ?Skt = self.*.listen_socket.accept() catch break;
                        if (client_skt_opt) |skt_val| {
                            const s: *Skt = try self.*.allocator.create(Skt);
                            s.* = skt_val;
                            const conn_id: u16 = self.*.allocId();
                            try self.*.skts.put(conn_id, s);
                            _ = try self.*.poller.register(s);
                            try self.*.armSkt(s, ntdllx.AFD_POLL_RECEIVE, conn_id);
                            clients_accepted += 1;
                            std.debug.print("[Stage4-Pinned] Accepted client, id={d}\n", .{conn_id});
                        } else {
                            break;
                        }
                    }
                    try self.*.armSkt(&self.*.listen_socket, ntdllx.AFD_POLL_ACCEPT, LISTEN_ID);
                } else {
                    if (entry.IoStatus.u.Status != .SUCCESS) continue;

                    if ((events & (ntdllx.AFD_POLL_ABORT | ntdllx.AFD_POLL_LOCAL_CLOSE | ntdllx.AFD_POLL_CONNECT_FAIL)) != 0) {
                        continue;
                    }

                    const skt: *Skt = self.*.skts.get(id) orelse continue;

                    var buf: [1024]u8 = undefined;
                    const bytes: usize = skt.*.recv(&buf) catch |err| {
                        if (err != error.PeerDisconnected) {
                            std.debug.print("[Stage4-Pinned] recv error: {any}\n", .{err});
                        }
                        continue;
                    };

                    if (bytes > 0) {
                        _ = skt.*.send(buf[0..bytes]) catch |err| {
                            std.debug.print("[Stage4-Pinned] send error: {any}\n", .{err});
                        };
                        messages_handled += @divFloor(bytes, 4);
                        try self.*.armSkt(skt, ntdllx.AFD_POLL_RECEIVE, id);
                    } else {
                        try self.*.armSkt(skt, ntdllx.AFD_POLL_RECEIVE, id);
                    }
                }
            }
        }

        for (client_threads) |t| t.join();
        std.debug.print("[Stage4-Pinned] Finished. Handled {d} messages, {d} pinned states.\n", .{ messages_handled, self.*.pinned_states.count() });
    }
};

pub fn runTest(allocator: std.mem.Allocator) !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    const port: u16 = try tofu.FindFreeTcpPort();
    const server_addr: address.Address = .{ .tcp_server_addr = address.TCPServerAddress.init("127.0.0.1", port) };
    const client_addr: address.Address = .{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", port) };

    var stage: Stage4Pinned = try Stage4Pinned.init(allocator, server_addr, client_addr);
    defer stage.deinit();
    try stage.run();
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
