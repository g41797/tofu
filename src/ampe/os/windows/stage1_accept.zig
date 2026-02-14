// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const windows = std.os.windows;
const ntdll = windows.ntdll;
const ws2_32 = windows.ws2_32;
const ntdllx = @import("ntdllx.zig");
const Skt = @import("tofu").Skt; // Import Skt from tofu module
const SocketCreator = @import("tofu").SocketCreator; // Import SocketCreator from tofu module
const address = @import("tofu").address; // Import address module

pub const Stage1Accept = struct {
    iocp: windows.HANDLE,
    listen_socket: Skt, // Changed from ws2_32.SOCKET
    listen_port: u16,
    event_handle: windows.HANDLE, // New event handle for AFD_POLL testing

    const Self = @This();

    pub const Error = error{
        IocpCreateFailed,
        EventCreateFailed, // New error
        GetBaseHandleFailed,
        IocpAssociateFailed, // New error
        EventWaitFailed, // New error
        AfdPollFailed,
        PollCompletionFailed,
        NoCompletionEntry,
        AfdPollCompletionError,
        AfdPollAcceptNotSet,
        WSAStartupFailed, // from runTest
    };

    pub fn init() !Self {
        var self: Self = .{
            .iocp = undefined,
            .listen_socket = undefined,
            .listen_port = 23456, // Default port
            .event_handle = undefined,
        };

        // 1. Create IOCP
        const status_iocp: ntdllx.NTSTATUS = ntdllx.NtCreateIoCompletion(&self.iocp, windows.GENERIC_READ | windows.GENERIC_WRITE, null, 0);
        if (status_iocp != .SUCCESS) {
            return error.IocpCreateFailed;
        }

        // 1.5. Create Event for AFD_POLL completion
        self.event_handle = ntdllx.CreateEventA(null, windows.TRUE, windows.FALSE, null); // Manual reset, initially unsignaled
        if (self.event_handle == windows.INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.iocp);
            return error.EventCreateFailed; // Need to define this error
        }

        // 2. Create Listener Socket using SocketCreator.fromAddress
        const server_addr_cfg = address.TCPServerAddress.init("127.0.0.1", self.listen_port);
        const server_adrs: address.Address = .{ .tcp_server_addr = server_addr_cfg };

        var sc = SocketCreator.init(std.heap.page_allocator);
        self.listen_socket = sc.fromAddress(server_adrs) catch unreachable;

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.listen_socket.deinit();
        windows.CloseHandle(self.iocp);
        windows.CloseHandle(self.event_handle); // Close event handle
    }

    pub fn runAcceptTest(self: *Self) !void {
        // - Get base handle
        var base_socket_handle: windows.HANDLE = undefined;
        var bytes_returned: u32 = undefined;
        const ioctl_res: i32 = ws2_32.WSAIoctl(
            self.listen_socket.socket.?,
            ws2_32.SIO_BASE_HANDLE,
            null, 0,
            @ptrCast(&base_socket_handle), // Fix: cast **HANDLE to *anyopaque
            @sizeOf(windows.HANDLE),
            &bytes_returned,
            null, null,
        );
        if (ioctl_res != 0) {
            std.debug.print("WSAIoctl(SIO_BASE_HANDLE) failed: {any}\n", .{ws2_32.WSAGetLastError()});
            return error.GetBaseHandleFailed;
        }

        std.debug.print("Base socket handle obtained: {any}\n", .{base_socket_handle});

        // Associate base_socket_handle with IOCP
        _ = try windows.CreateIoCompletionPort(
            base_socket_handle,
            self.iocp,
            0, // CompletionKey - not used for AFD_POLL, as IO_STATUS_BLOCK contains the context.
            0 // NumberOfConcurrentThreads - 0 means system defaults
        );
        std.debug.print("Base socket handle successfully associated with IOCP.\n", .{});

        // - Start client thread
        const client_thread: std.Thread = try std.Thread.spawn(.{}, struct {
            fn run(port: u16) void {
                // Initialize WinSock for this thread
                var wsa_data: ws2_32.WSADATA = undefined;
                const wsa_startup_res: i32 = ws2_32.WSAStartup(0x0202, &wsa_data); // Request Winsock 2.2
                if (wsa_startup_res != 0) {
                    std.debug.print("Client WSAStartup failed with error: {any}\n", .{wsa_startup_res});
                    return; // Cannot proceed without Winsock
                }
                defer _ = ws2_32.WSACleanup(); // Clean up Winsock for this thread on exit

                // Create client socket using SocketCreator.fromAddress
                const client_addr_cfg = address.TCPClientAddress.init("127.0.0.1", port);
                const client_adrs: address.Address = .{ .tcp_client_addr = client_addr_cfg };

                var sc = SocketCreator.init(std.heap.page_allocator);
                var client_skt: Skt = sc.fromAddress(client_adrs) catch unreachable;
                defer client_skt.deinit();

                const client_socket: ws2_32.SOCKET = client_skt.socket.?; // Extract raw socket

                // ... rest of the client connection logic ...


                const server_addr_in: ws2_32.sockaddr.in = .{
                    .family = ws2_32.AF.INET,
                    .port = std.mem.nativeToBig(u16, port),
                    .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
                    .zero = .{0} ** 8,
                };
                var generic_server_addr: ws2_32.sockaddr = undefined;
                @memcpy(std.mem.asBytes(&generic_server_addr), std.mem.asBytes(&server_addr_in));


                const connect_res: i32 = ws2_32.connect(client_socket, &generic_server_addr, @sizeOf(ws2_32.sockaddr.in));
                if (connect_res != 0) {
                    std.debug.print("Client connect failed: {any} (WSAGetLastError: {any})\n", .{connect_res, ws2_32.WSAGetLastError()});
                } else {
                    std.debug.print("Client connect returned 0 (may be pending). WSAGetLastError: {any}\n", .{ws2_32.WSAGetLastError()});
                    // For non-blocking sockets, connect returning 0 might still mean pending.
                    // We'll proceed with sleeping anyway, as the event loop should pick it up.
                }
                std.debug.print("Client connected/pending. Sleeping for 2000ms...\n", .{});
                std.Thread.sleep(2000 * std.time.ns_per_ms); // Keep connection open briefly (2000ms)
                std.debug.print("Client waking up and closing socket.\n", .{});
            }
        }.run, .{self.listen_port});

        // - Issue AFD_POLL
        // Use the same buffer for both input and output (METHOD_BUFFERED IOCTL).
        // This matches wepoll, c-ares, mio, and all reference implementations.
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        var afd_poll_info: ntdllx.AFD_POLL_INFO = .{
            .Timeout = 0, // No timeout, wait indefinitely
            .NumberOfHandles = 1,
            .Exclusive = 0, // 0 is FALSE, 1 is TRUE,
            .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                .{ .Handle = base_socket_handle, .Events = ntdllx.AFD_POLL_ACCEPT, .Status = .SUCCESS },
            },
        };

        const status_afd_poll: ntdllx.NTSTATUS = ntdll.NtDeviceIoControlFile(
            base_socket_handle,
            self.event_handle, null, null, // Event, ApcRoutine, ApcContext
            &io_status_block,
            ntdllx.IOCTL_AFD_POLL,
            &afd_poll_info, @sizeOf(ntdllx.AFD_POLL_INFO),
            &afd_poll_info, @sizeOf(ntdllx.AFD_POLL_INFO),
        );

        if (status_afd_poll != .SUCCESS and status_afd_poll != .PENDING) {
            std.debug.print("NtDeviceIoControlFile(AFD_POLL) failed immediately: {any}\n", .{status_afd_poll});
            return error.AfdPollFailed;
        }

        std.debug.print("AFD_POLL issued. Waiting for event to be signaled...\n", .{});

        // - Wait on event handle
        const wait_res = ntdllx.WaitForSingleObject(self.event_handle, ntdllx.INFINITE);
        if (wait_res != ntdllx.WAIT_OBJECT_0) {
            std.debug.print("WaitForSingleObject failed or timed out unexpectedly: {any}\n", .{wait_res});
            return error.EventWaitFailed; // Need to define this error
        }
        std.debug.print("Event signaled.\n", .{});

        // - After event signaled, check IO_STATUS_BLOCK to confirm completion
        // For AFD_POLL, the IO_STATUS_BLOCK is what matters.
        if (io_status_block.u.Status != .SUCCESS) {
            std.debug.print("AFD_POLL completion status not SUCCESS: {any}\n", .{io_status_block.u.Status});
            return error.AfdPollCompletionError;
        }

        std.debug.print("AFD_POLL completed. Events returned: 0x{X}\n", .{afd_poll_info.Handles[0].Events});
        if ((afd_poll_info.Handles[0].Events & ntdllx.AFD_POLL_ACCEPT) == 0) {
            std.debug.print("AFD_POLL_ACCEPT event not set in completion.\n", .{});
            return error.AfdPollAcceptNotSet;
        }

        std.debug.print("Successfully received AFD_POLL_ACCEPT event!\n", .{});

        client_thread.join();
    }
};

pub fn runTest() !void {
    // Initialize WinSock
    var wsa_data: ws2_32.WSADATA = undefined;
    const wsa_startup_res: i32 = ws2_32.WSAStartup(0x0202, &wsa_data); // Request Winsock 2.2
    if (wsa_startup_res != 0) {
        return error.WSAStartupFailed;
    }
    defer _ = ws2_32.WSACleanup();

    // This is the main entry point for the test
    var stage: Stage1Accept = try Stage1Accept.init();
    defer stage.deinit();

    try stage.runAcceptTest();
    std.debug.print("Stage 1 POC (Accept) successful.\n", .{});
}
