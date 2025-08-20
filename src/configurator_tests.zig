// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const Map = std.StringHashMap([]const u8);

test "base configurator test" {
    // const allocator = testing.allocator;

    var msg = allocMsg();

    defer msg.destroy();

    {
        // var params = Map.init(allocator);
        // defer params.deinit();

        var conf: Configurator = .{ .tcp_client = TCPClientConfigurator.init(null, null) };

        _ = try conf.prepareRequest(msg);

        const restored = Configurator.fromMessage(msg);

        try std.testing.expectEqual(true, conf.eql(restored));
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
    const msg: *Message = Message.create(std.testing.allocator) catch unreachable;
    return msg;
}

pub const engine = @import("engine.zig");
pub const MessageType = engine.MessageType;
pub const MessageMode = engine.MessageMode;
pub const OriginFlag = engine.OriginFlag;
pub const MoreMessagesFlag = engine.MoreMessagesFlag;
pub const ProtoFields = engine.ProtoFields;
pub const BinaryHeader = engine.BinaryHeader;
pub const TextHeader = engine.TextHeader;
pub const TextHeaderIterator = @import("message.zig").TextHeaderIterator;
pub const TextHeaders = engine.TextHeaders;
pub const Message = engine.Message;

const configurator = @import("configurator.zig");
const Configurator = configurator.Configurator;
const TCPClientConfigurator = configurator.TCPClientConfigurator;
const TCPServerConfigurator = configurator.TCPServerConfigurator;
const UDSClientConfigurator = configurator.UDSClientConfigurator;
const UDSServerConfigurator = configurator.UDSServerConfigurator;

const DefaultProto = configurator.DefaultProto;
const DefaultAddr = configurator.DefaultAddr;
const DefaultPort = configurator.DefaultPort;

const TCPProto = configurator.TCPProto;
const UDSProto = configurator.UDSProto;

pub const ConnectToHeader = configurator.ConnectToHeader;
pub const ListenOnHeader = configurator.ListenOnHeader;

const std = @import("std");
const testing = std.testing;
