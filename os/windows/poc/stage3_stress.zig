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

pub const Stage3Stress = struct {
    iocp: windows.HANDLE,
    listen_socket: Skt,
    listen_port: u16,
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*CompletionContext),

    const Self = @This();

    pub const Error = error{
        IocpCreateFailed,
        GetBaseHandleFailed,
        IocpAssociateFailed,
        AfdPollFailed,
        PollCompletionFailed,
        NoCompletionEntry,
        AfdPollCompletionError,
        WSAStartupFailed,
        AcceptFailed,
        UnexpectedEvent,
        ReadFailed,
        WriteFailed,
        CancellationFailed,
        CancellationVerificationFailed,
    };

    const ContextType = enum {
        listener,
        connection,
        cancellation_test,
    };

    const CompletionContext = struct {
        type: ContextType,
        handle: windows.HANDLE,
        base_handle: windows.HANDLE,
        io_status: windows.IO_STATUS_BLOCK,
        poll_info: ntdllx.AFD_POLL_INFO,
        is_cancelled: bool = false,

        fn init(handle: windows.HANDLE, base_handle: windows.HANDLE, ctype: ContextType) CompletionContext {
            return .{
                .type = ctype,
                .handle = handle,
                .base_handle = base_handle,
                .io_status = undefined,
                .poll_info = undefined,
            };
        }

        fn arm(self: *CompletionContext, events: u32) !void {
            self.poll_info = .{
                .Timeout = 0, // Indefinite
                .NumberOfHandles = 1,
                .Exclusive = 0,
                .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                    .{ .Handle = self.base_handle, .Events = events, .Status = .SUCCESS },
                },
            };

            const status = ntdll.NtDeviceIoControlFile(
                self.base_handle,
                null,
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
                std.debug.print("NtDeviceIoControlFile failed: {any}\n", .{status});
                return error.AfdPollFailed;
            }
            // std.debug.print("AFD_POLL issued: status={any}\n", .{status});
        }
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = .{
            .iocp = undefined,
            .listen_socket = undefined,
            .listen_port = 23459,
            .allocator = allocator,
            .connections = std.ArrayList(*CompletionContext).empty,
        };

        const status_iocp = ntdllx.NtCreateIoCompletion(&self.iocp, windows.GENERIC_READ | windows.GENERIC_WRITE, null, 0);
        if (status_iocp != .SUCCESS) return error.IocpCreateFailed;

        const server_addr_cfg = address.TCPServerAddress.init("127.0.0.1", self.listen_port);
        const server_adrs = address.Address{ .tcp_server_addr = server_addr_cfg };

        var sc = SocketCreator.init(allocator);
        self.listen_socket = try sc.fromAddress(server_adrs);

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |ctx| {
            _ = ws2_32.closesocket(@ptrCast(ctx.handle));
            self.allocator.destroy(ctx);
        }
        self.connections.deinit(self.allocator);
        self.listen_socket.deinit();
        _ = windows.CloseHandle(self.iocp);
    }

    fn getBaseHandle(socket: ws2_32.SOCKET) !windows.HANDLE {
        var base_handle: windows.HANDLE = undefined;
        var bytes_returned: u32 = undefined;
        const ioctl_res = ws2_32.WSAIoctl(
            socket,
            ws2_32.SIO_BASE_HANDLE,
            null,
            0,
            @ptrCast(&base_handle),
            @sizeOf(windows.HANDLE),
            &bytes_returned,
            null,
            null,
        );
        if (ioctl_res != 0) return error.GetBaseHandleFailed;
        return base_handle;
    }

    pub fn run(self: *Self) !void {
        const listen_base_handle = try getBaseHandle(self.listen_socket.socket.?);
        _ = try windows.CreateIoCompletionPort(listen_base_handle, self.iocp, 0, 0);

        var listen_ctx = CompletionContext.init(self.listen_socket.socket.?, listen_base_handle, .listener);
        try listen_ctx.arm(ntdllx.AFD_POLL_ACCEPT);

        // 1. Cancellation Test
        std.debug.print("Stage 3: Testing Async Cancellation...\n", .{});
        var cancel_skt_val: Skt = undefined;
        {
            const addr_cfg = address.TCPServerAddress.init("127.0.0.1", 0);
            var sc = SocketCreator.init(self.allocator);
            cancel_skt_val = try sc.fromAddress(.{ .tcp_server_addr = addr_cfg });
        }
        defer cancel_skt_val.deinit();
        const cancel_base = try getBaseHandle(cancel_skt_val.socket.?);
        _ = try windows.CreateIoCompletionPort(cancel_base, self.iocp, 0, 0);

        var cancel_ctx = CompletionContext.init(cancel_skt_val.socket.?, cancel_base, .cancellation_test);
        try cancel_ctx.arm(ntdllx.AFD_POLL_ACCEPT);

        var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
        const cancel_status = ntdllx.NtCancelIoFile(cancel_base, &cancel_iosb);
        if (cancel_status != .SUCCESS) {
            std.debug.print("NtCancelIoFile failed: {any}\n", .{cancel_status});
            return error.CancellationFailed;
        }
        cancel_ctx.is_cancelled = true;

        // 2. Stress Test
        const num_clients = 20;
        std.debug.print("Stage 3: Starting Stress Test with {d} clients...\n", .{num_clients});
        var client_threads: [num_clients]std.Thread = undefined;
        for (0..num_clients) |i| {
            client_threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(port: u16) void {
                    var wsa_data: ws2_32.WSADATA = undefined;
                    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
                    defer _ = ws2_32.WSACleanup();

                    const client_addr_cfg = address.TCPClientAddress.init("127.0.0.1", port);
                    var sc = SocketCreator.init(std.heap.page_allocator);
                    var client_skt = sc.fromAddress(.{ .tcp_client_addr = client_addr_cfg }) catch return;
                    defer client_skt.deinit();

                    const server_addr_in: ws2_32.sockaddr.in = .{
                        .family = ws2_32.AF.INET,
                        .port = std.mem.nativeToBig(u16, port),
                        .addr = std.mem.nativeToBig(u32, 0x7f000001),
                        .zero = .{0} ** 8,
                    };
                    _ = ws2_32.connect(client_skt.socket.?, @ptrCast(&server_addr_in), @sizeOf(ws2_32.sockaddr.in));
                    
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    const msg = "Stress";
                    _ = ws2_32.send(client_skt.socket.?, msg, @intCast(msg.len), 0);
                    
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                }
            }.run, .{ self.listen_port });
        }

        var clients_finished: usize = 0;
        var cancellation_verified: bool = false;

        var entries: [16]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var removed: u32 = 0;
        var timeout: windows.LARGE_INTEGER = -10 * 10_000_000;

        while (clients_finished < num_clients or !cancellation_verified) {
            const status = ntdllx.NtRemoveIoCompletionEx(self.iocp, &entries, entries.len, &removed, &timeout, 0);
            if (status != .SUCCESS) return error.PollCompletionFailed;

            for (entries[0..removed]) |entry| {
                const ctx: *CompletionContext = @ptrCast(@alignCast(entry.ApcContext.?));

                if (ctx.type == .cancellation_test) {
                    if (entry.IoStatus.u.Status == ntdllx.STATUS_CANCELLED or entry.IoStatus.u.Status == .SUCCESS) {
                        std.debug.print("Cancellation verified: received status {any}.\n", .{entry.IoStatus.u.Status});
                        cancellation_verified = true;
                    } else {
                        std.debug.print("Cancellation test failed: received status {any}\n", .{entry.IoStatus.u.Status});
                        return error.CancellationVerificationFailed;
                    }
                } else if (ctx.type == .listener) {
                    if ((ctx.poll_info.Handles[0].Events & ntdllx.AFD_POLL_ACCEPT) != 0) {
                        var addr: ws2_32.sockaddr = undefined;
                        var addr_len: i32 = @sizeOf(ws2_32.sockaddr);
                        const client_sock = ws2_32.accept(@ptrCast(ctx.handle), &addr, &addr_len);
                        try ctx.arm(ntdllx.AFD_POLL_ACCEPT);

                        if (client_sock != ws2_32.INVALID_SOCKET) {
                            const client_base = try getBaseHandle(client_sock);
                            _ = try windows.CreateIoCompletionPort(client_base, self.iocp, 0, 0);

                            const new_conn = try self.allocator.create(CompletionContext);
                            new_conn.* = CompletionContext.init(@ptrCast(client_sock), client_base, .connection);
                            try self.connections.append(self.allocator, new_conn);
                            try new_conn.arm(ntdllx.AFD_POLL_RECEIVE);
                        }
                    }
                } else if (ctx.type == .connection) {
                    const events = ctx.poll_info.Handles[0].Events;
                    if ((events & ntdllx.AFD_POLL_RECEIVE) != 0) {
                        var buf: [1024]u8 = undefined;
                        const bytes = ws2_32.recv(@ptrCast(ctx.handle), &buf, buf.len, 0);
                        
                        if (bytes == ws2_32.SOCKET_ERROR) {
                            const err = ws2_32.WSAGetLastError();
                            if (err == .WSAEWOULDBLOCK) {
                                try ctx.arm(ntdllx.AFD_POLL_RECEIVE);
                                continue;
                            }
                            if (err == .WSAECONNRESET or err == .WSAECONNABORTED) {
                                clients_finished += 1;
                                std.debug.print("Client {d}/{d} finished (reset).\n", .{clients_finished, num_clients});
                            }
                        } else if (bytes == 0) {
                            clients_finished += 1;
                            std.debug.print("Client {d}/{d} finished (graceful).\n", .{clients_finished, num_clients});
                        } else {
                            try ctx.arm(ntdllx.AFD_POLL_RECEIVE);
                        }
                    }
                }
            }
        }

        for (client_threads) |t| t.join();
        std.debug.print("Stage 3 Stress & Cancellation successful.\n", .{});
    }
};

pub fn runTest() !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    const rc = ws2_32.WSAStartup(0x0202, &wsa_data);
    if (rc != 0) return error.WSAStartupFailed;
    defer _ = ws2_32.WSACleanup();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stage = try Stage3Stress.init(allocator);
    defer stage.deinit();

    try stage.run();
}
