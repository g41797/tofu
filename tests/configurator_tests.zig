// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("configurator_tests\r\n", .{});
}

const Map = std.StringHashMap([]const u8);

test "base configurator test" {
    // const allocator = testing.allocator;

    var msg = allocMsg();

    defer msg.destroy();

    {
        // var params = Map.init(allocator);
        // defer params.deinit();

        var conf: Configurator = .{ .tcp_client = TCPClientConfigurator.init(null, null) };

        _ = try conf.configure(msg);

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
pub const message = @import("tofu").message;
pub const MessageType = message.MessageType;
pub const MessageRole = message.MessageRole;
pub const OriginFlag = message.OriginFlag;
pub const MoreMessagesFlag = message.MoreMessagesFlag;
pub const ProtoFields = message.ProtoFields;
pub const BinaryHeader = message.BinaryHeader;
pub const TextHeader = message.TextHeader;
pub const TextHeaderIterator = message.TextHeaderIterator;
pub const TextHeaders = message.TextHeaders;
pub const Message = message.Message;

const configurator = @import("tofu").configurator;
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
