// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const ProtoHeader = "~proto";
pub const AddrHeader = "~addr";
pub const IPHeader = "~ip";
pub const PortHeader = "~port";

pub const DefaultProto = TCPProto;
pub const DefaultAddr = "127.0.0.1";
pub const DefaultPort = LazyPTOP;

pub const TCPProto = "tcp";
pub const UDSProto = "uds";

pub const TCPClientConfigurator = struct {
    addr: ?[]const u8 = null,
    port: ?u16 = null,

    inline fn reset(cnf: *TCPClientConfigurator) void {
        cnf.* = .{};
    }

    pub fn init(cnf: *TCPClientConfigurator, host_or_ip: ?[]const u8, port: ?u16) void {
        cnf.reset();
        if (host_or_ip) |ad| {
            cnf.addr = ad;
        }
        if (port) |pr| {
            cnf.port = pr;
        }
        return;
    }

    pub fn prepareRequest(self: TCPClientConfigurator, msg: *Message) !void {
        try self.toConfiguration(&msg.*.thdrs);

        prepareForClient(msg);
    }

    pub fn toConfiguration(self: TCPClientConfigurator, config: *TextHeaders) !void {
        if ((self.addr == null) and (self.port == null)) {
            return;
        }
        try config.append(ProtoHeader, TCPProto);

        if (self.addr) |addrv| {
            try config.append(AddrHeader, addrv);
        } else {
            try config.append(AddrHeader, DefaultAddr);
        }

        var port: u16 = DefaultPort;
        if (self.port != null) {
            port = self.port.?;
        }

        // Max digits for u16 is 5 (65535) + null terminator
        var buffer: [6]u8 = undefined;
        const portText = std.fmt.bufPrint(&buffer, "{}", .{port}) catch unreachable;
        try config.append(PortHeader, portText);
        return;
    }
};

pub const TCPServerConfigurator = struct {
    ip: ?[]const u8 = null,
    port: ?u16 = null,

    inline fn reset(cnf: *TCPServerConfigurator) void {
        cnf.* = .{};
    }

    pub fn init(cnf: *TCPServerConfigurator, ip: ?[]const u8, port: ?u16) void {
        cnf.reset();
        if (ip) |ipval| {
            cnf.ip = ipval;
        }
        if (port) |pr| {
            cnf.port = pr;
        }
        return;
    }

    pub fn prepareRequest(self: TCPServerConfigurator, msg: *Message) !void {
        try self.toConfiguration(&msg.*.thdrs);

        prepareForServer(msg);
    }

    pub fn toConfiguration(self: TCPServerConfigurator, config: *TextHeaders) !void {
        if ((self.ip == null) and (self.port == null)) {
            return;
        }
        try config.append(ProtoHeader, TCPProto);

        if (self.ip) |ipv| {
            try config.append(AddrHeader, ipv);
        }

        var port: u16 = DefaultPort;
        if (self.port != null) {
            port = self.port.?;
        }

        // Max digits for u16 is 5 (65535) + null terminator
        var buffer: [6]u8 = undefined;
        const portText = std.fmt.bufPrint(&buffer, "{}", .{port}) catch unreachable;
        try config.append(PortHeader, portText);
        return;
    }
};

pub const UDSClientConfigurator = struct {
    port: ?u16 = null,

    inline fn reset(cnf: *UDSClientConfigurator) void {
        cnf.* = .{};
    }

    pub fn init(cnf: *UDSClientConfigurator, port: ?u16) void {
        cnf.reset();
        if (port) |pr| {
            cnf.port = pr;
        }
        return;
    }

    pub fn prepareRequest(self: UDSClientConfigurator, msg: *Message) !void {
        try self.toConfiguration(&msg.*.thdrs);

        prepareForClient(msg);
    }

    pub fn toConfiguration(self: UDSClientConfigurator, config: *TextHeaders) !void {
        try config.append(ProtoHeader, UDSProto);

        var port: u16 = DefaultPort;
        if (self.port != null) {
            port = self.port.?;
        }

        // Max digits for u16 is 5 (65535) + null terminator
        var buffer: [6]u8 = undefined;
        const portText = std.fmt.bufPrint(&buffer, "{}", .{port}) catch unreachable;
        try config.append(PortHeader, portText);
        return;
    }
};

pub const UDSServerConfigurator = struct {
    port: ?u16 = null,

    inline fn reset(cnf: *UDSServerConfigurator) void {
        cnf.* = .{};
    }

    pub fn init(cnf: *UDSServerConfigurator, port: ?u16) void {
        cnf.reset();
        if (port) |pr| {
            cnf.port = pr;
        }
        return;
    }

    pub fn prepareRequest(self: UDSServerConfigurator, msg: *Message) !void {
        try self.toConfiguration(&msg.*.thdrs);

        prepareForServer(msg);
    }

    pub fn toConfiguration(self: UDSServerConfigurator, config: *TextHeaders) !void {
        try config.append(ProtoHeader, UDSProto);

        var port: u16 = DefaultPort;
        if (self.port != null) {
            port = self.port.?;
        }

        // Max digits for u16 is 5 (65535) + null terminator
        var buffer: [6]u8 = undefined;
        const portText = std.fmt.bufPrint(&buffer, "{}", .{port}) catch unreachable;
        try config.append(PortHeader, portText);
        return;
    }
};

pub const WrongConfigurator = struct {
    pub fn prepareRequest(self: WrongConfigurator, msg: *Message) !void {
        _ = self;
        _ = msg;
        return error.WrongConfigurator;
    }
};

pub const Configurator = union(enum) {
    tcpClient: TCPClientConfigurator,
    tcpServer: TCPServerConfigurator,
    udsClient: UDSClientConfigurator,
    udsServer: UDSServerConfigurator,
    wrong: WrongConfigurator,

    pub fn prepareRequest(self: Configurator, msg: *Message) !void {
        switch (self) {
            inline else => |impl| return impl.prepareRequest(msg),
        }
    }

    pub fn updateFrom(self: *Configurator, msg: *Message) !void {
        // var temp: Configurator = @unionInit(Configurator, "wrong", .{});
        _ = msg;
        const cnf: TCPClientConfigurator = .{};
        self.* = .{
            .tcpClient = cnf,
        };
        return;
    }
};

inline fn prepareForServer(msg: *Message) void {
    msg.bhdr.proto.type = .welcome;
    msg.bhdr.proto.mode = .request;
    msg.bhdr.proto.more = .last;
    msg.bhdr.proto.origin = .application;
}

inline fn prepareForClient(msg: *Message) void {
    msg.bhdr.proto.type = .hello;
    msg.bhdr.proto.mode = .request;
    msg.bhdr.proto.more = .last;
    msg.bhdr.proto.origin = .application;
}

inline fn isFirstServerRequest(msg: *Message) bool {
    if (msg.bhdr.proto.type != .welcome) {
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
    if (msg.bhdr.proto.type != .hello) {
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

pub const protocol = @import("protocol.zig");
pub const MessageType = protocol.MessageType;
pub const MessageMode = protocol.MessageMode;
pub const OriginFlag = protocol.OriginFlag;
pub const MoreMessagesFlag = protocol.MoreMessagesFlag;
pub const ProtoFields = protocol.ProtoFields;
pub const BinaryHeader = protocol.BinaryHeader;
pub const TextHeader = protocol.TextHeader;
pub const TextHeaderIterator = @import("TextHeaderIterator.zig");
pub const TextHeaders = protocol.TextHeaders;
pub const Message = protocol.Message;

const std = @import("std");
