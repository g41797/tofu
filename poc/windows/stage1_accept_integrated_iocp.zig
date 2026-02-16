// SPDX-FileCopyrightText: Copyright (c) 2026 g41797
// SPDX-License-Identifier: MIT

const std = @import("std");
const windows = std.os.windows;
const ntdll = windows.ntdll;
const ws2_32 = windows.ws2_32;
const poc = @import("poc.zig");
const afd = poc.afd;
const ntdllx = poc.ntdllx;
const tofu = @import("tofu");
const Skt = tofu.Skt;
const SocketCreator = tofu.SocketCreator;
const address = tofu.address;

pub const Stage1AcceptIocp = struct {
    poller: afd.AfdPoller,
    listen_socket: Skt,
    listen_port: u16,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = .{
            .poller = try afd.AfdPoller.init(allocator),
            .listen_socket = undefined,
            .listen_port = 23457,
            .allocator = allocator,
        };

        const server_addr_cfg = address.TCPServerAddress.init("127.0.0.1", self.listen_port);
        const server_adrs: address.Address = .{ .tcp_server_addr = server_addr_cfg };

        var sc: SocketCreator = SocketCreator.init(allocator);
        self.listen_socket = try sc.fromAddress(server_adrs);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.*.listen_socket.deinit();
        self.*.poller.deinit();
    }

    pub fn runAcceptTest(self: *Self) !void {
        const base_handle: windows.HANDLE = try self.*.poller.register(&self.*.listen_socket);
        _ = base_handle;
        var listen_ctx: poc.SocketContext = poc.SocketContext.init(&self.*.listen_socket);

        // Arm for ACCEPT
        try listen_ctx.arm(ntdllx.AFD_POLL_ACCEPT, &listen_ctx);
        std.debug.print("[Accept-IOCP] Listener registered and armed. Waiting for client...\n", .{});

        // Start client thread
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
            }
        }.run, .{self.*.listen_port});
        defer client_thread.join();

        // Wait on IOCP for completion
        var entries: [1]ntdllx.FILE_COMPLETION_INFORMATION = undefined;
        const removed: u32 = try self.*.poller.poll(5000, &entries);

        if (removed == 0) return error.PollCompletionFailed;

        const returned_ctx: *poc.SocketContext = @ptrCast(@alignCast(entries[0].ApcContext.?));
        if (returned_ctx != &listen_ctx) return error.AfdPollCompletionError;

        if ((listen_ctx.poll_info.Handles[0].Events & ntdllx.AFD_POLL_ACCEPT) == 0) {
            return error.AfdPollAcceptNotSet;
        }

        std.debug.print("[Accept-IOCP] Successfully detected ACCEPT via AfdPoller!\n", .{});
    }
};

pub fn runTest() !void {
    var wsa_data: ws2_32.WSADATA = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa_data);
    defer _ = ws2_32.WSACleanup();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var stage: Stage1AcceptIocp = try Stage1AcceptIocp.init(gpa.allocator());
    defer stage.deinit();

    try stage.runAcceptTest();
}
