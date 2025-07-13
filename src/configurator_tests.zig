// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const Map = std.StringHashMap([]const u8);

test "base configurator test" {
    const allocator = testing.allocator;

    var th: TextHeaders = .{};
    _ = try th.init(allocator, 16);
    defer th.deinit();

    {
        th.reset();

        var params = Map.init(allocator);
        defer params.deinit();

        var tcpClConf: TCPClientConfigurator = .{};
        tcpClConf.init(null, null);

        const cnfr: Configurator = .{
            .tcpClient = tcpClConf,
        };

        _ = try cnfr.toConfiguration(&th);

        fillMap(&params, &th) catch unreachable;

        try testing.expectEqual(0, params.count());
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

const protocol = @import("protocol.zig");
pub const TextHeader = protocol.TextHeader;
pub const TextHeaders = protocol.TextHeaders;
pub const TextHeaderIterator = @import("TextHeaderIterator.zig");

const configurator = @import("configurator.zig");
const Configurator = configurator.Configurator;
const TCPClientConfigurator = configurator.TCPClientConfigurator;
const TCPServerConfigurator = configurator.TCPServerConfigurator;
const UDSConfigurator = configurator.UDSConfigurator;

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
