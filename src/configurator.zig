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

const ConfigPrintFormatTCP = "{s}|{s}|{d}";
const ConfigPrintFormatUDS = "{s}|{s}";

/// Format: "tcp|127.0.0.1|7099" or "uds|/tmp/7099.port"
pub const ConnectToHeader = "~connect_to";

/// Format: "tcp|127.0.0.1|7099" (loopback) or "tcp||7099" (all interfaces) or "uds|/tmp/7099.port"
pub const ListenOnHeader = "~listen_on";

pub const TCPClientConfigurator = struct {
    addrbuf: [256]u8 = undefined,
    port: ?u16 = null,

    pub fn init(host_or_ip: ?[]const u8, port: ?u16) TCPClientConfigurator {
        var cnf: TCPClientConfigurator = .{};

        cnf.toAddrBuf(host_or_ip);

        if (port) |pr| {
            cnf.port = pr;
        } else {
            cnf.port = DefaultPort;
        }
        return cnf;
    }

    pub fn prepareRequest(self: *const TCPClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg, .request);
        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn prepareSignal(self: *const TCPClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg, .signal);
        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *const TCPClientConfigurator, config: *TextHeaders) AmpeError!void {
        const addrlen = self.addrLen();

        if ((addrlen == 0) or (self.port == null)) {
            return AmpeError.WrongConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatTCP, .{ TCPProto, self.addrbuf[0..addrlen], self.port.? }) catch unreachable;
        config.append(ConnectToHeader, confHeader) catch {
            return AmpeError.WrongConfiguration;
        };
        return;
    }

    fn addrLen(self: *const TCPClientConfigurator) usize {
        const ret = std.mem.indexOf(u8, &self.addrbuf, &[_]u8{0}) orelse self.addrbuf.len;
        return ret;
    }

    fn toAddrBuf(self: *TCPClientConfigurator, host_or_ip: ?[]const u8) void {
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

    pub fn addrToSlice(self: *const TCPClientConfigurator) []const u8 {
        const ret = self.addrbuf[0..self.addrLen()];
        return ret;
    }
};

pub const TCPServerConfigurator = struct {
    addrbuf: [256]u8 = undefined,
    port: ?u16 = null,

    pub fn init(ip: ?[]const u8, port: ?u16) TCPServerConfigurator {
        var cnf: TCPServerConfigurator = .{};

        cnf.toAddrBuf(ip);

        if (port) |pr| {
            cnf.port = pr;
        } else {
            cnf.port = DefaultPort;
        }
        return cnf;
    }

    pub fn prepareRequest(self: *const TCPServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg, .request);
        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn prepareSignal(self: *const TCPServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg, .signal);
        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *const TCPServerConfigurator, config: *TextHeaders) AmpeError!void {
        const addrlen = self.addrLen();

        if ((addrlen == 0) or (self.port == null)) {
            return AmpeError.WrongConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatTCP, .{ TCPProto, self.addrbuf[0..addrlen], self.port.? }) catch unreachable;
        config.append(ListenOnHeader, confHeader) catch {
            return AmpeError.WrongConfiguration;
        };
        return;
    }

    fn addrLen(self: *const TCPServerConfigurator) usize {
        const ret = std.mem.indexOf(u8, &self.addrbuf, &[_]u8{0}) orelse self.addrbuf.len;
        return ret;
    }

    fn toAddrBuf(self: *TCPServerConfigurator, host_or_ip: ?[]const u8) void {
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

    pub fn addrToSlice(self: *const TCPServerConfigurator) []const u8 {
        const ret = self.addrbuf[0..self.addrLen()];
        return ret;
    }
};

pub const UDSClientConfigurator = struct {
    addrbuf: [108]u8 = undefined,

    pub fn init(path: []const u8) UDSClientConfigurator {
        var ret: UDSClientConfigurator = .{};
        ret.toAddrBuf(path);
        return ret;
    }

    pub fn prepareRequest(self: *const UDSClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg, .request);
        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn prepareSignal(self: *const UDSClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg, .signal);
        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *const UDSClientConfigurator, config: *TextHeaders) AmpeError!void {
        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatUDS, .{
            UDSProto,
            self.addrToSlice(),
        }) catch unreachable;
        config.append(ConnectToHeader, confHeader) catch {
            return AmpeError.WrongConfiguration;
        };
        return;
    }

    fn addrLen(self: *const UDSClientConfigurator) usize {
        const ret = std.mem.indexOf(u8, &self.addrbuf, &[_]u8{0}) orelse self.addrbuf.len;
        return ret;
    }

    fn toAddrBuf(self: *UDSClientConfigurator, path: []const u8) void {
        @memset(&self.addrbuf, 0);

        const dest = self.addrbuf[0..@min(path.len, self.addrbuf.len)];

        @memcpy(dest, path);

        return;
    }

    pub fn addrToSlice(self: *const UDSClientConfigurator) []const u8 {
        const ret = self.addrbuf[0..self.addrLen()];
        return ret;
    }
};

pub const UDSServerConfigurator = struct {
    addrbuf: [108]u8 = undefined,

    pub fn init(path: []const u8) UDSServerConfigurator {
        var ret: UDSServerConfigurator = .{};
        ret.toAddrBuf(path);
        return ret;
    }

    pub fn prepareRequest(self: *const UDSServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg, .request);
        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn prepareSignal(self: *const UDSServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg, .signal);
        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *const UDSServerConfigurator, config: *TextHeaders) AmpeError!void {
        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatUDS, .{ UDSProto, self.addrToSlice() }) catch unreachable;
        config.append(ListenOnHeader, confHeader) catch {
            return AmpeError.WrongConfiguration;
        };
        return;
    }

    fn addrLen(self: *const UDSServerConfigurator) usize {
        const ret = std.mem.indexOf(u8, &self.addrbuf, &[_]u8{0}) orelse self.addrbuf.len;
        return ret;
    }

    fn toAddrBuf(self: *UDSServerConfigurator, path: []const u8) void {
        @memset(&self.addrbuf, 0);

        const dest = self.addrbuf[0..@min(path.len, self.addrbuf.len)];

        @memcpy(dest, path);

        return;
    }

    pub fn addrToSlice(self: *const UDSServerConfigurator) []const u8 {
        const ret = self.addrbuf[0..self.addrLen()];
        return ret;
    }
};

pub const WrongConfigurator = struct {
    pub fn prepareRequest(self: *const WrongConfigurator, msg: *Message) AmpeError!void {
        _ = self;
        _ = msg;
        return AmpeError.WrongConfiguration;
    }

    pub fn prepareSignal(self: *const WrongConfigurator, msg: *Message) AmpeError!void {
        _ = self;
        _ = msg;
        return AmpeError.WrongConfiguration;
    }
};

pub const Configurator = union(enum) {
    tcp_server: TCPServerConfigurator,
    tcp_client: TCPClientConfigurator,
    uds_server: UDSServerConfigurator,
    uds_client: UDSClientConfigurator,
    wrong: WrongConfigurator,

    pub fn prepareRequest(self: *const Configurator, msg: *Message) AmpeError!void {
        return switch (self.*) {
            inline else => |conf| try conf.prepareRequest(msg),
        };
    }

    pub fn prepareSignal(self: *const Configurator, msg: *Message) AmpeError!void {
        return switch (self.*) {
            inline else => |conf| try conf.prepareSignal(msg),
        };
    }

    pub fn eql(self: Configurator, other: Configurator) bool {
        return activeTag(self) == activeTag(other);
    }

    pub fn fromMessage(msg: *Message) Configurator {
        const cftr: Configurator = .{
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

    fn clientFromString(string: []const u8) Configurator {
        var cftr: Configurator = .{
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
                    .uds_client = .init(parts[1]),
                };
                break;
            }

            const port = std.fmt.parseInt(u16, parts[2], 10) catch break :brk;
            cftr = .{
                .tcp_client = .init(parts[1], port),
            };
            break;
        }
        return cftr;
    }

    fn serverFromString(string: []const u8) Configurator {
        var cftr: Configurator = .{
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
                    .uds_server = .init(parts[1]),
                };
                break;
            }

            const port = std.fmt.parseInt(u16, parts[2], 10) catch break :brk;
            cftr = .{
                .tcp_server = .init(parts[1], port),
            };
            break;
        }
        return cftr;
    }

    // Returns true if .wrong is active field
    pub fn isWrong(self: *const Configurator) bool {
        switch (self.*) {
            .wrong => return true,
            inline else => return false,
        }
    }
};

inline fn prepareForServer(msg: *Message, role: message.MessageRole) void {
    msg.bhdr = .{};

    msg.bhdr.proto = .{
        .mtype = .welcome,
        .role = role,
    };
}

inline fn prepareForClient(msg: *Message, role: message.MessageRole) void {
    msg.bhdr = .{};

    msg.bhdr.proto = .{
        .mtype = .hello,
        .role = role,
    };
}

inline fn isFirstServerRequest(msg: *Message) bool {
    if (msg.bhdr.proto.mtype != .welcome) {
        return false;
    }
    if (msg.bhdr.proto.role != .request) {
        return false;
    }
    if (msg.bhdr.proto.more != .last) {
        return false;
    }
    if (msg.bhdr.proto.origin != .application) {
        return false;
    }

    return true;
}

inline fn isFirstClientRequest(msg: *Message) bool {
    if (msg.bhdr.proto.mtype != .hello) {
        return false;
    }
    if (msg.bhdr.proto.role != .request) {
        return false;
    }
    if (msg.bhdr.proto.more != .last) {
        return false;
    }
    if (msg.bhdr.proto.origin != .application) {
        return false;
    }

    return true;
}

const LazyPTOP = 7099;

pub const message = @import("message.zig");
pub const Message = message.Message;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeaders = message.TextHeaders;
pub const AmpeError = @import("status.zig").AmpeError;

const std = @import("std");
const activeTag = std.meta.activeTag;

// 2DO prepareRequest - replace with prepare +
