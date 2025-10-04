// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("sockets_tests\r\n", .{});
}

const localIP = "127.0.0.1";
const SEC_TIMEOUT_MS = 1_000;
const INFINITE_TIMEOUT_MS = std.math.maxInt(u64);

pub const std_options: @import("std").Options = .{ .log_level = .debug };

test "UDS exchanger " {
    std.testing.log_level = .info;

    log.debug("Exchanger UDS\r\n", .{});

    var tup: Notifier.TempUdsPath = .{};

    const path = try tup.buildPath(gpa);

    log.debug("\r\nUDS path {s}\r\n", .{path});

    const srvcnf: Configurator = .{
        .uds_server = UDSServerConfigurator.init(path),
    };

    const clcnf: Configurator = .{
        .uds_client = UDSClientConfigurator.init(path),
    };

    for (1..3) |_| {
        try run(srvcnf, clcnf);
    }
    return;
}

test "TCP/IP exchanger " {
    std.testing.log_level = .info;

    log.debug("Exchanger TCP/IP)\r\n", .{});

    const srvcnf: Configurator = .{
        .tcp_server = TCPServerConfigurator.init(localIP, configurator.DefaultPort),
    };

    const clcnf: Configurator = .{
        .tcp_client = TCPClientConfigurator.init(localIP, configurator.DefaultPort),
    };

    for (1..3) |_| {
        try run(srvcnf, clcnf);
    }
    return;
}

fn run(srvcnf: Configurator, clcnf: Configurator) !void {
    var exc: Exchanger = try Exchanger.init(gpa, srvcnf, clcnf, false);
    defer exc.deinit();

    try exc.startListen();

    try exc.startClient();

    try exc.waitConnectClient();

    exc.setRun(Exchanger.sendRecvPoll);

    try exc.exchange();

    return;
}

pub const SendRecv = *const fn (exc: *Exchanger, count: usize) anyerror!void;

pub const Exchanger = struct {
    allocator: Allocator = undefined,
    pool: Pool = undefined,

    srvcnf: Configurator = undefined,
    clcnf: Configurator = undefined,

    lstCN: CN = 10,
    srvCN: CN = 20,
    clCN: CN = 30,

    tcm: ?TCM = null,
    plr: ?Poller = null,

    sender: ?*TC = null,
    receiver: ?*TC = null,

    forSend: MessageQueue = .{},
    forRecv: MessageQueue = .{},
    forCmpr: MessageQueue = .{},

    srf: SendRecv = undefined,

    pub fn init(allocator: Allocator, srvcnf: Configurator, clcnf: Configurator, usePoller: bool) !Exchanger {
        var ret: Exchanger = .{
            .allocator = allocator,
            .pool = try Pool.init(allocator, null, null, null),
            .srvcnf = srvcnf,
            .clcnf = clcnf,
        };

        if (usePoller) {
            ret.srf = sendRecvPoll;
        } else {
            ret.srf = sendRecvNonPoll;
        }

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

    pub fn setRun(exc: *Exchanger, sr: SendRecv) void {
        exc.srf = sr;
    }

    pub fn setRunner(exc: *Exchanger, usePoller: bool) void {
        if (usePoller) {
            exc.srf = sendRecvPoll;
        } else {
            exc.srf = sendRecvNonPoll;
        }
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
        // Workaround, in production hello contains chn
        cl.tskt.io.cn = cl.acn.chn;
        errdefer cl.tskt.deinit();

        try exc.tcm.?.put(exc.clCN, cl);

        return;
    }

    pub fn waitConnectClient(exc: *Exchanger) !void {
        var it = Engine.Iterator.init(&exc.tcm.?);

        var trgrs: sockets.Triggers = .{};

        var serverReady: bool = false;
        var clientReady: bool = false;

        for (0..100) |i| {
            log.debug("wait connected client {d}", .{i + 1});

            if (serverReady and clientReady) {
                break;
            }

            trgrs = try exc.plr.?.waitTriggers(it, SEC_TIMEOUT_MS);

            if (trgrs.err == .on) {
                break;
            }

            if (trgrs.timeout == .on) {
                continue;
            }

            if (serverReady) { // disable further accepts - test flow only
                trgrs.accept = .off;
            }

            if (trgrs.accept == .on) { // Just one listener, so checking trgrs is OK
                var listener = exc.tcm.?.getPtr(exc.lstCN).?.tskt;

                log.debug("wait connected client - try accept", .{});
                const srvsktptr = try listener.tryAccept();

                if (srvsktptr != null) {
                    const srvio: sockets.TriggeredSkt = .{
                        .io = try sockets.IoSkt.initServerSide(&exc.pool, exc.srvCN, srvsktptr.?),
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

                    it = Engine.Iterator.init(&exc.tcm.?);

                    serverReady = true;
                    log.debug("wait connected client - server ready", .{});
                }
            }

            if (trgrs.connect == .on) {
                log.debug("wait connected client - try connect", .{});
                const clTsktPtr = exc.tcm.?.getPtr(exc.clCN).?;

                if (clTsktPtr.act.connect == .on) {
                    _ = try clTsktPtr.tskt.tryConnect();
                }
            }

            if ((trgrs.send == .on) or (trgrs.recv == .on) or (trgrs.pool == .on)) {
                clientReady = true;
                log.debug("wait connected client - client ready", .{});
            }
        }

        return;
    }

    pub fn exchange(exc: *Exchanger) !void {
        exc.removeTC(exc.lstCN); // poll only io sockets

        exc.sender = exc.getTC(exc.clCN).?;
        exc.receiver = exc.getTC(exc.srvCN).?;

        const sdf: Socket = exc.sender.?.tskt.getSocket();
        const rdf: Socket = exc.receiver.?.tskt.getSocket();

        log.debug("sender fd {x} receiver fd {x} ", .{ sdf, rdf });

        assert(sdf != rdf);

        try exc.exchangeMsgs(11);
        return;
    }

    pub fn exchangeMsgs(exc: *Exchanger, count: usize) !void {
        exc.clearPool();
        exc.clearQs();

        const body: []u8 = try exc.allocator.alloc(u8, 10000);
        defer exc.allocator.free(body);

        for (0..count) |i| {
            var smsg = try Message.create(exc.allocator);

            smsg.bhdr.channel_number = exc.srvCN;
            smsg.bhdr.message_id = i + 1;
            smsg.bhdr.proto.role = .signal;
            smsg.bhdr.proto.more = .last;
            smsg.bhdr.proto.mtype = .application;
            smsg.bhdr.proto.origin = .application;
            try smsg.body.copy(body);

            exc.forSend.enqueue(smsg);
            exc.forCmpr.enqueue(try smsg.clone());
            exc.pool.put(try Message.create(exc.allocator)); // Prepare free messages for receiver
            exc.pool.put(try Message.create(exc.allocator)); // Prepare free messages for receiver
            exc.pool.put(try Message.create(exc.allocator)); // Prepare free messages for receiver                                                             //
        }

        const scount = exc.forSend.count();

        assert(scount == count);

        if (scount == 0) {
            return;
        }

        for (0..scount) |_| {
            try exc.sender.?.tskt.addToSend(exc.forSend.dequeue().?);
        }
        assert(exc.sender.?.tskt.io.sendQ.count() == scount);

        try exc.srf(exc, count);
    }

    pub fn sendRecvPoll(
        exc: *Exchanger,
        count: usize,
    ) !void {
        if (count == 0) {
            return;
        }

        const it = Engine.Iterator.init(&exc.tcm.?);

        var loop: usize = 1;

        while ((loop < 3 * count) and (exc.forRecv.count() < (count + 1))) : (loop += 1) {
            var trgrs: sockets.Triggers = .{};

            trgrs = try exc.plr.?.waitTriggers(it, Notifier.SEC_TIMEOUT_MS);

            try testing.expect(trgrs.err != .on);

            // In production code we need in loop check act triggers per every channels
            // For the test - checking of 'trgrs' is good enough

            if (trgrs.send == .on) {
                var wasSend = try exc.sender.?.tskt.trySend();
                for (0..wasSend.count()) |_| {
                    exc.pool.put(wasSend.dequeue().?);
                }
            }
            if (trgrs.recv == .on) {
                var wasRecv = try exc.receiver.?.tskt.tryRecv();
                wasRecv.move(&exc.forRecv);
            }

            log.debug("loop {d} received {d}", .{
                loop,
                exc.forRecv.count(),
            });
        }

        try testing.expect(exc.forRecv.count() == (count + 1));

        return;
    }

    pub fn sendRecvNonPoll(
        exc: *Exchanger,
        count: usize,
    ) !void {
        if (count == 0) {
            return;
        }

        var loop: usize = 0;

        while (loop < 100) : (loop += 1) { //
            var wasSend = try exc.sender.?.tskt.trySend();
            for (0..wasSend.count()) |_| {
                exc.pool.put(wasSend.dequeue().?);
            }

            var wasRecv = try exc.receiver.?.tskt.tryRecv();

            wasRecv.move(&exc.forRecv);

            const rc = exc.forRecv.count();
            if (rc == (count + 1)) {
                break;
            }
        }

        try testing.expect(exc.forRecv.count() == (count + 1));

        return;
    }

    fn closeChannels(exc: *Exchanger) void {
        var it = Engine.Iterator.init(&exc.tcm.?);

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

    pub fn clearQs(exc: *Exchanger) void {
        message.clearQueue(&exc.forCmpr);
        message.clearQueue(&exc.forRecv);
        message.clearQueue(&exc.forSend);
    }

    pub fn clearPool(exc: *Exchanger) void {
        exc.pool.freeAll();
    }

    pub fn deinit(exc: *Exchanger) void {
        exc.closeChannels();

        exc.clearQs();

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

fn create_listener(cnfr: *Configurator) !sockets.TriggeredSkt {
    var wlcm: *Message = try Message.create(gpa);
    defer wlcm.destroy();

    try cnfr.prepareRequest(wlcm);

    var sc: sockets.SocketCreator = sockets.SocketCreator.init(gpa);

    var tskt: sockets.TriggeredSkt = .{
        .accept = try sockets.AcceptSkt.init(wlcm, &sc),
    };
    errdefer tskt.deinit();

    const trgrs = try tskt.triggers();

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

    var clSkt: sockets.IoSkt = .{};
    try clSkt.initClientSide(pool, hello, &sc);
    var tskt: sockets.TriggeredSkt = .{
        .io = clSkt,
    };
    errdefer tskt.deinit();

    const trgrs = try tskt.triggers();

    const utrg = sockets.UnpackedTriggers.fromTriggers(trgrs);

    const onTrigger: u8 = switch (cnfr.*) {
        .tcp_client => utrg.connect,
        .uds_client => utrg.send,
        else => unreachable,
    };

    try testing.expect(onTrigger == 1);

    return tskt;
}

const tofu = @import("../tofu.zig");
const internal = tofu.@"internal usage";

const message = tofu.message;
const MessageType = message.MessageType;
const MessageRole = message.MessageRole;
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

const Engine = tofu.Engine;
const TCM = internal.TriggeredChannelsMap;
const TC = internal.TriggeredChannel;

const poller = internal.poller;
const Poller = poller.Poller;
const Poll = poller.Poll;

const configurator = tofu.configurator;
const Configurator = configurator.Configurator;
const TCPServerConfigurator = configurator.TCPServerConfigurator;
const TCPClientConfigurator = configurator.TCPClientConfigurator;
const UDSServerConfigurator = configurator.UDSServerConfigurator;
const UDSClientConfigurator = configurator.UDSClientConfigurator;
const WrongConfigurator = configurator.WrongConfigurator;

const status = tofu.status;
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const raw_to_status = status.raw_to_status;
const raw_to_error = status.raw_to_error;
const status_to_raw = status.status_to_raw;

const Pool = internal.Pool;
const Notifier = internal.Notifier;
const Notification = Notifier.Notification;

const channels = internal.channels;
const ActiveChannel = channels.ActiveChannel;
const ActiveChannels = channels.ActiveChannels;

const sockets = internal.sockets;

const Appendable = @import("nats").Appendable;

const DBG = tofu.DBG;

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const os = builtin.os.tag;
const Allocator = std.mem.Allocator;
const gpa = std.testing.allocator;
const Mutex = std.Thread.Mutex;
const Socket = std.posix.socket_t;

const log = std.log;

// 2DO - clean obsolete log.debug
