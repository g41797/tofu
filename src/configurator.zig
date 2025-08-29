// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

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

// For the client - Part of Hello headers
// "~connect_to: proto|addr or empty|port
// "~connect_to: tcp|127.0.0.1|7099
// "~connect_to: uds|/tmp/7099.port
pub const ConnectToHeader = "~connect_to";

// For the server - Part of Welcome headers, actually only this one is required
// "~listen_on: proto|addr or empty|port
// "~listen_on: tcp|127.0.0.1|7099  - on loopback only
// "~listen_on: tcp||7099           - on every host IP address
// "~listen_on: uds|/tmp/7099.port
pub const ListenOnHeader = "~listen_on";

pub const TCPClientConfigurator = struct {
    addr: ?[]const u8 = null,
    port: ?u16 = null,

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

    pub fn prepareRequest(self: *const TCPClientConfigurator, msg: *Message) !void {
        prepareForClient(msg);

        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *const TCPClientConfigurator, config: *TextHeaders) !void {
        if ((self.addr == null) or (self.port == null)) {
            return error.WrongInitialConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatTCP, .{ TCPProto, self.addr.?, self.port.? }) catch unreachable;
        try config.append(ConnectToHeader, confHeader);
        return;
    }
};

pub const TCPServerConfigurator = struct {
    ip: ?[]const u8 = null,
    port: ?u16 = null,

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

    pub fn prepareRequest(self: *const TCPServerConfigurator, msg: *Message) !void {
        prepareForServer(msg);

        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *const TCPServerConfigurator, config: *TextHeaders) !void {
        if ((self.ip == null) or (self.port == null)) {
            return error.WrongInitialConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatTCP, .{ TCPProto, self.ip.?, self.port.? }) catch unreachable;
        try config.append(ListenOnHeader, confHeader);
        return;
    }
};

pub const UDSClientConfigurator = struct {
    path: []const u8 = undefined,

    pub fn init(path: []const u8) UDSClientConfigurator {
        return .{
            .path = path,
        };
    }

    pub fn prepareRequest(self: *const UDSClientConfigurator, msg: *Message) !void {
        prepareForClient(msg);

        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *const UDSClientConfigurator, config: *TextHeaders) !void {
        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatUDS, .{
            UDSProto,
            self.path,
        }) catch unreachable;
        try config.append(ConnectToHeader, confHeader);
        return;
    }
};

pub const UDSServerConfigurator = struct {
    path: []const u8 = undefined,

    pub fn init(path: []const u8) UDSServerConfigurator {
        return .{
            .path = path,
        };
    }

    pub fn prepareRequest(self: *const UDSServerConfigurator, msg: *Message) !void {
        prepareForServer(msg);

        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *const UDSServerConfigurator, config: *TextHeaders) !void {
        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormatUDS, .{ UDSProto, self.path }) catch unreachable;
        try config.append(ListenOnHeader, confHeader);
        return;
    }
};

pub const WrongConfigurator = struct {
    pub fn prepareRequest(self: *const WrongConfigurator, msg: *Message) !void {
        _ = self;
        _ = msg;
        return error.WrongConfigurator;
    }
};

pub const Configurator = union(enum) {
    tcp_server: TCPServerConfigurator,
    tcp_client: TCPClientConfigurator,
    uds_server: UDSServerConfigurator,
    uds_client: UDSClientConfigurator,
    wrong: WrongConfigurator,

    pub fn prepareRequest(self: *const Configurator, msg: *Message) !void {
        return switch (self.*) {
            inline else => |conf| try conf.prepareRequest(msg),
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
};

inline fn prepareForServer(msg: *Message) void {
    msg.bhdr = .{};

    msg.bhdr.proto = .{
        .mtype = .welcome,
        .mode = .request,
    };
}

inline fn prepareForClient(msg: *Message) void {
    msg.bhdr = .{};

    msg.bhdr.proto = .{
        .mtype = .hello,
        .mode = .request,
    };
}

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

const std = @import("std");
const activeTag = std.meta.activeTag;
