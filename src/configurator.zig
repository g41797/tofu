// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const TCPProto = "tcp";
pub const UDSProto = "uds";

pub const DefaultProto = TCPProto;
pub const DefaultAddr = "127.0.0.1";
pub const DefaultPort = LazyPTOP;

const ConfigPrintFormat = "{s}|{s}|{d}";

// For the client - Part of Hello headers
// "~connect_to: proto|addr or empty|port
// "~connect_to: tcp|127.0.0.1|7099
// "~connect_to: uds||7099
pub const ConnectToHeader = "~connect_to";

// For the server - Part of Welcome headers
// "~listen_on: proto|addr or empty|port
// "~listen_on: tcp|127.0.0.1|7099  - on loopback only
// "~listen_on: tcp||7099           - on every host IP address
// "~listen_on: uds||7099

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

    pub fn prepareRequest(self: *TCPClientConfigurator, msg: *Message) !void {
        prepareForClient(msg);

        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *TCPClientConfigurator, config: *TextHeaders) !void {
        if ((self.addr == null) or (self.port == null)) {
            return error.WrongInitialConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormat, .{ TCPProto, self.addr.?, self.port.? }) catch unreachable;
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

    pub fn prepareRequest(self: *TCPServerConfigurator, msg: *Message) !void {
        prepareForServer(msg);

        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *TCPServerConfigurator, config: *TextHeaders) !void {
        if ((self.ip == null) or (self.port == null)) {
            return error.WrongInitialConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormat, .{ TCPProto, self.ip.?, self.port.? }) catch unreachable;
        try config.append(ListenOnHeader, confHeader);
        return;
    }
};

pub const UDSClientConfigurator = struct {
    port: ?u16 = null,

    pub fn init(port: ?u16) UDSClientConfigurator {
        var cnf: UDSClientConfigurator = .{};
        if (port) |pr| {
            cnf.port = pr;
        } else {
            cnf.port = DefaultPort;
        }
        return;
    }

    pub fn prepareRequest(self: *UDSClientConfigurator, msg: *Message) !void {
        prepareForClient(msg);

        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *UDSClientConfigurator, config: *TextHeaders) !void {
        if (self.port == null) {
            return error.WrongInitialConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormat, .{ UDSProto, "", self.port.? }) catch unreachable;
        try config.append(ConnectToHeader, confHeader);
        return;
    }
};

pub const UDSServerConfigurator = struct {
    port: ?u16 = null,

    pub fn init(port: ?u16) UDSServerConfigurator {
        var cnf: UDSServerConfigurator = .{};
        if (port) |pr| {
            cnf.port = pr;
        } else {
            cnf.port = DefaultPort;
        }
        return;
    }

    pub fn prepareRequest(self: *UDSServerConfigurator, msg: *Message) !void {
        prepareForServer(msg);

        try self.toConfiguration(&msg.*.thdrs);
    }

    pub fn toConfiguration(self: *UDSServerConfigurator, config: *TextHeaders) !void {
        if (self.port == null) {
            return error.WrongInitialConfiguration;
        }

        var buffer: [256]u8 = undefined;
        const confHeader = std.fmt.bufPrint(&buffer, ConfigPrintFormat, .{ UDSProto, "", self.port.? }) catch unreachable;
        try config.append(ListenOnHeader, confHeader);
        return;
    }
};

pub const WrongConfigurator = struct {
    pub fn prepareRequest(self: *WrongConfigurator, msg: *Message) !void {
        _ = self;
        _ = msg;
        return error.WrongConfigurator;
    }
};

inline fn prepareForServer(msg: *Message) void {
    msg.bhdr.proto.mtype = .welcome;
    msg.bhdr.proto.mode = .request;
    msg.bhdr.proto.more = .last;
    msg.bhdr.proto.origin = .application;

    msg.bhdr.channel_number = 0;
    msg.bhdr.message_id = 0;
    msg.bhdr.status = 0;
    msg.bhdr.text_headers_len = 0; // Protocol will use actual headers length
}

inline fn prepareForClient(msg: *Message) void {
    msg.bhdr.proto.mtype = .hello;
    msg.bhdr.proto.mode = .request;
    msg.bhdr.proto.more = .last;
    msg.bhdr.proto.origin = .application;

    msg.bhdr.channel_number = 0;
    msg.bhdr.message_id = 0;
    msg.bhdr.status = 0;
    msg.bhdr.text_headers_len = 0; // Protocol will use actual headers length
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
pub const MessageType = message.MessageType;
pub const MessageMode = message.MessageMode;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = @import("TextHeaderIterator.zig");
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;

const std = @import("std");
