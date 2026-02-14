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

pub const Stage1AcceptIocp = struct {
    iocp: windows.HANDLE,
    listen_socket: Skt,
    listen_port: u16,

    const Self = @This();

    pub const Error = error{
        IocpCreateFailed,
        GetBaseHandleFailed,
        IocpAssociateFailed,
        AfdPollFailed,
        PollCompletionFailed,
        NoCompletionEntry,
        AfdPollCompletionError,
        AfdPollAcceptNotSet,
        WSAStartupFailed,
    };

    pub fn init() !Self {
        var self: Self = .{
            .iocp = undefined,
            .listen_socket = undefined,
            .listen_port = 23457, // Different port from event-based test to avoid conflicts
        };

        // 1. Create IOCP
        const status_iocp: ntdllx.NTSTATUS = ntdllx.NtCreateIoCompletion(&self.iocp, windows.GENERIC_READ | windows.GENERIC_WRITE, null, 0);
        if (status_iocp != .SUCCESS) {
            return error.IocpCreateFailed;
        }

        // 2. Create Listener Socket using SocketCreator.fromAddress
        const server_addr_cfg: address.TCPServerAddress = address.TCPServerAddress.init("127.0.0.1", self.listen_port);
        const server_adrs: address.Address = .{ .tcp_server_addr = server_addr_cfg };

        var sc: SocketCreator = SocketCreator.init(std.heap.page_allocator);
        self.listen_socket = sc.fromAddress(server_adrs) catch unreachable;

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.listen_socket.deinit();
        windows.CloseHandle(self.iocp);
    }

    pub fn runAcceptTest(self: *Self) !void {
        // - Get base handle
        var base_socket_handle: windows.HANDLE = undefined;
        var bytes_returned: u32 = undefined;
        const ioctl_res: i32 = ws2_32.WSAIoctl(
            self.listen_socket.socket.?,
            ws2_32.SIO_BASE_HANDLE,
            null, 0,
            @ptrCast(&base_socket_handle),
            @sizeOf(windows.HANDLE),
            &bytes_returned,
            null, null,
        );
        if (ioctl_res != 0) {
            std.debug.print("WSAIoctl(SIO_BASE_HANDLE) failed: {any}\n", .{ws2_32.WSAGetLastError()});
            return error.GetBaseHandleFailed;
        }

        std.debug.print("IOCP test: Base socket handle obtained: {any}\n", .{base_socket_handle});

        // Associate base_socket_handle with IOCP
        _ = try windows.CreateIoCompletionPort(
            base_socket_handle,
            self.iocp,
            0, // CompletionKey
            0, // NumberOfConcurrentThreads - 0 means system defaults
        );
        std.debug.print("IOCP test: Base socket handle successfully associated with IOCP.\n", .{});

        // - Start client thread
        const client_thread: std.Thread = try std.Thread.spawn(.{}, struct {
            fn run(port: u16) void {
                // Initialize WinSock for this thread
                var wsa_data: ws2_32.WSADATA = undefined;
                const wsa_startup_res: i32 = ws2_32.WSAStartup(0x0202, &wsa_data);
                if (wsa_startup_res != 0) {
                    std.debug.print("IOCP test: Client WSAStartup failed with error: {any}\n", .{wsa_startup_res});
                    return;
                }
                defer _ = ws2_32.WSACleanup();

                // Create client socket using SocketCreator.fromAddress
                const client_addr_cfg: address.TCPClientAddress = address.TCPClientAddress.init("127.0.0.1", port);
                const client_adrs: address.Address = .{ .tcp_client_addr = client_addr_cfg };

                var sc: SocketCreator = SocketCreator.init(std.heap.page_allocator);
                var client_skt: Skt = sc.fromAddress(client_adrs) catch unreachable;
                defer client_skt.deinit();

                const client_socket: ws2_32.SOCKET = client_skt.socket.?;

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
                    std.debug.print("IOCP test: Client connect failed: {any} (WSAGetLastError: {any})\n", .{ connect_res, ws2_32.WSAGetLastError() });
                } else {
                    std.debug.print("IOCP test: Client connect returned 0. WSAGetLastError: {any}\n", .{ws2_32.WSAGetLastError()});
                }
                std.debug.print("IOCP test: Client connected/pending. Sleeping for 2000ms...\n", .{});
                std.Thread.sleep(2000 * std.time.ns_per_ms);
                std.debug.print("IOCP test: Client waking up and closing socket.\n", .{});
            }
        }.run, .{self.listen_port});

        // - Issue AFD_POLL
        // Use the same buffer for both input and output (METHOD_BUFFERED IOCTL).
        // Decision Log Section 8.1: Always use the same AFD_POLL_INFO for both.
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        var afd_poll_info: ntdllx.AFD_POLL_INFO = .{
            .Timeout = 0, // No timeout, wait indefinitely
            .NumberOfHandles = 1,
            .Exclusive = 0, // 0 is FALSE
            .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                .{ .Handle = base_socket_handle, .Events = ntdllx.AFD_POLL_ACCEPT, .Status = .SUCCESS },
            },
        };

        // Decision Log Section 8.2: ApcContext must be non-null for IOCP completion posting.
        // Pass Event = null so completion goes to IOCP only (not to an event).
        // Pass ApcContext = @ptrCast(&io_status_block) to enable IOCP posting.
        const status_afd_poll: ntdllx.NTSTATUS = ntdll.NtDeviceIoControlFile(
            base_socket_handle,
            null, null, @ptrCast(&io_status_block), // Event=null, ApcRoutine=null, ApcContext=&io_status_block
            &io_status_block,
            ntdllx.IOCTL_AFD_POLL,
            &afd_poll_info, @sizeOf(ntdllx.AFD_POLL_INFO),
            &afd_poll_info, @sizeOf(ntdllx.AFD_POLL_INFO),
        );

        if (status_afd_poll != .SUCCESS and status_afd_poll != .PENDING) {
            std.debug.print("IOCP test: NtDeviceIoControlFile(AFD_POLL) failed immediately: {any}\n", .{status_afd_poll});
            return error.AfdPollFailed;
        }

        std.debug.print("IOCP test: AFD_POLL issued (status={any}). Waiting on IOCP...\n", .{status_afd_poll});

        // - Wait on IOCP for completion (10-second timeout to prevent test hangs)
        var entries: [1]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        var removed: u32 = 0;

        // NT timeout: negative = relative, in 100ns units. 10 seconds = -10 * 10_000_000
        var timeout: windows.LARGE_INTEGER = -10 * 10_000_000;

        const status_wait: ntdllx.NTSTATUS = ntdllx.NtRemoveIoCompletionEx(
            self.iocp,
            &entries,
            1,
            &removed,
            &timeout,
            0, // Not alertable
        );

        if (status_wait != .SUCCESS) {
            std.debug.print("IOCP test: NtRemoveIoCompletionEx failed or timed out: {any}\n", .{status_wait});
            return error.PollCompletionFailed;
        }

        if (removed == 0) {
            std.debug.print("IOCP test: NtRemoveIoCompletionEx returned SUCCESS but no entries removed.\n", .{});
            return error.NoCompletionEntry;
        }

        std.debug.print("IOCP test: Completion received. Removed={d}\n", .{removed});

        // Validate the completion entry
        // The ApcContext we passed should come back in the entry
        const returned_apc_context: ?*anyopaque = entries[0].ApcContext;
        std.debug.print("IOCP test: Completion ApcContext={any}, expected={any}\n", .{ returned_apc_context, @as(?*anyopaque, @ptrCast(&io_status_block)) });

        // Check IO_STATUS_BLOCK for success
        if (io_status_block.u.Status != .SUCCESS) {
            std.debug.print("IOCP test: AFD_POLL completion status not SUCCESS: {any}\n", .{io_status_block.u.Status});
            return error.AfdPollCompletionError;
        }

        std.debug.print("IOCP test: AFD_POLL completed. Events returned: 0x{X}\n", .{afd_poll_info.Handles[0].Events});
        if ((afd_poll_info.Handles[0].Events & ntdllx.AFD_POLL_ACCEPT) == 0) {
            std.debug.print("IOCP test: AFD_POLL_ACCEPT event not set in completion.\n", .{});
            return error.AfdPollAcceptNotSet;
        }

        std.debug.print("IOCP test: Successfully received AFD_POLL_ACCEPT event via IOCP!\n", .{});

        client_thread.join();
    }
};

pub fn runTest() !void {
    // Initialize WinSock
    var wsa_data: ws2_32.WSADATA = undefined;
    const wsa_startup_res: i32 = ws2_32.WSAStartup(0x0202, &wsa_data);
    if (wsa_startup_res != 0) {
        return error.WSAStartupFailed;
    }
    defer _ = ws2_32.WSACleanup();

    var stage: Stage1AcceptIocp = try Stage1AcceptIocp.init();
    defer stage.deinit();

    try stage.runAcceptTest();
    std.debug.print("Stage 1 POC (Accept via IOCP) successful.\n", .{});
}
