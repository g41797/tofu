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

    pub fn init(cnf: *TCPClientConfigurator, host_or_ip: ?[]const u8, port: ?u16) void {
        cnf.* = .{};
        if (host_or_ip) |ad| {
            cnf.addr = ad;
        }
        if (port) |pr| {
            cnf.port = pr;
        }
        return;
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

    pub fn init(ip: ?[]const u8, port: ?u16) TCPServerConfigurator {
        const result: TCPServerConfigurator = .{};
        if (ip) |ipval| {
            result.ip = ipval;
        }
        if (port) |pr| {
            result.port = pr;
        }
        return result;
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

pub const UDSConfigurator = struct {
    port: ?u16 = DefaultPort,

    pub fn init(port: ?u16) UDSConfigurator {
        const result: UDSConfigurator = .{};
        if (port) |pr| {
            result.port = pr;
        }
        return result;
    }

    pub fn toConfiguration(self: UDSConfigurator, config: *TextHeaders) !void {
        try config.append(ProtoHeader, UDSProto);

        // Max digits for u16 is 5 (65535) + null terminator
        var buffer: [6]u8 = undefined;
        const portText = std.fmt.bufPrint(&buffer, "{}", .{self.port.?}) catch unreachable;
        try config.append(PortHeader, portText);
        return;
    }
};

pub const Configurator = union(enum) {
    tcpClient: TCPClientConfigurator,
    tcpServer: TCPServerConfigurator,
    udsClientServer: UDSConfigurator,

    pub fn toConfiguration(self: Configurator, config: *TextHeaders) !void {
        switch (self) {
            inline else => |impl| return impl.toConfiguration(config),
        }
    }
};

const LazyPTOP = 7099;

pub const protocol = @import("protocol.zig");
pub const TextHeaders = protocol.TextHeaders;

const std = @import("std");
