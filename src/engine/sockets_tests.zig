// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

const localIP = "127.0.0.1";
const SEC_TIMEOUT_MS = 1_000;
const INFINITE_TIMEOUT_MS = -1;

// test "create TCP listener" {
//     var cnfr: Configurator = .{
//         .tcp_server = TCPServerConfigurator.init(localIP, configurator.DefaultPort),
//     };
//
//     var listener = try create_listener(&cnfr);
//
//     defer listener.deinit();
// }
//
// test "create UDS listener" {
//     var cnfr: Configurator = .{
//         .uds_server = UDSServerConfigurator.init(""),
//     };
//
//     var listener = try create_listener(&cnfr);
//
//     defer listener.deinit();
// }
//
// test "create TCP client" {
//     var pool = try Pool.init(gpa, null);
//     defer pool.close();
//
//     var cnfr: Configurator = .{
//         .tcp_server = TCPServerConfigurator.init(localIP, configurator.DefaultPort),
//     };
//
//     var listener = try create_listener(&cnfr);
//
//     defer listener.deinit();
//
//     var clcnfr: Configurator = .{
//         .tcp_client = TCPClientConfigurator.init(null, null),
//     };
//
//     var client = try create_client(&clcnfr, &pool);
//
//     defer client.deinit();
// }
//
// test "create UDS client" {
//     var pool = try Pool.init(gpa, null);
//     defer pool.close();
//
//     var tup: Notifier.TempUdsPath = .{};
//     const udsPath = try tup.buildPath(gpa);
//
//     var cnfr: Configurator = .{
//         .uds_server = UDSServerConfigurator.init(udsPath),
//     };
//
//     var listener = try create_listener(&cnfr);
//
//     defer listener.deinit();
//
//     // const c_array_ptr: [*:0]const u8 = @ptrCast(&listener.accept.skt.address.un.path);
//     // const length = std.mem.len(c_array_ptr);
//     // const zig_slice: []const u8 = c_array_ptr[0..length];
//
//     var clcnfr: Configurator = .{
//         .uds_client = UDSClientConfigurator.init(udsPath),
//     };
//
//     var client = try create_client(&clcnfr, &pool);
//
//     defer client.deinit();
// }

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

test "exchanger exchange" {
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

    _ = try exc.waitConnectClient();

    try exc.exchange();

    return;
}

pub const Exchanger = struct {
    allocator: Allocator = undefined,
    pool: Pool = undefined,

    srvcnf: Configurator = undefined,
    clcnf: Configurator = undefined,

    lstCN: CN = 1,
    srvCN: CN = 2,
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
        var lst: TC = .{
            .exp = .{},
            .act = .{},
            .tskt = try create_listener(&exc.srvcnf),
            .acn = .{
                .chn = exc.lstCN,
                .mid = exc.lstCN,
                .ctx = null,
            },
        };
        errdefer lst.tskt.deinit();

        try exc.tcm.?.put(exc.lstCN, lst);

        return;
    }

    pub fn startClient(exc: *Exchanger) !void {
        var cl: TC = .{
            .exp = .{},
            .act = .{},
            .tskt = try create_client(&exc.clcnf, &exc.pool),
            .acn = .{
                .chn = exc.clCN,
                .mid = exc.clCN,
                .ctx = null,
            },
        };
        errdefer cl.tskt.deinit();

        try exc.tcm.?.put(exc.clCN, cl);

        return;
    }

    pub fn waitConnectClient(exc: *Exchanger) !sockets.Triggers {
        var it = Distributor.Iterator.init(&exc.tcm.?);

        var trgrs: sockets.Triggers = .{};

        for (0..10) |_| {
            trgrs = try exc.plr.?.waitTriggers(it, SEC_TIMEOUT_MS);

            if (trgrs.err == .on) {
                break;
            }

            if (trgrs.timeout == .on) {
                continue;
            }

            if (trgrs.accept == .on) { // Just one listener, so checking trgrs is OK
                var listener = exc.tcm.?.getPtr(exc.lstCN).?.tskt;

                const srvsktptr = try listener.tryAccept();

                if (srvsktptr != null) {
                    const srvio: sockets.TriggeredSkt = .{
                        .io = try sockets.IoSkt.initServerSide(&exc.pool, srvsktptr.?),
                    };

                    var srv: TC = .{
                        .exp = .{},
                        .act = .{},
                        .tskt = srvio,
                        .acn = .{
                            .chn = exc.srvCN,
                            .mid = exc.srvCN,
                            .ctx = null,
                        },
                    };
                    errdefer srv.tskt.deinit();

                    try exc.tcm.?.put(exc.srvCN, srv);

                    it = Distributor.Iterator.init(&exc.tcm.?);

                    trgrs = try exc.plr.?.waitTriggers(it, SEC_TIMEOUT_MS);

                    continue;
                }
            }

            const clTsktPtr = exc.tcm.?.getPtr(exc.clCN).?;

            if (clTsktPtr.act.connect == .on) {
                const connected = try clTsktPtr.tskt.tryConnect();
                if (connected) {
                    break;
                }
                continue;
            }
        }

        return trgrs;
    }

    pub fn exchange(exc: *Exchanger) !void {
        exc.removeTC(exc.lstCN); // poll only io sockets

        try exc.exchangeHeaders(1);
        return;
    }

    pub fn exchangeHeaders(exc: *Exchanger, count: usize) !void {
        const sender = exc.getTC(exc.srvCN).?; //Opposite direction
        const receiver = exc.getTC(exc.clCN).?;

        errdefer exc.pool.freeAll();

        for (0..count) |i| {
            var smsg = try Message.create(exc.allocator);
            errdefer smsg.destroy();
            smsg.bhdr.channel_number = exc.srvCN;
            smsg.bhdr.message_id = i + 1;
            smsg.bhdr.proto.mode = .signal;
            smsg.bhdr.proto.more = .last;
            smsg.bhdr.proto.mtype = .application;
            smsg.bhdr.proto.origin = .application;
            try sender.tskt.addToSend(smsg);
            exc.pool.put(try Message.create(exc.allocator)); // Prepare free messages for receiver
        }

        try exc.sendRecv(sender, receiver, count);
    }

    pub fn sendRecv(exc: *Exchanger, sndr: *TC, rcvr: *TC, count: usize) !void {
        _ = exc;
        _ = sndr;
        _ = rcvr;

        // var it = Distributor.Iterator.init(&exc.tcm.?);
        // var trgrs: sockets.Triggers = .{};

        const wasSend: usize = 0;
        const wasRecv: usize = 0;

        for (0..100) |_| {
            if ((wasSend != count) and (wasRecv != count)) {
                break;
            }
        }

        return;
    }

    fn closeChannels(exc: *Exchanger) void {
        var it = Distributor.Iterator.init(&exc.tcm.?);

        var next = it.next();

        while (next != null) {
            next.?.tskt.deinit();
            next = it.next();
        }
        return;
    }

    fn getTC(exc: *Exchanger, cn: channels.ChannelNumber) ?*TC {
        const tcp = exc.tcm.?.getPtr(cn);
        if (tcp) |tc| {
            return tc;
        }
        return null;
    }

    fn removeTC(exc: *Exchanger, tcn: channels.ChannelNumber) void {
        const tcp = exc.tcm.?.getPtr(tcn);
        if (tcp) |tc| {
            tc.*.tskt.deinit();
        }
        _ = exc.tcm.?.orderedRemove(tcn);
    }

    pub fn deinit(exc: *Exchanger) void {
        exc.closeChannels();

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
