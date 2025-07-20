// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const Map = std.StringHashMap([]const u8);

test "base configurator test" {
    const allocator = testing.allocator;

    var msg = allocMsg();

    defer msg.destroy();

    {
        var params = Map.init(allocator);
        defer params.deinit();

        var tcpClConf: TCPClientConfigurator = .{};
        tcpClConf.init(null, null);

        const cnfr: Configurator = .{
            .tcpClient = tcpClConf,
        };

        _ = try cnfr.prepareRequest(msg);

        fillMap(&params, &msg.thdrs) catch unreachable;

        try testing.expectEqual(0, params.count());

        var conftr: Configurator = @unionInit(Configurator, "wrong", .{});
        _ = try conftr.updateFrom(msg);
        try testing.expectEqual(true, conftr == .tcpClient);
    }
}

fn fillMap(map: *Map, th: *TextHeaders) !void {
    var it = th.hiter();

    var next = it.next();
    while (next != null) {
        _ = try map.put(next.?.name, next.?.value);
        next = it.next();
    }
    return;
}

fn allocMsg() *Message {
    var msg: *Message = testing.allocator.create(Message) catch unreachable;
    msg.* = .{};
    msg.bhdr = .{};
    msg.thdrs.init(testing.allocator, 64) catch unreachable;
    msg.body.init(testing.allocator, 256, null) catch unreachable;
    return msg;
}

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

const configurator = @import("configurator.zig");
const Configurator = configurator.Configurator;
const TCPClientConfigurator = configurator.TCPClientConfigurator;
const TCPServerConfigurator = configurator.TCPServerConfigurator;
const UDSClientConfigurator = configurator.UDSClientConfigurator;
const UDSServerConfigurator = configurator.UDSServerConfigurator;

const ProtoHeader = configurator.ProtoHeader;
const AddrHeader = configurator.AddrHeader;
const IPHeader = configurator.IPHeader;
const PortHeader = configurator.PortHeader;

const DefaultProto = configurator.DefaultProto;
const DefaultAddr = configurator.DefaultAddr;
const DefaultPort = configurator.DefaultPort;

const TCPProto = configurator.TCPProto;
const UDSProto = configurator.UDSProto;

const std = @import("std");
const testing = std.testing;
