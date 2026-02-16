// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const poc = @import("poc.zig");
const afd = poc.afd;
const ntdllx = poc.ntdllx;
const Skt = @import("tofu").Skt;
const SocketCreator = @import("tofu").SocketCreator;
const address = @import("tofu").address;

pub const Stage1Accept = struct {
    poller: afd.AfdPoller,
    listen_socket: Skt,
    listen_port: u16,
    event_handle: windows.HANDLE,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = .{
            .poller = try afd.AfdPoller.init(allocator),
            .listen_socket = undefined,
            .listen_port = 23456,
            .event_handle = ntdllx.CreateEventA(null, windows.TRUE, windows.FALSE, null),
        };

        if (self.event_handle == windows.INVALID_HANDLE_VALUE) {
            self.poller.deinit();
            return error.EventCreateFailed;
        }

        const server_adrs: address.Address = .{ .tcp_server_addr = address.TCPServerAddress.init("127.0.0.1", self.listen_port) };
        var sc = SocketCreator.init(allocator);
        self.listen_socket = try sc.fromAddress(server_adrs);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.listen_socket.deinit();
        self.poller.deinit();
        windows.CloseHandle(self.event_handle);
    }

    pub fn runAcceptTest(self: *Self) !void {
        const base_handle: windows.HANDLE = try self.poller.register(&self.*.listen_socket);
        std.debug.print("[Accept-POC] Listener base handle: {any}\n", .{base_handle});

        // Start client
        const client_thread = try std.Thread.spawn(.{}, struct {
            fn run(port: u16) void {
                var wsa_data: ws2_32.WSADATA = undefined;
                _ = ws2_32.WSAStartup(0x0202, &wsa_data);
                defer _ = ws2_32.WSACleanup();

                var sc = SocketCreator.init(std.heap.page_allocator);
                var client_skt = sc.fromAddress(.{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", port) }) catch return;
                defer client_skt.deinit();

                const server_addr_in: ws2_32.sockaddr.in = .{
                    .family = ws2_32.AF.INET,
                    .port = std.mem.nativeToBig(u16, port),
                    .addr = std.mem.nativeToBig(u32, 0x7f000001),
                    .zero = .{0} ** 8,
                };
                _ = ws2_32.connect(client_skt.socket.?, @ptrCast(&server_addr_in), @sizeOf(ws2_32.sockaddr.in));
                std.Thread.sleep(1000 * std.time.ns_per_ms);
            }
        }.run, .{self.listen_port});
        defer client_thread.join();

        const ctx: poc.SocketContext = poc.SocketContext.init(&self.*.listen_socket);
        // Use event handle for manual wait verification
        var poll_info = ntdllx.AFD_POLL_INFO{
            .Timeout = -1,
            .NumberOfHandles = 1,
            .Exclusive = 0,
            .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                .{ .Handle = base_handle, .Events = ntdllx.AFD_POLL_ACCEPT, .Status = .SUCCESS },
            },
        };

        const status: ntdllx.NTSTATUS = windows.ntdll.NtDeviceIoControlFile(
            base_handle,
            self.*.event_handle,
            null,
            null,
            &ctx.skt.*.io_status,
            ntdllx.IOCTL_AFD_POLL,
            &poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
            &poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
        );

        if (status != .SUCCESS and status != .PENDING) return error.AfdPollFailed;

        std.debug.print("[Accept-POC] Waiting for client...\n", .{});
        _ = ntdllx.WaitForSingleObject(self.event_handle, ntdllx.INFINITE);

        if (poll_info.Handles[0].Events & ntdllx.AFD_POLL_ACCEPT != 0) {
            std.debug.print("[Accept-POC] Successfully detected ACCEPT readiness via AfdPoller logic!\n", .{});
        }
    }
};

pub fn runTest() !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    if (ws2_32.WSAStartup(0x0202, &wsa_data) != 0) return error.WSAStartupFailed;
    defer _ = ws2_32.WSACleanup();

    var stage = try Stage1Accept.init(std.heap.page_allocator);
    defer stage.deinit();
    try stage.runAcceptTest();
}
