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
    addr: ?[]const u8 = null,
    port: ?u16 = null,

    /// Initializes a TCP client configurator with an optional host/IP address and port.
    /// Defaults to DefaultAddr and DefaultPort if not provided.
    pub fn init(host_or_ip: ?[]const u8, port: ?u16) TCPClientConfigurator {
        var cnf: TCPClientConfigurator = .{};

        if (host_or_ip) |ad| {
            cnf.addr = ad;
        } else {
            cnf.addr = DefaultAddr;
        }

        if (port) |pr| {
            cnf.port = pr;
        } else {
            cnf.port = DefaultPort;
        }
        return cnf;
    }

    /// Prepares a message with TCP client configuration for a Hello request.
    pub fn prepareRequest(self: *const TCPClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Converts the TCP client configuration to a text header and appends it to the provided TextHeaders.
    pub fn toConfiguration(self: *const TCPClientConfigurator, config: *TextHeaders) AmpeError!void {
        if ((self.addr == null) or (self.port == null)) {
            return AmpeError.WrongConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatTCP, .{ TCPProto, self.addr.?, self.port.? }) catch unreachable;
        config.append(ConnectToHeader, confHeader) catch {
            return AmpeError.WrongConfiguration;
        };
        return;
    }
};

/// Structure for configuring a TCP server listener.
pub const TCPServerConfigurator = struct {
    ip: ?[]const u8 = null,
    port: ?u16 = null,

    /// Initializes a TCP server configurator with an optional IP address and port.
    /// Defaults to an empty IP (listen on all interfaces) and DefaultPort if not provided.
    pub fn init(ip: ?[]const u8, port: ?u16) TCPServerConfigurator {
        var cnf: TCPServerConfigurator = .{};

        if (ip) |ipval| {
            cnf.ip = ipval;
        } else {
            cnf.ip = "";
        }
        if (port) |pr| {
            cnf.port = pr;
        } else {
            cnf.port = DefaultPort;
        }
        return cnf;
    }

    /// Prepares a message with TCP server configuration for a Welcome request.
    pub fn prepareRequest(self: *const TCPServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Converts the TCP server configuration to a text header and appends it to the provided TextHeaders.
    pub fn toConfiguration(self: *const TCPServerConfigurator, config: *TextHeaders) AmpeError!void {
        if ((self.ip == null) or (self.port == null)) {
            return AmpeError.WrongConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatTCP, .{ TCPProto, self.ip.?, self.port.? }) catch unreachable;
        config.append(ListenOnHeader, confHeader) catch {
            return AmpeError.WrongConfiguration;
        };
        return;
    }
};

/// Structure for configuring a UDS client connection.
pub const UDSClientConfigurator = struct {
    path: []const u8 = undefined,

    /// Initializes a UDS client configurator with a file path for the Unix Domain Socket.
    pub fn init(path: []const u8) UDSClientConfigurator {
        return .{
            .path = path,
        };
    }

    /// Prepares a message with UDS client configuration for a Hello request.
    pub fn prepareRequest(self: *const UDSClientConfigurator, msg: *Message) AmpeError!void {
        prepareForClient(msg);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Converts the UDS client configuration to a text header and appends it to the provided TextHeaders.
    pub fn toConfiguration(self: *const UDSClientConfigurator, config: *TextHeaders) AmpeError!void {
        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatUDS, .{
            UDSProto,
            self.path,
        }) catch unreachable;
        config.append(ConnectToHeader, confHeader) catch {
            return AmpeError.WrongConfiguration;
        };
        return;
    }
};

/// Structure for configuring a UDS server listener.
pub const UDSServerConfigurator = struct {
    path: []const u8 = undefined,

    /// Initializes a UDS server configurator with a file path for the Unix Domain Socket.
    pub fn init(path: []const u8) UDSServerConfigurator {
        return .{
            .path = path,
        };
    }

    /// Prepares a message with UDS server configuration for a Welcome request.
    pub fn prepareRequest(self: *const UDSServerConfigurator, msg: *Message) AmpeError!void {
        prepareForServer(msg);
        try self.toConfiguration(&msg.*.thdrs);
    }

    /// Converts the UDS server configuration to a text header and appends it to the provided TextHeaders.
    pub fn toConfiguration(self: *const UDSServerConfigurator, config: *TextHeaders) AmpeError!void {
        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatUDS, .{ UDSProto, self.path }) catch unreachable;
        config.append(ListenOnHeader, confHeader) catch {
            return AmpeError.WrongConfiguration;
        };
        return;
    }
};

/// Structure representing an invalid configurator that always returns an error.
pub const WrongConfigurator = struct {
    /// Returns an error when attempting to prepare a request, indicating an invalid configurator.
    pub fn prepareRequest(self: *const WrongConfigurator, msg: *Message) AmpeError!void {
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

    /// Prepares a message with the appropriate configuration based on the active configurator type.
    pub fn prepareRequest(self: *const Configurator, msg: *Message) AmpeError!void {
        return switch (self.*) {
            inline else => |conf| try conf.prepareRequest(msg),
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
};

/// Prepares a message for a server Welcome request by setting the appropriate binary header fields.
inline fn prepareForServer(msg: *Message) void {
    msg.bhdr = .{};

    msg.bhdr.proto = .{
        .mtype = .welcome,
        .mode = .request,
    };
}

/// Prepares a message for a client Hello request by setting the appropriate binary header fields.
inline fn prepareForClient(msg: *Message) void {
    msg.bhdr = .{};

    msg.bhdr.proto = .{
        .mtype = .hello,
        .mode = .request,
    };
}

/// Checks if a message represents the first server Welcome request.
inline fn isFirstServerRequest(msg: *Message) bool {
    if (msg.bhdr.proto.mtype != .welcome) {
        return false;
    }
    if (msg.bhdr.proto.mode != .request) {
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
    if (msg.bhdr.proto.mode != .request) {
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
