// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const localIP = "127.0.0.1";
const SEC_TIMEOUT_MS = 1_000;
const INFINITE_TIMEOUT_MS = -1;

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

    try testing.expect(trgrs.accept == .on);

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

    var tup: Notifier.TempUdsPath = .{};
    const udsPath = try tup.buildPath(gpa);

    var cnfr: Configurator = .{
        .uds_server = UDSServerConfigurator.init(udsPath),
    };

    var listener = try create_listener(&cnfr);

    defer listener.deinit();

    // const c_array_ptr: [*:0]const u8 = @ptrCast(&listener.accept.skt.address.un.path);
    // const length = std.mem.len(c_array_ptr);
    // const zig_slice: []const u8 = c_array_ptr[0..length];

    var clcnfr: Configurator = .{
        .uds_client = UDSClientConfigurator.init(udsPath),
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

    const utrg = sockets.UnpackedTriggers.fromTriggers(trgrs);

    const onTrigger: u8 = switch (cnfr.*) {
        .tcp_client => utrg.connect,
        .uds_client => utrg.send,
        else => unreachable,
    };

    try testing.expect(onTrigger == 1);

    return tskt;
}

test "exchanger waitConnectClient" {
    const srvcnf: Configurator = .{
        .tcp_server = TCPServerConfigurator.init(localIP, configurator.DefaultPort),
    };

    const clcnf: Configurator = .{
        .tcp_client = TCPClientConfigurator.init(localIP, configurator.DefaultPort),
    };

    var exc: Exchanger = try Exchanger.init(gpa, srvcnf, clcnf);
    defer exc.deinit();

    try exc.startListen();

    try exc.startClient();

    const trgrs = try exc.waitConnectClient();

    const utrg = sockets.UnpackedTriggers.fromTriggers(trgrs);

    const onTrigger: u8 = switch (exc.clcnf) {
        .tcp_client => utrg.connect,
        .uds_client => utrg.send,
        else => unreachable,
    };

    _ = onTrigger;

    return;
}

pub const Exchanger = struct {
    allocator: Allocator = undefined,
    pool: Pool = undefined,

    srvcnf: Configurator = undefined,
    clcnf: Configurator = undefined,

    lst: ?TC = null,
    lstCN: CN = 1,

    srv: ?TC = null,
    srvCN: CN = 2,

    cl: ?TC = null,
    clCN: CN = 3,

    sendMsg: ?*Message = null,
    recvMsg: ?*Message = null,

    tcm: ?TCM = null,
    plr: ?Poller = null,

    pub fn init(allocator: Allocator, srvcnf: Configurator, clcnf: Configurator) !Exchanger {
        var ret: Exchanger = .{
            .allocator = allocator,
            .pool = try Pool.init(allocator, null),
            .srvcnf = srvcnf,
            .clcnf = clcnf,
        };

        errdefer ret.deinit();

        var tcm = TCM.init(allocator);
        errdefer tcm.deinit();
        try tcm.ensureTotalCapacity(256);
        ret.tcm = tcm;

        const pll: Poller = .{
            .poll = try Poll.init(allocator),
        };

        ret.plr = pll;

        return ret;
    }

    pub fn startListen(exc: *Exchanger) !void {
        exc.lst = .{
            .exp = .{},
            .act = .{},
            .tskt = try create_listener(&exc.srvcnf),
            .acn = .{
                .chn = exc.lstCN,
                .mid = exc.lstCN,
                .ctx = null,
            },
        };
        errdefer exc.lst.?.tskt.deinit();

        try exc.tcm.?.put(exc.lstCN, exc.lst.?);

        return;
    }

    pub fn startClient(exc: *Exchanger) !void {
        exc.cl = .{
            .exp = .{},
            .act = .{},
            .tskt = try create_client(&exc.clcnf, &exc.pool),
            .acn = .{
                .chn = exc.clCN,
                .mid = exc.clCN,
                .ctx = null,
            },
        };
        errdefer exc.cl.?.tskt.deinit();

        try exc.tcm.?.put(exc.clCN, exc.cl.?);

        return;
    }

    pub fn waitConnectClient(exc: *Exchanger) !sockets.Triggers {
        const it = Distributor.Iterator.init(&exc.tcm.?);

        var trgrs: sockets.Triggers = .{};

        for (0..10) |_| {
            trgrs = try exc.plr.?.waitTriggers(it, SEC_TIMEOUT_MS);

            if ((trgrs.timeout == .off) or (trgrs.err == .on)) {
                break;
            }
        }
        return trgrs;
    }

    pub fn deinit(exc: *Exchanger) void {
        if (exc.lst != null) {
            exc.lst.?.tskt.deinit();
            exc.lst = null;
        }
        if (exc.srv != null) {
            exc.srv.?.tskt.deinit();
            exc.srv = null;
        }
        if (exc.cl != null) {
            exc.cl.?.tskt.deinit();
            exc.cl = null;
        }
        if (exc.recvMsg) |m| {
            m.destroy();
            exc.recvMsg = null;
        }
        if (exc.tcm != null) {
            exc.tcm.?.deinit();
            exc.tcm = null;
        }
        if (exc.plr != null) {
            exc.plr.?.deinit();
            exc.plr = null;
        }

        exc.pool.close();
    }
};

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
const CN = message.ChannelNumber;

const Distributor = @import("Distributor.zig");
const TCM = Distributor.TriggeredChannelsMap;
const TC = Distributor.TriggeredChannel;

const poller = @import("poller.zig");
const Poller = poller.Poller;
const Poll = poller.Poll;

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
const ActiveChannel = channels.ActiveChannel;
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
