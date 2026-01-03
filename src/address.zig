// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

//! TCP/UDS address configuration for Hello/Welcome messages.

pub const Proto = enum {
    tcp,
    uds,
};

pub const TCPProto = "tcp";
pub const UDSProto = "uds";
pub const DefaultProto = TCPProto;
pub const DefaultAddr = "127.0.0.1";
pub const DefaultPort = LazyPTOP;

const AddressFormatTCP = "{s}|{s}|{d}";
const AddressFormatUDS = "{s}|{s}";

/// Format: "tcp|127.0.0.1|7099" or "uds|/tmp/7099.port"
pub const ConnectToHeader = "~connect_to";

/// Format: "tcp|127.0.0.1|7099" (loopback) or "tcp||7099" (all interfaces) or "uds|/tmp/7099.port"
pub const ListenOnHeader = "~listen_on";

pub const TCPClientAddress = struct {
    addrbuf: [256]u8 = undefined,
    port: ?u16 = null,

    pub fn init(host_or_ip: ?[]const u8, port: ?u16) TCPClientAddress {
        var cnf: TCPClientAddress = .{};

        cnf.toAddrBuf(host_or_ip);

        if (port) |pr| {
            cnf.port = pr;
        } else {
            cnf.port = DefaultPort;
        }
        return cnf;
    }

    pub fn format(self: *const TCPClientAddress, msg: *Message) AmpeError!void {
        prepareForClient(msg);
        try self.toHeaders(&msg.*.thdrs);
    }

    fn toHeaders(self: *const TCPClientAddress, config: *TextHeaders) AmpeError!void {
        const addrlen = self.addrLen();

        if ((addrlen == 0) or (self.port == null)) {
            return AmpeError.WrongAddress;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, AddressFormatTCP, .{ TCPProto, self.addrbuf[0..addrlen], self.port.? }) catch unreachable;
        config.append(ConnectToHeader, confHeader) catch {
            return AmpeError.WrongAddress;
        };
        return;
    }

    fn addrLen(self: *const TCPClientAddress) usize {
        const ret = std.mem.indexOf(u8, &self.addrbuf, &[_]u8{0}) orelse self.addrbuf.len;
        return ret;
    }

    fn toAddrBuf(self: *TCPClientAddress, host_or_ip: ?[]const u8) void {
        @memset(&self.addrbuf, 0);
        @memcpy(self.addrbuf[0..DefaultAddr.len], DefaultAddr);

        if (host_or_ip == null) {
            return;
        }

        const addr = host_or_ip.?;

        @memset(&self.addrbuf, 0);

        const dest = self.addrbuf[0..@min(addr.len, self.addrbuf.len)];

        @memcpy(dest, addr);

        return;
    }

    pub fn addrToSlice(self: *const TCPClientAddress) []const u8 {
        const ret = self.addrbuf[0..self.addrLen()];
        return ret;
    }
};

pub const TCPServerAddress = struct {
    addrbuf: [256]u8 = undefined,
    port: ?u16 = null,

    pub fn init(ip: ?[]const u8, port: ?u16) TCPServerAddress {
        var cnf: TCPServerAddress = .{};

        cnf.toAddrBuf(ip);

        if (port) |pr| {
            cnf.port = pr;
        } else {
            cnf.port = DefaultPort;
        }
        return cnf;
    }

    pub fn format(self: *const TCPServerAddress, msg: *Message) AmpeError!void {
        prepareForServer(msg);
        try self.toHeaders(&msg.*.thdrs);
    }

    fn toHeaders(self: *const TCPServerAddress, config: *TextHeaders) AmpeError!void {
        const addrlen = self.addrLen();

        if ((addrlen == 0) or (self.port == null)) {
            return AmpeError.WrongAddress;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, AddressFormatTCP, .{ TCPProto, self.addrbuf[0..addrlen], self.port.? }) catch unreachable;
        config.append(ListenOnHeader, confHeader) catch {
            return AmpeError.WrongAddress;
        };
        return;
    }

    fn addrLen(self: *const TCPServerAddress) usize {
        const ret = std.mem.indexOf(u8, &self.addrbuf, &[_]u8{0}) orelse self.addrbuf.len;
        return ret;
    }

    fn toAddrBuf(self: *TCPServerAddress, host_or_ip: ?[]const u8) void {
        @memset(&self.addrbuf, 0);

        if (host_or_ip == null) {
            return;
        }

        const addr = host_or_ip.?;

        @memset(&self.addrbuf, 0);

        const dest = self.addrbuf[0..@min(addr.len, self.addrbuf.len)];

        @memcpy(dest, addr);

        return;
    }

    pub fn addrToSlice(self: *const TCPServerAddress) []const u8 {
        const ret = self.addrbuf[0..self.addrLen()];
        return ret;
    }
};

pub const UDSClientAddress = struct {
    addrbuf: [108]u8 = undefined,

    pub fn init(path: []const u8) UDSClientAddress {
        var ret: UDSClientAddress = .{};
        ret.toAddrBuf(path);
        return ret;
    }

    pub fn format(self: *const UDSClientAddress, msg: *Message) AmpeError!void {
        prepareForClient(msg);
        try self.toHeaders(&msg.*.thdrs);
    }

    fn toHeaders(self: *const UDSClientAddress, config: *TextHeaders) AmpeError!void {
        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, AddressFormatUDS, .{
            UDSProto,
            self.addrToSlice(),
        }) catch unreachable;
        config.append(ConnectToHeader, confHeader) catch {
            return AmpeError.WrongAddress;
        };
        return;
    }

    fn addrLen(self: *const UDSClientAddress) usize {
        const ret = std.mem.indexOf(u8, &self.addrbuf, &[_]u8{0}) orelse self.addrbuf.len;
        return ret;
    }

    fn toAddrBuf(self: *UDSClientAddress, path: []const u8) void {
        @memset(&self.addrbuf, 0);

        const dest = self.addrbuf[0..@min(path.len, self.addrbuf.len)];

        @memcpy(dest, path);

        return;
    }

    pub fn addrToSlice(self: *const UDSClientAddress) []const u8 {
        const ret = self.addrbuf[0..self.addrLen()];
        return ret;
    }
};

pub const UDSServerAddress = struct {
    addrbuf: [108]u8 = undefined,

    pub fn init(path: []const u8) UDSServerAddress {
        var ret: UDSServerAddress = .{};
        ret.toAddrBuf(path);
        return ret;
    }

    pub fn format(self: *const UDSServerAddress, msg: *Message) AmpeError!void {
        prepareForServer(msg);
        try self.toHeaders(&msg.*.thdrs);
    }

    fn toHeaders(self: *const UDSServerAddress, config: *TextHeaders) AmpeError!void {
        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, AddressFormatUDS, .{ UDSProto, self.addrToSlice() }) catch unreachable;
        config.append(ListenOnHeader, confHeader) catch {
            return AmpeError.WrongAddress;
        };
        return;
    }

    fn addrLen(self: *const UDSServerAddress) usize {
        const ret = std.mem.indexOf(u8, &self.addrbuf, &[_]u8{0}) orelse self.addrbuf.len;
        return ret;
    }

    fn toAddrBuf(self: *UDSServerAddress, path: []const u8) void {
        @memset(&self.addrbuf, 0);

        const dest = self.addrbuf[0..@min(path.len, self.addrbuf.len)];

        @memcpy(dest, path);

        return;
    }

    pub fn addrToSlice(self: *const UDSServerAddress) []const u8 {
        const ret = self.addrbuf[0..self.addrLen()];
        return ret;
    }
};

pub const WrongAddress = struct {
    pub fn format(self: *const WrongAddress, msg: *Message) AmpeError!void {
        _ = self;
        _ = msg;
        return AmpeError.WrongAddress;
    }
};

pub const Address = union(enum) {
    tcp_server_addr: TCPServerAddress,
    tcp_client_addr: TCPClientAddress,
    uds_server_addr: UDSServerAddress,
    uds_client_addr: UDSClientAddress,
    wrong: WrongAddress,

    pub fn format(self: *const Address, msg: *Message) AmpeError!void {
        return switch (self.*) {
            inline else => |conf| try conf.format(msg),
        };
    }

    pub fn eql(self: Address, other: Address) bool {
        return activeTag(self) == activeTag(other);
    }

    pub fn parse(msg: *Message) Address {
        const cftr: Address = .{
            .wrong = .{},
        };
        if (msg.actual_headers_len() == 0) {
            return cftr;
        }
        var it = msg.thdrs.hiter();

        var next = it.next();

        while (next != null) : (next = it.next()) {
            if (std.mem.eql(u8, next.?.name, ConnectToHeader)) {
                return clientFromString(next.?.value);
            }
            if (std.mem.eql(u8, next.?.name, ListenOnHeader)) {
                return serverFromString(next.?.value);
            }
        }

        return cftr;
    }

    fn clientFromString(string: []const u8) Address {
        var cftr: Address = .{
            .wrong = .{},
        };

        brk: while (true) {
            var split = std.mem.splitScalar(u8, string, '|');
            var parts: [3][]const u8 = undefined;
            var count: usize = 0;

            while (split.next()) |part| : (count += 1) {
                if (count > 3) {
                    break :brk;
                }
                parts[count] = part;
            }

            if (count < 2) {
                break;
            }

            if (count == 2) {
                if (!std.mem.eql(u8, parts[0], UDSProto)) {
                    break;
                }
                cftr = .{
                    .uds_client_addr = .init(parts[1]),
                };
                break;
            }

            const port = std.fmt.parseInt(u16, parts[2], 10) catch break :brk;
            cftr = .{
                .tcp_client_addr = .init(parts[1], port),
            };
            break;
        }
        return cftr;
    }

    fn serverFromString(string: []const u8) Address {
        var cftr: Address = .{
            .wrong = .{},
        };

        brk: while (true) {
            var split = std.mem.splitScalar(u8, string, '|');
            var parts: [3][]const u8 = undefined;
            var count: usize = 0;

            while (split.next()) |part| : (count += 1) {
                if (count > 3) {
                    break :brk;
                }
                parts[count] = part;
            }

            if (count < 2) {
                break;
            }

            if (count == 2) {
                if (!std.mem.eql(u8, parts[0], UDSProto)) {
                    break;
                }
                cftr = .{
                    .uds_server_addr = .init(parts[1]),
                };
                break;
            }

            const port = std.fmt.parseInt(u16, parts[2], 10) catch break :brk;
            cftr = .{
                .tcp_server_addr = .init(parts[1], port),
            };
            break;
        }
        return cftr;
    }

    // Returns true if .wrong is active field
    pub fn isWrong(self: *const Address) bool {
        switch (self.*) {
            .wrong => return true,
            inline else => return false,
        }
    }
};

inline fn prepareForServer(msg: *Message) void {
    msg.bhdr = .init(.WelcomeRequest);
}

inline fn prepareForClient(msg: *Message) void {
    msg.bhdr = .init(.HelloRequest);
}

const LazyPTOP = 7099;

pub const message = @import("message.zig");
pub const Message = message.Message;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeaders = message.TextHeaders;
pub const AmpeError = @import("status.zig").AmpeError;

const std = @import("std");
const activeTag = std.meta.activeTag;

// 2DO format - replace with prepare +
