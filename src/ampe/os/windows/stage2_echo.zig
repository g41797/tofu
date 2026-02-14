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

pub const Stage2Echo = struct {
    iocp: windows.HANDLE,
    listen_socket: Skt,
    listen_port: u16,
    allocator: std.mem.Allocator,

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
    };

    const ContextType = enum {
        listener,
        connection,
    };

    const CompletionContext = struct {
        type: ContextType,
        handle: windows.HANDLE,
        base_handle: windows.HANDLE,
        io_status: windows.IO_STATUS_BLOCK,
        poll_info: ntdllx.AFD_POLL_INFO,

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
        }
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = .{
            .iocp = undefined,
            .listen_socket = undefined,
            .listen_port = 23458,
            .allocator = allocator,
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
        self.listen_socket.deinit();
        windows.CloseHandle(self.iocp);
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

        // Start client thread
        const client_thread = try std.Thread.spawn(.{}, struct {
            fn run(port: u16) void {
                std.debug.print("Client thread starting, connecting to port {d}...\n", .{port});
                var wsa_data: ws2_32.WSADATA = undefined;
                const rc = ws2_32.WSAStartup(0x0202, &wsa_data);
                if (rc != 0) return;
                defer _ = ws2_32.WSACleanup();

                const client_addr_cfg = address.TCPClientAddress.init("127.0.0.1", port);
                const client_adrs = address.Address{ .tcp_client_addr = client_addr_cfg };
                var sc = SocketCreator.init(std.heap.page_allocator);
                var client_skt = sc.fromAddress(client_adrs) catch |err| {
                    std.debug.print("Client: sc.fromAddress failed: {any}\n", .{err});
                    return;
                };
                defer client_skt.deinit();

                const server_addr_in: ws2_32.sockaddr.in = .{
                    .family = ws2_32.AF.INET,
                    .port = std.mem.nativeToBig(u16, port),
                    .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
                    .zero = .{0} ** 8,
                };
                var generic_server_addr: ws2_32.sockaddr = undefined;
                @memcpy(std.mem.asBytes(&generic_server_addr), std.mem.asBytes(&server_addr_in));

                const connect_res = ws2_32.connect(client_skt.socket.?, &generic_server_addr, @sizeOf(ws2_32.sockaddr.in));
                if (connect_res != 0) {
                    const err = ws2_32.WSAGetLastError();
                    if (err != .WSAEWOULDBLOCK) {
                        std.debug.print("Client: connect failed with error: {any}\n", .{err});
                        return;
                    }
                }

                // Give it a bit of time to connect
                std.Thread.sleep(100 * std.time.ns_per_ms);

                std.debug.print("Client: sending message...\n", .{});
                const msg = "Tofu Echo Test";
                const sent = ws2_32.send(client_skt.socket.?, msg, @intCast(msg.len), 0);
                if (sent == ws2_32.SOCKET_ERROR) {
                    std.debug.print("Client: send failed: {any}\n", .{ws2_32.WSAGetLastError()});
                    return;
                }

                std.debug.print("Client: waiting for echo...\n", .{});
                var buf: [1024]u8 = undefined;
                while (true) {
                    const recv_len = ws2_32.recv(client_skt.socket.?, &buf, buf.len, 0);
                    if (recv_len > 0) {
                        std.debug.print("Client received echo: {s}\n", .{buf[0..@intCast(recv_len)]});
                        break;
                    } else if (recv_len == 0) {
                        std.debug.print("Client: server closed connection.\n", .{});
                        break;
                    } else {
                        const err = ws2_32.WSAGetLastError();
                        if (err == .WSAEWOULDBLOCK) {
                            std.Thread.sleep(10 * std.time.ns_per_ms);
                            continue;
                        }
                        std.debug.print("Client: recv failed: {any}\n", .{err});
                        break;
                    }
                }
            }
        }.run, .{self.listen_port});
        defer client_thread.join();

        var conn_ctx: ?*CompletionContext = null;
        defer if (conn_ctx) |ctx| self.allocator.destroy(ctx);

        var entries: [4]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var removed: u32 = 0;
        var timeout: windows.LARGE_INTEGER = -10 * 10_000_000; // 10s

        while (true) {
            const status = ntdllx.NtRemoveIoCompletionEx(self.iocp, &entries, entries.len, &removed, &timeout, 0);
            if (status != .SUCCESS) return error.PollCompletionFailed;

            for (entries[0..removed]) |entry| {
                const ctx: *CompletionContext = @ptrCast(@alignCast(entry.ApcContext.?));

                if (ctx.type == .listener) {
                    if ((ctx.poll_info.Handles[0].Events & ntdllx.AFD_POLL_ACCEPT) != 0) {
                        var addr: ws2_32.sockaddr = undefined;
                        var addr_len: i32 = @sizeOf(ws2_32.sockaddr);
                        const client_sock = ws2_32.accept(@ptrCast(ctx.handle), &addr, &addr_len);
                        
                        // Re-arm after accept
                        try ctx.arm(ntdllx.AFD_POLL_ACCEPT);

                        if (client_sock == ws2_32.INVALID_SOCKET) {
                            if (ws2_32.WSAGetLastError() == .WSAEWOULDBLOCK) continue;
                            return error.AcceptFailed;
                        }

                        const client_base = try getBaseHandle(client_sock);
                        _ = try windows.CreateIoCompletionPort(client_base, self.iocp, 0, 0);

                        conn_ctx = try self.allocator.create(CompletionContext);
                        conn_ctx.?.* = CompletionContext.init(@ptrCast(client_sock), client_base, .connection);
                        try conn_ctx.?.arm(ntdllx.AFD_POLL_RECEIVE);
                        std.debug.print("Server accepted connection and armed RECEIVE.\n", .{});
                    }
                } else if (ctx.type == .connection) {
                    const events = ctx.poll_info.Handles[0].Events;
                    if ((events & ntdllx.AFD_POLL_RECEIVE) != 0) {
                        var buf: [1024]u8 = undefined;
                        const bytes = ws2_32.recv(@ptrCast(ctx.handle), &buf, buf.len, 0);
                        
                        // Re-arm after recv
                        try ctx.arm(ntdllx.AFD_POLL_RECEIVE);

                        if (bytes == ws2_32.SOCKET_ERROR) {
                            const err = ws2_32.WSAGetLastError();
                            if (err == .WSAEWOULDBLOCK) continue;
                            if (err == .WSAECONNRESET or err == .WSAECONNABORTED) {
                                std.debug.print("Server: connection closed by client ({any}).\n", .{err});
                                return;
                            }
                            std.debug.print("Server: recv failed with error: {any}\n", .{err});
                            return error.ReadFailed;
                        }
                        if (bytes == 0) {
                            std.debug.print("Server: connection closed by client.\n", .{});
                            return; // Test complete
                        }

                        std.debug.print("Server received: {s}, echoing back...\n", .{buf[0..@intCast(bytes)]});

                        const sent = ws2_32.send(@ptrCast(ctx.handle), &buf, @intCast(bytes), 0);
                        if (sent == ws2_32.SOCKET_ERROR) {
                            std.debug.print("Server: send failed with error: {any}\n", .{ws2_32.WSAGetLastError()});
                            return error.WriteFailed;
                        }
                    }
                }
            }
        }
    }
};

pub fn runTest() !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    const wsa_startup_res = ws2_32.WSAStartup(0x0202, &wsa_data);
    if (wsa_startup_res != 0) return error.WSAStartupFailed;
    defer _ = ws2_32.WSACleanup();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stage = try Stage2Echo.init(allocator);
    defer stage.deinit();

    try stage.run();
}
