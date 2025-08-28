// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Trigger = enum(u1) {
    on = 1,
    off = 0,
};

pub const Triggers = packed struct(u8) {
    notify: Trigger = .off,
    accept: Trigger = .off,
    connect: Trigger = .off,
    send: Trigger = .off,
    recv: Trigger = .off,
    pool: Trigger = .off,
    err: Trigger = .off,
    timeout: Trigger = .off,

    pub inline fn eql(self: Triggers, other: Triggers) bool {
        return self == other;
    }

    pub inline fn off(self: Triggers) bool {
        const z: u8 = @bitCast(self);
        return (z == 0);
    }

    pub inline fn lor(self: Triggers, other: Triggers) Triggers {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }
};

pub const UnpackedTriggers = struct {
    notify: u8 = 0,
    accept: u8 = 0,
    connect: u8 = 0,
    send: u8 = 0,
    recv: u8 = 0,
    pool: u8 = 0,
    err: u8 = 0,
    timeout: u8 = 0,

    pub fn fromTriggers(tr: Triggers) UnpackedTriggers {
        var ret: UnpackedTriggers = .{};
        if (!tr.off()) {
            if (tr.notify == .on) {
                ret.notify = 1;
            }
            if (tr.accept == .on) {
                ret.accept = 1;
            }
            if (tr.connect == .on) {
                ret.connect = 1;
            }
            if (tr.send == .on) {
                ret.send = 1;
            }
            if (tr.recv == .on) {
                ret.recv = 1;
            }
            if (tr.pool == .on) {
                ret.pool = 1;
            }
            if (tr.err == .on) {
                ret.err = 1;
            }
            if (tr.timeout == .on) {
                ret.timeout = 1;
            }
        }
        return ret;
    }
};

pub const TriggeredSkt = union(enum) {
    notification: NotificationSkt,
    accept: AcceptSkt,
    io: IoSkt,

    pub fn triggers(tsk: *TriggeredSkt) !Triggers {
        const ret = switch (tsk.*) {
            .notification => try tsk.*.notification.triggers(),
            .accept => try tsk.*.accept.triggers(),
            .io => try tsk.*.io.triggers(),
        };

        if (DBG) {
            _ = UnpackedTriggers.fromTriggers(ret);
        }

        return ret;
    }

    pub inline fn getSocket(tsk: *TriggeredSkt) Socket {
        return switch (tsk.*) {
            .notification => tsk.*.notification.getSocket(),
            .accept => tsk.*.accept.getSocket(),
            .io => tsk.*.io.getSocket(),
        };
    }

    pub fn tryRecvNotification(tsk: *TriggeredSkt) !Notification {
        return switch (tsk.*) {
            .notification => tsk.*.notification.tryRecvNotification(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryAccept(tsk: *TriggeredSkt) !?Skt {
        return switch (tsk.*) {
            .accept => tsk.*.accept.tryAccept(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryConnect(tsk: *TriggeredSkt) !bool {
        return switch (tsk.*) {
            .io => tsk.*.io.tryConnect(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryRecv(tsk: *TriggeredSkt) !MessageQueue {
        return switch (tsk.*) {
            .io => tsk.*.io.tryRecv(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn trySend(tsk: *TriggeredSkt) !MessageQueue {
        return switch (tsk.*) {
            .io => tsk.*.io.trySend(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn addToSend(tsk: *TriggeredSkt, sndmsg: *Message) !void {
        return switch (tsk.*) {
            .io => tsk.*.io.addToSend(sndmsg),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn addForRecv(tsk: *TriggeredSkt, rcvmsg: *Message) !void {
        return switch (tsk.*) {
            .io => tsk.*.io.addForRecv(rcvmsg),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn detach(tsk: *TriggeredSkt) MessageQueue {
        return switch (tsk.*) {
            .io => tsk.*.io.detach(),
            inline else => return null,
        };
    }

    pub fn deinit(tsk: *TriggeredSkt) void {
        return switch (tsk.*) {
            .notification => tsk.*.notification.deinit(),
            .accept => tsk.*.accept.deinit(),
            .io => tsk.*.io.deinit(),
        };
    }
};

pub const Skt = struct { //2DO - Add here all socket functions e.g. listen etc.
    socket: std.posix.socket_t = undefined,
    address: std.net.Address = undefined,

    pub fn listen(skt: *Skt) !void {
        const kernel_backlog = 64;
        try posix.setsockopt(skt.socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
        try posix.bind(skt.socket, &skt.address.any, skt.address.getOsSockLen());
        try posix.listen(skt.socket, kernel_backlog);

        // set address to the OS-chosen information - check for UDS!!!.
        var slen: posix.socklen_t = skt.address.getOsSockLen();
        try posix.getsockname(skt.socket, &skt.address.any, &slen);

        return;
    }

    pub fn accept(askt: *Skt) AmpeError!?Skt {
        log.debug("TRY LISTEN FD {x}", .{askt.socket});

        var skt: Skt = .{};

        var addr: std.net.Address = undefined;
        var addr_len = askt.address.getOsSockLen();

        skt.socket = std.posix.accept(
            askt.socket,
            &addr.any,
            &addr_len,
            std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        ) catch |e| {
            switch (e) {
                std.posix.AcceptError.WouldBlock => {
                    return null;
                },
                std.posix.AcceptError.ConnectionAborted,
                std.posix.AcceptError.ConnectionResetByPeer,
                => return AmpeError.PeerDisconnected,
                else => return AmpeError.CommunicatioinFailure,
            }
        };
        errdefer posix.close(skt.socket);

        nats.Client.setSockNONBLOCK(skt.socket) catch {
            return AmpeError.NotAllowed;
        };

        skt.address = addr;

        log.debug("LISTEN FD {x} CLIENT FD {x}", .{ askt.socket, skt.socket });

        return skt;
    }

    pub fn connect(skt: *Skt) AmpeError!bool {
        if (isAlreadyConnected(skt.socket)) {
            return true;
        }

        var connected = true;

        log.debug("TRY CONNECT FD {x}", .{skt.socket});

        std.posix.connect(
            skt.socket,
            &skt.address.any,
            skt.address.getOsSockLen(),
        ) catch |e| switch (e) {
            std.posix.ConnectError.WouldBlock => {
                connected = false;
            },
            else => return AmpeError.PeerDisconnected,
        };

        if (connected) {
            log.debug("CONNECTED FD {x}", .{skt.socket});
        }
        return connected;
    }

    pub fn disableNagle(skt: *Skt) !void {
        switch (skt.address.any.family) {
            std.posix.AF.INET, std.posix.AF.INET6 => {
                // try disable Nagle
                // const tcp_nodelay: c_int = 0;
                // try os.setsockopt(skt.socket, os.IPPROTO.TCP, os.TCP.NODELAY, mem.asBytes(&tcp_nodelay));
                try disable_nagle(skt.socket);
            },
            else => return,
        }
    }

    pub fn deinit(skt: *Skt) void {
        posix.close(skt.socket);
    }
};

pub const SocketCreator = struct {
    allocator: Allocator = undefined,
    cnfgr: Configurator = undefined,

    pub fn init(allocator: Allocator) SocketCreator {
        return .{
            .allocator = allocator,
            .cnfgr = .wrong,
        };
    }

    pub fn fromMessage(sc: *SocketCreator, msg: *Message) AmpeError!Skt {
        const cnfgr = Configurator.fromMessage(msg);

        return sc.fromConfigurator(cnfgr);
    }

    pub fn fromConfigurator(sc: *SocketCreator, cnfgr: Configurator) AmpeError!Skt {
        sc.cnfgr = cnfgr;

        switch (sc.cnfgr) {
            .wrong => return AmpeError.InvalidAddress,
            .tcp_server => return sc.createTcpServer(),
            .tcp_client => return sc.createTcpClient(),
            .uds_server => return sc.createUdsServer(),
            .uds_client => return sc.createUdsClient(),
        }
    }

    pub fn createTcpServer(sc: *SocketCreator) AmpeError!Skt {
        const cnf: *TCPServerConfigurator = &sc.cnfgr.tcp_server;

        const address = std.net.Address.resolveIp(cnf.ip.?, cnf.port.?) catch {
            return AmpeError.InvalidAddress;
        };

        const skt = createListenerSocket(&address) catch {
            return AmpeError.InvalidAddress;
        };

        return skt;
    }

    pub fn createTcpClient(sc: *SocketCreator) AmpeError!Skt {
        const cnf: *TCPClientConfigurator = &sc.cnfgr.tcp_client;

        var list = std.net.getAddressList(sc.allocator, cnf.addr.?, cnf.port.?) catch {
            return AmpeError.InvalidAddress;
        };
        defer list.deinit();

        if (list.addrs.len == 0) {
            return AmpeError.InvalidAddress;
        }

        for (list.addrs) |addr| {
            const ret = createConnectSocket(&addr) catch {
                continue;
            };
            return ret;
        }
        return AmpeError.InvalidAddress;
    }

    pub fn createUdsServer(sc: *SocketCreator) AmpeError!Skt {
        return createUdsListener(sc.allocator, sc.cnfgr.uds_server.path);
    }

    pub fn createUdsListener(allocator: Allocator, path: []const u8) AmpeError!Skt {
        var udsPath = path;

        if (udsPath.len == 0) {
            var tup: Notifier.TempUdsPath = .{};

            udsPath = tup.buildPath(allocator) catch {
                return AmpeError.UnknownError;
            };
        }

        var address = std.net.Address.initUnix(udsPath) catch {
            return AmpeError.InvalidAddress;
        };

        const skt = createListenerSocket(&address) catch {
            return AmpeError.InvalidAddress;
        };

        return skt;
    }

    pub fn createUdsClient(sc: *SocketCreator) AmpeError!Skt {
        return createUdsSocket(sc.cnfgr.uds_client.path);
    }

    pub fn createUdsSocket(path: []const u8) AmpeError!Skt {
        var address = std.net.Address.initUnix(path) catch {
            return AmpeError.InvalidAddress;
        };

        const skt = createConnectSocket(&address) catch {
            return AmpeError.InvalidAddress;
        };

        return skt;
    }

    // from IoUring.zig#L3473 (0.14.1), slightly changed
    fn createListenerSocket(address: *const std.net.Address) !Skt {
        var ret: Skt = .{
            .address = address.*,
            .socket = undefined,
        };

        ret.socket = try posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(ret.socket);

        try ret.listen();

        return ret;
    }
};

pub fn createConnectSocket(address: *const std.net.Address) !Skt {
    var ret: Skt = .{
        .address = address.*,
        .socket = undefined,
    };

    ret.socket = try posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(ret.socket);

    return ret;
}

const NotificationTriggers: Triggers = .{
    .notify = .on,
};

pub const NotificationSkt = struct {
    socket: Socket = undefined,

    pub fn init(socket: Socket) NotificationSkt { // prnt.ntfr.receiver
        log.debug("NotificationSkt init", .{});
        return .{
            .socket = socket,
        };
    }

    pub fn triggers(nskt: *NotificationSkt) !Triggers {
        _ = nskt;
        return NotificationTriggers;
    }

    pub inline fn getSocket(self: *NotificationSkt) Socket {
        return self.socket;
    }

    pub fn tryRecvNotification(nskt: *NotificationSkt) !Notification {
        return Notifier.recv_notification(nskt.socket);
    }

    pub fn deinit(nskt: *NotificationSkt) void {
        // Notification sockets will be closed later by engine itself
        _ = nskt;
        return;
    }
};

const AcceptTriggers: Triggers = .{
    .accept = .on,
};

pub const AcceptSkt = struct {
    skt: Skt = undefined,

    pub fn init(wlcm: *Message, sc: *SocketCreator) AmpeError!AcceptSkt {
        return .{
            .skt = try sc.fromMessage(wlcm),
        };
    }

    pub fn triggers(askt: *AcceptSkt) !Triggers {
        _ = askt;
        return AcceptTriggers;
    }

    pub inline fn getSocket(self: *AcceptSkt) Socket {
        return self.skt.socket;
    }

    pub fn tryAccept(askt: *AcceptSkt) AmpeError!?Skt {
        return askt.skt.accept();
    }

    pub fn deinit(askt: *AcceptSkt) void {
        std.posix.close(askt.skt.socket);
        return;
    }
};

pub const Side = enum(u1) {
    client = 0,
    server = 1,
};

pub const IoSkt = struct {
    pool: *Pool = undefined,
    side: Side = undefined,
    cn: message.ChannelNumber = undefined,
    skt: Skt = undefined,
    connected: bool = undefined,
    connectInitiated: bool = undefined,
    sendQ: MessageQueue = undefined,
    currSend: MsgSender = undefined,
    currRecv: MsgReceiver = undefined,
    alreadySend: ?*Message = null,

    pub fn initServerSide(pool: *Pool, cn: message.ChannelNumber, sskt: Skt) AmpeError!IoSkt {
        log.debug("Server IoSkt init", .{});

        var ret: IoSkt = .{
            .pool = pool,
            .side = .server,
            .cn = cn,
            .skt = sskt,
            .connected = true,
            .connectInitiated = true,
            .sendQ = .{},
            .currSend = MsgSender.init(),
            .currRecv = MsgReceiver.init(pool),
            .alreadySend = null,
        };

        ret.currSend.set(cn, sskt.socket) catch unreachable;
        ret.currRecv.set(cn, sskt.socket) catch unreachable;

        return ret;
    }

    pub fn initClientSide(ios: *IoSkt, pool: *Pool, hello: *Message, sc: *SocketCreator) AmpeError!void {
        log.debug("Client IoSkt init", .{});

        ios.pool = pool;
        ios.side = .client;
        ios.cn = hello.bhdr.channel_number;
        ios.skt = try sc.fromMessage(hello);
        ios.connected = false;
        ios.connectInitiated = false;
        ios.sendQ = .{};
        ios.currSend = MsgSender.init();
        ios.currRecv = MsgReceiver.init(pool);
        ios.alreadySend = null;

        errdefer ios.skt.deinit();

        ios.addToSend(hello) catch unreachable;

        // ios.connected = try ios.skt.connect();
        //
        // if (ios.connected) {
        //     ios.postConnect();
        //     var sq = try ios.trySend();
        //     ios.alreadySend = sq.dequeue();
        // }

        return;
    }

    pub fn triggers(ioskt: *IoSkt) !Triggers {
        if (ioskt.side == .client) { // Initial state of client ioskt - not-connected

            if (!ioskt.connectInitiated) {
                ioskt.connected = try ioskt.skt.connect();
                ioskt.connectInitiated = true;
            }

            if (!ioskt.connected) {
                return .{
                    .connect = .on,
                };
            }

            ioskt.postConnect();
            var sq = try ioskt.trySend();
            ioskt.alreadySend = sq.dequeue();
        }

        var ret: Triggers = .{};
        if (!ioskt.sendQ.empty() or ioskt.currSend.started()) {
            ret.send = .on;
        }

        const recvPossible = try ioskt.currRecv.recvIsPossible();

        if (recvPossible) {
            ret.recv = .on;
        } else {
            assert(ioskt.currRecv.ptrg == .on);
            ret.pool = .on;
        }

        if (DBG) {
            const utrgs = UnpackedTriggers.fromTriggers(ret);
            _ = utrgs;
        }

        return ret;
    }

    pub inline fn getSocket(self: *IoSkt) Socket {
        return self.skt.socket;
    }

    pub fn addToSend(ioskt: *IoSkt, sndmsg: *Message) AmpeError!void {
        ioskt.sendQ.enqueue(sndmsg);
        return;
    }

    pub fn addForRecv(ioskt: *IoSkt, rcvmsg: *Message) AmpeError!void {
        return ioskt.currRecv.attach(rcvmsg);
    }

    // tryConnect is called by Distributor for succ. connection.
    // For the failed connection Distributor uses detach: get Hello request , convert to filed Hello response...
    pub fn tryConnect(ioskt: *IoSkt) AmpeError!bool {
        if (ioskt.connected) {
            return AmpeError.NotAllowed;
        }

        ioskt.connected = try ioskt.skt.connect();

        if (ioskt.connected) {
            ioskt.postConnect();
        }

        return ioskt.connected;
    }

    fn postConnect(ioskt: *IoSkt) void {
        ioskt.currSend.set(ioskt.cn, ioskt.skt.socket) catch unreachable;
        ioskt.currRecv.set(ioskt.cn, ioskt.skt.socket) catch unreachable;

        ioskt.currSend.attach(ioskt.sendQ.dequeue().?) catch unreachable;
        ioskt.alreadySend = null;
        return;
    }

    pub fn detach(ioskt: *IoSkt) MessageQueue {
        var ret: MessageQueue = .{};

        const last = ioskt.currSend.detach();

        if (last != null) {
            ret.enqueue(last.?);
        }

        ioskt.sendQ.move(&ret);

        return ret;
    }

    pub fn tryRecv(ioskt: *IoSkt) AmpeError!MessageQueue {
        if (!ioskt.connected) {
            return AmpeError.NotAllowed;
        }

        var ret: MessageQueue = .{};

        while (true) {
            const received = ioskt.currRecv.recv() catch |e| {
                switch (e) {
                    AmpeError.PoolEmpty => {
                        return ret;
                    },
                    else => return e,
                }
            };

            if (received == null) {
                break;
            }
            ret.enqueue(received.?);
        }

        return ret;
    }

    pub fn trySend(ioskt: *IoSkt) AmpeError!MessageQueue {
        var ret: MessageQueue = .{};

        if (!ioskt.connected) {
            return AmpeError.NotAllowed;
        }

        while (true) {
            if (!ioskt.currSend.started()) {
                if (ioskt.sendQ.empty()) {
                    break;
                }
                ioskt.currSend.attach(ioskt.sendQ.dequeue().?) catch unreachable; // Ok for non-empty q
            }

            const wasSend = try ioskt.currSend.send();

            if (wasSend == null) {
                break;
            }

            ret.enqueue(wasSend.?);
        }

        return ret;
    }

    pub fn deinit(ioskt: *IoSkt) void {
        ioskt.skt.deinit();
        ioskt.sendQ.clear();

        ioskt.currSend.deinit();
        ioskt.currRecv.deinit();

        if (ioskt.alreadySend != null) {
            ioskt.alreadySend.?.destroy();
            ioskt.alreadySend = null;
        }

        return;
    }
};

pub const MsgSender = struct {
    ready: bool = undefined,
    cn: message.ChannelNumber = undefined,
    socket: Socket = undefined,
    msg: ?*Message = undefined,
    bh: [BinaryHeader.BHSIZE]u8 = [_]u8{'+'} ** BinaryHeader.BHSIZE,
    iov: [3]std.posix.iovec_const = undefined,
    vind: usize = undefined,
    sndlen: usize = undefined,
    iovPrepared: bool = undefined,

    pub fn init() MsgSender {
        return .{
            .ready = false,
            .msg = null,
            .sndlen = 0,
            .vind = 3,
            .iovPrepared = false,
        };
    }

    pub fn set(ms: *MsgSender, cn: message.ChannelNumber, socket: Socket) !void {
        if (ms.ready) {
            return AmpeError.NotAllowed;
        }
        ms.cn = cn;
        ms.socket = socket;
        ms.ready = true;
    }

    pub inline fn isReady(ms: *MsgSender) bool {
        return ms.ready;
    }

    pub fn deinit(ms: *MsgSender) void {
        if (ms.msg) |m| {
            m.destroy();
        }
        ms.msg = null;
        ms.sndlen = 0;
        return;
    }

    pub fn attach(ms: *MsgSender, msg: *Message) !void {
        if (!ms.ready) {
            return AmpeError.NotAllowed;
        }

        if (ms.msg) |m| {
            m.destroy();
        }

        ms.msg = msg;
        ms.iovPrepared = false;

        return;
    }

    inline fn prepare(ms: *MsgSender) void {
        const hlen = ms.msg.?.actual_headers_len();
        const blen = ms.msg.?.actual_body_len();

        ms.msg.?.bhdr.body_len = @intCast(blen);
        ms.msg.?.bhdr.text_headers_len = @intCast(hlen);

        @memset(&ms.bh, ' ');

        ms.msg.?.bhdr.toBytes(&ms.bh);
        ms.vind = 0;

        assert(ms.bh.len == message.BinaryHeader.BHSIZE);

        ms.iov[0] = .{ .base = &ms.bh, .len = ms.bh.len };
        ms.sndlen = ms.bh.len;

        if (hlen == 0) {
            ms.iov[1] = .{ .base = @ptrCast(""), .len = 0 };
        } else {
            ms.iov[1] = .{ .base = @ptrCast(ms.msg.?.thdrs.buffer.body().?.ptr), .len = hlen };
            ms.sndlen += hlen;
        }

        if (blen == 0) {
            ms.iov[2] = .{ .base = @ptrCast(""), .len = 0 };
        } else {
            ms.iov[2] = .{ .base = @ptrCast(ms.msg.?.body.body().?.ptr), .len = blen };
            ms.sndlen += blen;
        }

        ms.iovPrepared = true;
        return;
    }

    pub inline fn started(ms: *MsgSender) bool {
        return (ms.msg != null);
    }

    pub fn detach(ms: *MsgSender) ?*Message {
        const ret = ms.msg;
        ms.msg = null;
        ms.sndlen = 0;
        ms.vind = 3;
        return ret;
    }

    pub fn send(ms: *MsgSender) AmpeError!?*Message {
        if (!ms.ready) {
            return AmpeError.NotAllowed;
        }
        if (ms.msg == null) {
            return AmpeError.NotAllowed; // to  prevent bug
        }

        if (!ms.iovPrepared) {
            ms.prepare();
        }

        while (ms.vind < 3) : (ms.vind += 1) {
            while (ms.iov[ms.vind].len > 0) {
                const wasSend = try sendBuf(ms.socket, ms.iov[ms.vind].base[0..ms.iov[ms.vind].len]);
                if (wasSend == null) {
                    return null;
                }
                ms.iov[ms.vind].base += wasSend.?;
                ms.iov[ms.vind].len -= wasSend.?;
                ms.sndlen -= wasSend.?;

                if (ms.sndlen > 0) {
                    continue;
                }

                const ret = ms.msg;
                ms.msg = null;
                return ret;
            }
        }
        return AmpeError.NotAllowed; // to  prevent bug
    }
};

pub const MsgReceiver = struct {
    ready: bool = undefined,
    cn: message.ChannelNumber = undefined,
    socket: Socket = undefined,
    pool: *Pool = undefined,
    ptrg: Trigger = undefined,
    bh: [BinaryHeader.BHSIZE]u8 = [_]u8{'-'} ** BinaryHeader.BHSIZE,
    iov: [3]std.posix.iovec = undefined,
    vind: usize = undefined,
    rcvlen: usize = undefined,
    msg: ?*Message = undefined,

    pub fn init(pool: *Pool) MsgReceiver {
        return .{
            .ready = false,
            .pool = pool,
            .msg = null,
            .rcvlen = 0,
            .vind = 3,
            .ptrg = .off, // Possibly msg == null will be good enough
        };
    }

    pub fn set(mr: *MsgReceiver, cn: message.ChannelNumber, socket: Socket) !void {
        if (mr.ready) {
            return AmpeError.NotAllowed;
        }
        mr.cn = cn;
        mr.socket = socket;
        mr.ready = true;
    }

    pub fn recvIsPossible(mr: *MsgReceiver) !bool {
        if (mr.msg != null) {
            return true;
        }

        const msg = mr.getFromPool() catch |err| {
            if (err != AmpeError.PoolEmpty) {
                return err;
            }
            return false;
        };
        mr.msg = msg;
        mr.prepareMsg();
        return true;
    }

    pub fn attach(mr: *MsgReceiver, msg: *Message) !void {
        if ((!mr.ready) or (mr.msg != null)) {
            return AmpeError.NotAllowed;
        }

        mr.msg = msg;
        mr.ptrg = .off;

        mr.prepareMsg();

        return;
    }

    inline fn prepareMsg(mr: *MsgReceiver) void {
        mr.msg.?.reset();
        @memset(&mr.bh, ' ');
        assert(mr.bh.len == message.BinaryHeader.BHSIZE);

        mr.iov[0] = .{ .base = &mr.bh, .len = mr.bh.len };
        mr.iov[1] = .{ .base = mr.msg.?.thdrs.buffer.buffer.?.ptr, .len = 0 };
        mr.iov[2] = .{ .base = mr.msg.?.body.buffer.?.ptr, .len = 0 };

        mr.vind = 0;
        mr.rcvlen = 0;
        return;
    }

    fn getFromPool(mr: *MsgReceiver) !*Message {
        const ret = mr.pool.get(.poolOnly) catch |e| {
            switch (e) {
                error.ClosedPool => {
                    return AmpeError.NotAllowed;
                },
                error.EmptyPool => {
                    mr.ptrg = .on;
                    return AmpeError.PoolEmpty;
                },
                else => return AmpeError.AllocationFailed,
            }
        };
        mr.ptrg = .off;
        return ret;
    }

    pub fn recv(mr: *MsgReceiver) !?*Message {
        if (!mr.ready) {
            return AmpeError.NotAllowed;
        }

        if (mr.msg == null) {
            mr.msg = try mr.getFromPool();
            mr.prepareMsg();
        }

        while (mr.vind < 3) : (mr.vind += 1) {
            while (mr.iov[mr.vind].len > 0) {
                const wasRecv = try recvToBuf(mr.socket, mr.iov[mr.vind].base[0..mr.iov[mr.vind].len]);
                if (wasRecv == null) {
                    return null;
                }

                if (wasRecv.? == 0) {
                    return null;
                }
                mr.iov[mr.vind].base += wasRecv.?;
                mr.iov[mr.vind].len -= wasRecv.?;
                mr.rcvlen += wasRecv.?;
            }

            if (mr.vind == 0) {
                mr.msg.?.bhdr.fromBytes(&mr.bh);
                if (mr.msg.?.bhdr.text_headers_len > 0) {
                    mr.iov[1].len = mr.msg.?.bhdr.text_headers_len;

                    // Allow direct receive to the buffer of appendable without copy
                    mr.msg.?.thdrs.buffer.alloc(mr.iov[1].len) catch {
                        return AmpeError.AllocationFailed;
                    };
                    mr.msg.?.thdrs.buffer.change(mr.iov[1].len) catch unreachable;
                }
                if (mr.msg.?.bhdr.body_len > 0) {
                    mr.iov[2].len = mr.msg.?.bhdr.body_len;

                    // Allow direct receive to the buffer of appendable without copy
                    mr.msg.?.body.alloc(mr.iov[2].len) catch {
                        return AmpeError.AllocationFailed;
                    };
                    mr.msg.?.body.change(mr.iov[2].len) catch unreachable;
                }
            }
        }

        const ret = mr.msg;
        mr.msg = null;
        return ret;
    }

    pub inline fn isReady(mr: *MsgReceiver) bool {
        return mr.ready;
    }

    pub fn deinit(mr: *MsgReceiver) void {
        if (mr.msg) |m| {
            m.destroy();
        }
        mr.msg = null;
        mr.rcvlen = 0;
        return;
    }
};

pub fn recvToBuf(socket: std.posix.socket_t, buf: []u8) AmpeError!?usize {
    var wasRecv: usize = 0;
    wasRecv = std.posix.recv(socket, buf, 0) catch |e| {
        switch (e) {
            std.posix.RecvFromError.WouldBlock => {
                return null;
            },
            std.posix.RecvFromError.ConnectionResetByPeer, std.posix.RecvFromError.ConnectionRefused => return AmpeError.PeerDisconnected,
            else => return AmpeError.CommunicatioinFailure,
        }
    };

    return wasRecv;
}

pub fn sendBuf(socket: std.posix.socket_t, buf: []const u8) AmpeError!?usize {
    var wasSend: usize = 0;
    wasSend = std.posix.send(socket, buf, 0) catch |e| {
        switch (e) {
            std.posix.SendError.WouldBlock => {
                return null;
            },
            std.posix.SendError.ConnectionResetByPeer, std.posix.SendError.BrokenPipe => return AmpeError.PeerDisconnected,
            else => return AmpeError.CommunicatioinFailure,
        }
    };

    if (wasSend == 0) {
        return null;
    }

    return wasSend;
}

fn isAlreadyConnected(socket: std.posix.socket_t) bool {
    _getsockoptError(socket) catch |err| {
        if (err == error.AlreadyConnected) {
            log.debug("ALREADY CONNECTED FD {x}", .{socket});
            return true;
        }
    };
    return false;
}

//
// https://github.com/tardy-org/tardy/blob/main/src/cross/socket.zig#L39
//
fn disable_nagle(socket: std.posix.socket_t) !void {
    if (comptime os.isBSD()) {
        // system.TCP is weird on MacOS.
        try std.posix.setsockopt(
            socket,
            std.posix.IPPROTO.TCP,
            1,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    } else {
        try std.posix.setsockopt(
            socket,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    }
}

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

const engine = @import("../engine.zig");
const DBG = engine.DBG;
const Options = engine.Options;
const Sr = engine.Sr;
const AllocationStrategy = engine.AllocationStrategy;

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

const mailbox = @import("mailbox");
pub const MSGMailBox = mailbox.MailBoxIntrusive(Message);

const nats = @import("nats");

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const os = builtin.os.tag;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Socket = std.posix.socket_t;

const log = std.log;

const native_os = builtin.os.tag;
const linux = std.os.linux;
const windows = std.os.windows;

////////////////// FROM std.posix /////////////////////////////
/// Initiate a connection on a socket.
/// If `sockfd` is opened in non blocking mode, the function will
/// return error.WouldBlock when EAGAIN or EINPROGRESS is received.
fn _connect(sock: std.posix.socket_t, sock_addr: *const std.net.Address, len: std.posix.system.socklen_t) posix.ConnectError!void {
    if (native_os == .windows) {
        const rc = windows.ws2_32.connect(sock, sock_addr, @intCast(len));
        if (rc == 0) return;
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEADDRINUSE => return error.AddressInUse,
            .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
            .WSAECONNREFUSED => return error.ConnectionRefused,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAETIMEDOUT => return error.ConnectionTimedOut,
            .WSAEHOSTUNREACH, // 2DO: should we return NetworkUnreachable in this case as well?
            .WSAENETUNREACH,
            => return error.NetworkUnreachable,
            .WSAEFAULT => unreachable,
            .WSAEINVAL => unreachable,
            .WSAEISCONN => unreachable,
            .WSAENOTSOCK => unreachable,
            .WSAEWOULDBLOCK => return error.WouldBlock,
            .WSAEACCES => unreachable,
            .WSAENOBUFS => return error.SystemResources,
            .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
            else => |err| return windows.unexpectedWSAError(err),
        }
        return;
    }

    while (true) {
        switch (posix.errno(std.posix.system.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.PermissionDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .INTR => continue,
            .ISCONN => return, // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
            .CONNABORTED => unreachable, // Tried to reuse socket that previously received error.ConnectionRefused.
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn _getsockoptError(sockfd: std.posix.socket_t) !void {
    var err_code: i32 = undefined;
    var size: u32 = @sizeOf(u32);
    const rc = std.posix.system.getsockopt(sockfd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err_code), &size);
    assert(size == 4);
    switch (posix.errno(rc)) {
        .SUCCESS => switch (@as(posix.system.E, @enumFromInt(err_code))) {
            .SUCCESS => return,
            .ACCES => return error.PermissionDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN => return error.SystemResources,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .ISCONN => {
                log.debug("ALREADY CONNECTED FD {x}", .{sockfd});
                return error.AlreadyConnected; // The socket is already connected.
            },
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => return error.ConnectionTimedOut,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |err| return posix.unexpectedErrno(err),
        },
        .BADF => unreachable, // The argument sockfd is not a valid file descriptor.
        .FAULT => unreachable, // The address pointed to by optval or optlen is not in a valid part of the process address space.
        .INVAL => unreachable,
        .NOPROTOOPT => unreachable, // The option is unknown at the level indicated.
        .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
        else => |err| return posix.unexpectedErrno(err),
    }
}
