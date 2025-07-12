// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const ProtoHeader = "~proto";
pub const AddrHeader = "~addr";
pub const PortHeader = "~port";

pub const DefaultAddr = "127.0.0.1";
pub const DefaultPort = LazyPTOP;

pub const TCPConfigurator = struct {
    addr: ?[]const u8 = DefaultAddr,
    port: ?u16 = DefaultPort,

    pub fn init(host_or_ip: ?[]const u8, port: ?u16) TCPConfigurator {
        const result = .{};
        if (host_or_ip) |ad| {
            result.addr = ad;
        }
        if (port) |pr| {
            result.port = pr;
        }
        return result;
    }

    pub fn toConfiguration(self: TCPConfigurator, config: *TextHeaders) !void {
        try config.append(ProtoHeader, TCPProto);
        try config.append(AddrHeader, self.addr);

        // Max digits for u16 is 5 (65535) + null terminator
        var buffer: [6]u8 = undefined;
        const portText = std.fmt.bufPrint(&buffer, "{}", .{self.port}) catch unreachable;
        try config.append(PortHeader, portText);
        return;
    }
};

pub const UDSConfigurator = struct {
    port: ?u16 = DefaultPort,

    pub fn init(port: ?u16) UDSConfigurator {
        const result = .{};
        if (port) |pr| {
            result.port = pr;
        }
        return result;
    }

    pub fn toConfiguration(self: TCPConfigurator, config: *TextHeaders) !void {
        try config.append(ProtoHeader, UDSProto);

        // Max digits for u16 is 5 (65535) + null terminator
        var buffer: [6]u8 = undefined;
        const portText = std.fmt.bufPrint(&buffer, "{}", .{self.port}) catch unreachable;
        try config.append(PortHeader, portText);
        return;
    }
};

pub const Configurator = union(enum) {
    tcp: TCPConfigurator,
    uds: UDSConfigurator,

    pub fn toConfiguration(self: Configurator, config: *TextHeaders) !void {
        switch (self) {
            .null => {}, // do nothing
            inline else => |impl| return impl.toConfiguration(config),
        }
    }
};

const TCPProto = "tcp";
const UDSProto = "uds";
const LazyPTOP = 7099;

pub const protocol = @import("protocol.zig");
pub const TextHeaders = protocol.TextHeaders;

const std = @import("std");
