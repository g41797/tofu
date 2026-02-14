// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const windows = std.os.windows;
const ntdll = windows.ntdll;
const ws2_32 = windows.ws2_32;
const ntdllx = @import("ntdllx.zig");
const Skt = @import("tofu").Skt;
const SocketCreator = @import("tofu").SocketCreator;
const address = @import("tofu").address;

pub const Stage1UUds = struct {
    iocp: windows.HANDLE,
    listen_socket: Skt,
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*CompletionContext),

    const Self = @This();

    pub const Error = error{
        IocpCreateFailed,
        EventCreateFailed,
        GetBaseHandleFailed,
        IocpAssociateFailed,
        EventWaitFailed,
        AfdPollFailed,
        PollCompletionFailed,
        NoCompletionEntry,
        AfdPollCompletionError,
        AfdPollAcceptNotSet,
        WSAStartupFailed,
        AcceptFailed,
        ReadFailed,
        WriteFailed,
    };

    const ContextType = enum {
        listener,
        connection,
    };

    const CompletionContext = struct {
        type: ContextType,
        handle: windows.HANDLE,
        base_handle: windows.HANDLE,
        event: windows.HANDLE,
        io_status: windows.IO_STATUS_BLOCK,
        poll_info: ntdllx.AFD_POLL_INFO,
        name: []const u8,

        fn init(handle: windows.HANDLE, base_handle: windows.HANDLE, ctype: ContextType, name: []const u8) !*CompletionContext {
            const allocator = std.heap.page_allocator;
            const self = try allocator.create(CompletionContext);
            self.* = .{
                .type = ctype,
                .handle = handle,
                .base_handle = base_handle,
                .event = ntdllx.CreateEventA(null, windows.TRUE, windows.FALSE, null),
                .io_status = undefined,
                .poll_info = undefined,
                .name = name,
            };
            if (self.event == windows.INVALID_HANDLE_VALUE) return error.EventCreateFailed;
            return self;
        }

        fn deinit(self: *CompletionContext) void {
            windows.CloseHandle(self.event);
            std.heap.page_allocator.destroy(self);
        }

        fn arm(self: *CompletionContext, events: u32, iocp: windows.HANDLE) !void {
            _ = iocp;
            self.poll_info = .{
                .Timeout = -1,
                .NumberOfHandles = 1,
                .Exclusive = 0,
                .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                    .{ .Handle = self.base_handle, .Events = events, .Status = .SUCCESS },
                },
            };

            _ = ntdllx.ResetEvent(self.event); 

            const status = ntdll.NtDeviceIoControlFile(
                self.base_handle,
                self.event,
                null,
                self, 
                &self.io_status,
                ntdllx.IOCTL_AFD_POLL,
                &self.poll_info,
                @sizeOf(ntdllx.AFD_POLL_INFO),
                &self.poll_info,
                @sizeOf(ntdllx.AFD_POLL_INFO),
            );

            if (status != .SUCCESS and status != .PENDING) {
                return error.AfdPollFailed;
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = .{
            .iocp = undefined,
            .listen_socket = undefined,
            .allocator = allocator,
            .connections = std.ArrayList(*CompletionContext).empty,
        };

        const status_iocp = ntdllx.NtCreateIoCompletion(&self.iocp, windows.GENERIC_READ | windows.GENERIC_WRITE, null, 0);
        if (status_iocp != .SUCCESS) return error.IocpCreateFailed;

        const server_adrs: address.Address = .{ .uds_server_addr = address.UDSServerAddress.init("") };
        var sc = SocketCreator.init(allocator);
        self.listen_socket = try sc.fromAddress(server_adrs);

        // Associate listener once
        const listen_base = try getBaseHandle(self.listen_socket.socket.?);
        _ = try windows.CreateIoCompletionPort(listen_base, self.iocp, 0, 0);

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |ctx| {
            _ = ws2_32.closesocket(@ptrCast(ctx.handle));
            ctx.deinit();
        }
        self.connections.deinit(self.allocator);
        self.listen_socket.deinit();
        windows.CloseHandle(self.iocp);
    }

    fn getBaseHandle(socket: ws2_32.SOCKET) !windows.HANDLE {
        var base_handle: windows.HANDLE = undefined;
        var bytes_returned: u32 = undefined;
        const ioctl_res = ws2_32.WSAIoctl(
            socket,
            ws2_32.SIO_BASE_HANDLE,
            null, 0,
            @ptrCast(&base_handle),
            @sizeOf(windows.HANDLE),
            &bytes_returned,
            null, null,
        );
        if (ioctl_res != 0) return error.GetBaseHandleFailed;
        return base_handle;
    }

    pub fn runEchoTest(self: *Self) !void {
        std.debug.print("[UDS-POC] Starting UDS Echo Test...\n", .{});
        const listen_base = try getBaseHandle(self.listen_socket.socket.?);
        const listen_ctx = try CompletionContext.init(self.listen_socket.socket.?, listen_base, .listener, "EchoListener");
        defer listen_ctx.deinit();
        try listen_ctx.arm(ntdllx.AFD_POLL_ACCEPT, self.iocp);

        const client_thread = try std.Thread.spawn(.{}, struct {
            fn run(path_arr: [108]u8) void {
                const path = std.mem.sliceTo(&path_arr, 0);
                var wsa_data: ws2_32.WSADATA = undefined;
                _ = ws2_32.WSAStartup(0x0202, &wsa_data);
                defer _ = ws2_32.WSACleanup();

                var sc = SocketCreator.init(std.heap.page_allocator);
                var client_skt = sc.fromAddress(.{ .uds_client_addr = address.UDSClientAddress.init(path) }) catch return;
                defer client_skt.deinit();

                var addr = std.net.Address.initUnix(path) catch unreachable;
                _ = ws2_32.connect(client_skt.socket.?, &addr.any, @intCast(2 + path.len + 1));
                
                std.Thread.sleep(50 * std.time.ns_per_ms);
                _ = ws2_32.send(client_skt.socket.?, "Tofu UDS Echo", 13, 0);

                var buf: [1024]u8 = undefined;
                _ = ws2_32.recv(client_skt.socket.?, &buf, buf.len, 0);
            }
        }.run, .{self.listen_socket.address.un.path});
        defer client_thread.join();

        var entries: [4]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var removed: u32 = 0;
        var timeout: windows.LARGE_INTEGER = -5 * 10_000_000;

        var echo_done = false;
        while (!echo_done) {
            const status = ntdllx.NtRemoveIoCompletionEx(self.iocp, &entries, entries.len, &removed, &timeout, 0);
            if (status != .SUCCESS) return error.PollCompletionFailed;

            for (entries[0..removed]) |entry| {
                const ctx: *CompletionContext = @ptrCast(@alignCast(entry.ApcContext.?));
                if (ctx.type == .listener) {
                    var addr: ws2_32.sockaddr = undefined;
                    var addr_len: i32 = @sizeOf(ws2_32.sockaddr);
                    const client_sock = ws2_32.accept(@ptrCast(ctx.handle), &addr, &addr_len);
                    try ctx.arm(ntdllx.AFD_POLL_ACCEPT, self.iocp);

                    if (client_sock != ws2_32.INVALID_SOCKET) {
                        const client_base = try getBaseHandle(client_sock);
                        _ = try windows.CreateIoCompletionPort(client_base, self.iocp, 0, 0);
                        const conn = try CompletionContext.init(@ptrCast(client_sock), client_base, .connection, "EchoConn");
                        try self.connections.append(self.allocator, conn);
                        try conn.arm(ntdllx.AFD_POLL_RECEIVE, self.iocp);
                    }
                } else if (ctx.type == .connection) {
                    var buf: [1024]u8 = undefined;
                    const bytes = ws2_32.recv(@ptrCast(ctx.handle), &buf, buf.len, 0);
                    if (bytes > 0) {
                        _ = ws2_32.send(@ptrCast(ctx.handle), &buf, @intCast(bytes), 0);
                        echo_done = true;
                    } else if (bytes == ws2_32.SOCKET_ERROR and ws2_32.WSAGetLastError() == .WSAEWOULDBLOCK) {
                        try ctx.arm(ntdllx.AFD_POLL_RECEIVE, self.iocp);
                    } else {
                        echo_done = true;
                    }
                }
            }
        }
        std.debug.print("[UDS-POC] Echo Test successful.\n", .{});
    }

    pub fn runStressTest(self: *Self) !void {
        const num_clients = 20;
        std.debug.print("[UDS-POC] Starting UDS Stress Test ({d} clients)...\n", .{num_clients});
        
        const listen_base = try getBaseHandle(self.listen_socket.socket.?);
        const listen_ctx = try CompletionContext.init(self.listen_socket.socket.?, listen_base, .listener, "StressListener");
        defer listen_ctx.deinit();
        try listen_ctx.arm(ntdllx.AFD_POLL_ACCEPT, self.iocp);

        var client_threads: [num_clients]std.Thread = undefined;
        for (0..num_clients) |i| {
            client_threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(path_arr: [108]u8) void {
                    const path = std.mem.sliceTo(&path_arr, 0);
                    var wsa_data: ws2_32.WSADATA = undefined;
                    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
                    defer _ = ws2_32.WSACleanup();

                    var sc = SocketCreator.init(std.heap.page_allocator);
                    var client_skt = sc.fromAddress(.{ .uds_client_addr = address.UDSClientAddress.init(path) }) catch return;
                    defer client_skt.deinit();

                    var addr = std.net.Address.initUnix(path) catch unreachable;
                    _ = ws2_32.connect(client_skt.socket.?, &addr.any, @intCast(2 + path.len + 1));
                    
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    _ = ws2_32.send(client_skt.socket.?, "Stress", 6, 0);
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                }
            }.run, .{self.listen_socket.address.un.path});
        }

        var clients_finished: usize = 0;
        var entries: [16]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var removed: u32 = 0;
        var timeout: windows.LARGE_INTEGER = -10 * 10_000_000;

        while (clients_finished < num_clients) {
            const status = ntdllx.NtRemoveIoCompletionEx(self.iocp, &entries, entries.len, &removed, &timeout, 0);
            if (status != .SUCCESS) return error.PollCompletionFailed;

            for (entries[0..removed]) |entry| {
                const ctx: *CompletionContext = @ptrCast(@alignCast(entry.ApcContext.?));
                if (ctx.type == .listener) {
                    var addr: ws2_32.sockaddr = undefined;
                    var addr_len: i32 = @sizeOf(ws2_32.sockaddr);
                    const client_sock = ws2_32.accept(@ptrCast(ctx.handle), &addr, &addr_len);
                    try ctx.arm(ntdllx.AFD_POLL_ACCEPT, self.iocp);

                    if (client_sock != ws2_32.INVALID_SOCKET) {
                        const client_base = try getBaseHandle(client_sock);
                        _ = try windows.CreateIoCompletionPort(client_base, self.iocp, 0, 0);
                        const conn = try CompletionContext.init(@ptrCast(client_sock), client_base, .connection, "StressConn");
                        try self.connections.append(self.allocator, conn);
                        try conn.arm(ntdllx.AFD_POLL_RECEIVE, self.iocp);
                    }
                } else if (ctx.type == .connection) {
                    var buf: [1024]u8 = undefined;
                    const bytes = ws2_32.recv(@ptrCast(ctx.handle), &buf, buf.len, 0);
                    if (bytes == ws2_32.SOCKET_ERROR) {
                        const err = ws2_32.WSAGetLastError();
                        if (err == .WSAEWOULDBLOCK) {
                            try ctx.arm(ntdllx.AFD_POLL_RECEIVE, self.iocp);
                        } else {
                            clients_finished += 1;
                        }
                    } else if (bytes == 0) {
                        clients_finished += 1;
                    } else {
                        try ctx.arm(ntdllx.AFD_POLL_RECEIVE, self.iocp);
                    }
                }
            }
        }

        for (client_threads) |t| t.join();
        std.debug.print("[UDS-POC] Stress Test successful.\n", .{});
    }
};

pub fn runTest() !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    if (ws2_32.WSAStartup(0x0202, &wsa_data) != 0) return error.WSAStartupFailed;
    defer _ = ws2_32.WSACleanup();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stage = try Stage1UUds.init(allocator);
    defer stage.deinit();

    try stage.runEchoTest();
    try stage.runStressTest();
    std.debug.print("Stage 1U (UDS Full) successful.\n", .{});
}
