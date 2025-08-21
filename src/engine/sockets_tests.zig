// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const localIP = "127.0.0.1";

test "create TCP listener" {
    var cnfr: Configurator = .{
        .tcp_server = TCPServerConfigurator.init(localIP, configurator.DefaultPort),
    };

    var listener = try create_listener(&cnfr);

    defer listener.deinit();
}

test "create UDS listener" {
    var cnfr: Configurator = .{
        .uds_server = UDSServerConfigurator.init(""),
    };

    var listener = try create_listener(&cnfr);

    defer listener.deinit();
}

fn create_listener(cnfr: *Configurator) !sockets.TriggeredSkt {
    var wlcm: *Message = try Message.create(gpa);
    defer wlcm.destroy();

    try cnfr.prepareRequest(wlcm);

    var sc: sockets.SocketCreator = sockets.SocketCreator.init(gpa);

    var tskt: sockets.TriggeredSkt = .{
        .accept = try sockets.AcceptSkt.init(wlcm, &sc),
    };
    errdefer tskt.deinit();

    const trgrs = tskt.triggers();

    try testing.expect(trgrs != null);
    try testing.expect(trgrs.?.accept == .on);

    return tskt;
}

test "create TCP client" {
    var pool = try Pool.init(gpa, null);
    defer pool.close();

    var cnfr: Configurator = .{
        .tcp_server = TCPServerConfigurator.init(localIP, configurator.DefaultPort),
    };

    var listener = try create_listener(&cnfr);

    defer listener.deinit();

    var clcnfr: Configurator = .{
        .tcp_client = TCPClientConfigurator.init(null, null),
    };

    var client = try create_client(&clcnfr, &pool);

    defer client.deinit();
}

test "create UDS client" {
    var pool = try Pool.init(gpa, null);
    defer pool.close();

    var cnfr: Configurator = .{
        .uds_server = UDSServerConfigurator.init(""),
    };

    var listener = try create_listener(&cnfr);

    defer listener.deinit();

    const c_array_ptr: [*:0]const u8 = @ptrCast(&listener.accept.skt.address.un.path);
    const length = std.mem.len(c_array_ptr);
    const zig_slice: []const u8 = c_array_ptr[0..length];

    var clcnfr: Configurator = .{
        .uds_client = UDSClientConfigurator.init(zig_slice),
    };

    var client = try create_client(&clcnfr, &pool);

    defer client.deinit();
}

fn create_client(cnfr: *Configurator, pool: *Pool) !sockets.TriggeredSkt {
    var hello: *Message = try Message.create(gpa);

    cnfr.prepareRequest(hello) catch |err| {
        hello.destroy();
        return err;
    };

    var sc: sockets.SocketCreator = sockets.SocketCreator.init(gpa);

    var tskt: sockets.TriggeredSkt = .{
        .io = try sockets.IoSkt.initClientSide(pool, hello, &sc),
    };
    errdefer tskt.deinit();

    const trgrs = tskt.triggers();

    try testing.expect(trgrs != null);

    var utrg = sockets.UnpackedTriggers.fromTriggers(trgrs.?);

    utrg = .{};

    try testing.expect((trgrs.?.connect == .on) or (trgrs.?.send == .on));

    return tskt;
}

const sockets = @import("sockets.zig");

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageMode = message.MessageMode;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = message.TextHeaderIterator;
const TextHeaders = message.TextHeaders;
const Message = message.Message;
const MessageQueue = message.MessageQueue;

const MessageID = message.MessageID;
const VC = message.ValidCombination;

const Distributor = @import("Distributor.zig");

const configurator = @import("../configurator.zig");
const Configurator = configurator.Configurator;
const TCPServerConfigurator = configurator.TCPServerConfigurator;
const TCPClientConfigurator = configurator.TCPClientConfigurator;
const UDSServerConfigurator = configurator.UDSServerConfigurator;
const UDSClientConfigurator = configurator.UDSClientConfigurator;
const WrongConfigurator = configurator.WrongConfigurator;

const status = @import("../status.zig");
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const Pool = @import("Pool.zig");
const Notifier = @import("Notifier.zig");
const Notification = Notifier.Notification;

const channels = @import("channels.zig");
const ActiveChannels = channels.ActiveChannels;

pub const Appendable = @import("nats").Appendable;

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const gpa = std.testing.allocator;
const Mutex = std.Thread.Mutex;
const Socket = std.posix.socket_t;
