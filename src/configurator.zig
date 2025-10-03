// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

/// Enum representing supported communication protocols.
pub const Proto = enum {
    tcp,
    uds,
};

/// Constant string for TCP protocol identifier.
pub const TCPProto = "tcp";

/// Constant string for UDS (Unix Domain Socket) protocol identifier.
pub const UDSProto = "uds";

/// Default protocol for communication (TCP).
pub const DefaultProto = TCPProto;

/// Default IP address for TCP communication (localhost).
pub const DefaultAddr = "127.0.0.1";

/// Default port number for communication.
pub const DefaultPort = LazyPTOP;

/// Format string for TCP configuration headers.
const ConfigPrintFormatTCP = "{s}|{s}|{d}";

/// Format string for UDS configuration headers.
const ConfigPrintFormatUDS = "{s}|{s}";

/// Header key for client connection configuration in Hello messages.
/// For the client - Part of Hello headers
/// "~connect_to: proto|addr or empty|port
/// "~connect_to: tcp|127.0.0.1|7099
/// "~connect_to: uds|/tmp/7099.port
pub const ConnectToHeader = "~connect_to";

/// Header key for server listening configuration in Welcome messages.
/// For the server - Part of Welcome headers, actually only this one is required
/// "~listen_on: proto|addr or empty|port
/// "~listen_on: tcp|127.0.0.1|7099  - on loopback only
/// "~listen_on: tcp||7099           - on every host IP address
/// "~listen_on: uds|/tmp/7099.port
pub const ListenOnHeader = "~listen_on";

/// Structure for configuring a TCP client connection.
pub const TCPClientConfigurator = struct {
    addrbuf: [256]u8 = undefined,
    port: ?u16 = null,

    /// Initializes a TCP client configurator with an optional host/IP address and port.
    /// Defaults to DefaultAddr and DefaultPort if not provided.
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

    /// Prepares a message with TCP client configuration for a Hello request.
    pub fn prepareRequest(self: *const TCPClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg, .request);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Prepares a message with TCP client configuration for a Hello signal.
    pub fn prepareSignal(self: *const TCPClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg, .signal);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Converts the TCP client configuration to a text header and appends it to the provided TextHeaders.
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

/// Structure for configuring a TCP server listener.
pub const TCPServerConfigurator = struct {
    addrbuf: [256]u8 = undefined,
    port: ?u16 = null,

    /// Initializes a TCP server configurator with an optional IP address and port.
    /// Defaults to an empty IP (listen on all interfaces) and DefaultPort if not provided.
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

    /// Prepares a message with TCP server configuration for a Welcome request.
    pub fn prepareRequest(self: *const TCPServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg, .request);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Prepares a message with TCP server configuration for a Welcome signal.
    pub fn prepareSignal(self: *const TCPServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg, .signal);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Converts the TCP server configuration to a text header and appends it to the provided TextHeaders.
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

/// Structure for configuring a UDS client connection.
pub const UDSClientConfigurator = struct {
    addrbuf: [108]u8 = undefined,

    /// Initializes a UDS client configurator with a file path for the Unix Domain Socket.
    pub fn init(path: []const u8) UDSClientConfigurator {
        var ret: UDSClientConfigurator = .{};
        ret.toAddrBuf(path);
        return ret;
    }

    /// Prepares a message with UDS client configuration for a Hello request.
    pub fn prepareRequest(self: *const UDSClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg, .request);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Prepares a message with UDS client configuration for a Hello signal.
    pub fn prepareSignal(self: *const UDSClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg, .signal);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Converts the UDS client configuration to a text header and appends it to the provided TextHeaders.
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

/// Structure for configuring a UDS server listener.
pub const UDSServerConfigurator = struct {
    addrbuf: [108]u8 = undefined,

    /// Initializes a UDS server configurator with a file path for the Unix Domain Socket.
    pub fn init(path: []const u8) UDSServerConfigurator {
        var ret: UDSServerConfigurator = .{};
        ret.toAddrBuf(path);
        return ret;
    }

    /// Prepares a message with UDS server configuration for a Welcome request.
    pub fn prepareRequest(self: *const UDSServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg, .request);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Prepares a message with UDS server configuration for a Welcome signal.
    pub fn prepareSignal(self: *const UDSServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg, .signal);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Converts the UDS server configuration to a text header and appends it to the provided TextHeaders.
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

/// Structure representing an invalid configurator that always returns an error.
pub const WrongConfigurator = struct {
    /// Returns an error when attempting to prepare request, indicating an invalid configurator.
    pub fn prepareRequest(self: *const WrongConfigurator, msg: *Message) AmpeError!void {
        _ = self;
        _ = msg;
        return AmpeError.WrongConfiguration;
    }

    /// Returns an error when attempting to prepare signal, indicating an invalid configurator.
    pub fn prepareSignal(self: *const WrongConfigurator, msg: *Message) AmpeError!void {
        _ = self;
        _ = msg;
        return AmpeError.WrongConfiguration;
    }
};

/// Tagged union representing different types of configurators.
pub const Configurator = union(enum) {
    tcp_server: TCPServerConfigurator,
    tcp_client: TCPClientConfigurator,
    uds_server: UDSServerConfigurator,
    uds_client: UDSClientConfigurator,
    wrong: WrongConfigurator,

    /// Prepares request with the appropriate configuration based on the active configurator type.
    pub fn prepareRequest(self: *const Configurator, msg: *Message) AmpeError!void {
        return switch (self.*) {
            inline else => |conf| try conf.prepareRequest(msg),
        };
    }

    /// Prepares signal with the appropriate configuration based on the active configurator type.
    pub fn prepareSignal(self: *const Configurator, msg: *Message) AmpeError!void {
        return switch (self.*) {
            inline else => |conf| try conf.prepareSignal(msg),
        };
    }

    /// Checks if two configurators are of the same type.
    pub fn eql(self: Configurator, other: Configurator) bool {
        return activeTag(self) == activeTag(other);
    }

    /// Creates a configurator from a message's text headers, parsing ConnectToHeader or ListenOnHeader.
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

    /// Parses a client configuration string into a Configurator (TCP or UDS client).
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

    /// Parses a server configuration string into a Configurator (TCP or UDS server).
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

/// Prepares a message for a server Welcome request/signal by setting the appropriate binary header fields.
inline fn prepareForServer(msg: *Message, role: message.MessageRole) void {
    msg.bhdr = .{};

    msg.bhdr.proto = .{
        .mtype = .welcome,
        .role = role,
    };
}

/// Prepares a message for a client Hello request/signal by setting the appropriate binary header fields.
inline fn prepareForClient(msg: *Message, role: message.MessageRole) void {
    msg.bhdr = .{};

    msg.bhdr.proto = .{
        .mtype = .hello,
        .role = role,
    };
}

/// Checks if a message represents the first server Welcome request.
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

/// Checks if a message represents the first client Hello request.
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

const tofu = @import("engine.zig");

pub const message = tofu.message;
pub const Message = message.Message;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeaders = message.TextHeaders;
pub const AmpeError = tofu.status.AmpeError;

const std = @import("std");
const activeTag = std.meta.activeTag;

// 2DO prepareRequest - replace with prepare +
