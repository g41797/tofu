// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

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

    pub fn toStatus(self: Triggers) AmpeStatus {
        if (self.err == .off) {
            return .success;
        }

        if (self.notify == .on) {
            return AmpeStatus.notification_failed;
        }

        if (self.connect == .on) {
            return AmpeStatus.connect_failed;
        }

        if (self.accept == .on) {
            return AmpeStatus.accept_failed;
        }

        return AmpeStatus.communication_failed;
    }
};

pub const TriggersOff: Triggers = .{
    .accept = .off,
    .err = .off,
    .connect = .off,
    .notify = .off,
    .pool = .off,
    .recv = .off,
    .send = .off,
    .timeout = .off,
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

pub const Side = enum(u1) {
    client = 0,
    server = 1,
};

pub const TriggeredSkt = union(enum) {
    notification: NotificationSkt,
    accept: AcceptSkt,
    io: IoSkt,
    dumb: DumbSkt,

    pub fn triggers(tsk: *TriggeredSkt) !Triggers {
        const ret = switch (tsk.*) {
            .notification => try tsk.*.notification.triggers(),
            .accept => try tsk.*.accept.triggers(),
            .io => try tsk.*.io.triggers(),
            inline else => return .{},
        };

        if (DBG) {
            _ = internal.triggeredSkts.UnpackedTriggers.fromTriggers(ret);
        }

        return ret;
    }

    pub inline fn getSocket(tsk: *TriggeredSkt) ?Socket {
        return switch (tsk.*) {
            .notification => tsk.*.notification.getSocket(),
            .accept => tsk.*.accept.getSocket(),
            .io => tsk.*.io.getSocket(),
            inline else => return null,
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
        sndmsg.assert();

        return switch (tsk.*) {
            .io => tsk.*.io.addToSend(sndmsg),
            // Any attempt to send to listener is interpreted as close
            .accept => {
                sndmsg.*.bhdr.dumpMeta("addToSend ChannelClosed");
                assert(false);
                return AmpeError.ChannelClosed;
            },
            inline else => {
                sndmsg.*.bhdr.dumpMeta("addToSend NotAllowed");
                assert(false);
                return AmpeError.NotAllowed;
            },
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
            inline else => return .{},
        };
    }

    pub fn deinit(tsk: *TriggeredSkt) void {
        return switch (tsk.*) {
            .notification => tsk.*.notification.deinit(),
            .accept => tsk.*.accept.deinit(),
            .io => tsk.*.io.deinit(),
            .dumb => tsk.*.dumb.deinit(),
        };
    }

    pub fn refreshPointers(tsk: *TriggeredSkt) void {
        switch (tsk.*) {
            .io => tsk.*.io.refreshPointers(),
            else => {},
        }
    }
};

const NotificationTriggers: Triggers = .{
    .notify = .on,
};

pub const NotificationSkt = struct {
    skt: *Skt = undefined,

    pub fn init(skt: *Skt) NotificationSkt {
        return .{
            .skt = skt,
        };
    }

    pub fn triggers(nskt: *NotificationSkt) !Triggers {
        _ = nskt;
        return NotificationTriggers;
    }

    pub inline fn getSocket(self: *NotificationSkt) ?Socket {
        return self.skt.socket;
    }

    pub fn tryRecvNotification(nskt: *NotificationSkt) !Notification {
        return Notifier.recv_notification(nskt.skt.socket.?);
    }

    pub fn deinit(nskt: *NotificationSkt) void {
        // Notification sockets will be closed by ampe itself
        _ = nskt;
        return;
    }
};

const AcceptTriggers: Triggers = .{
    .accept = .on,
};

pub const AcceptSkt = struct {
    skt: Skt = .{},

    pub fn init(wlcm: *Message, sc: *SocketCreator) AmpeError!AcceptSkt {
        return .{
            .skt = try sc.parse(wlcm),
        };
    }

    pub fn triggers(askt: *AcceptSkt) !Triggers {
        _ = askt;
        return AcceptTriggers;
    }

    pub inline fn getSocket(self: *AcceptSkt) ?Socket {
        return self.skt.socket;
    }

    pub fn tryAccept(askt: *AcceptSkt) AmpeError!?Skt {
        return askt.skt.accept();
    }

    pub fn deinit(askt: *AcceptSkt) void {
        askt.skt.deinit();
        return;
    }
};

pub const IoSkt = struct {
    pool: *internal.Pool = undefined,
    side: Side = undefined,
    cn: message.ChannelNumber = undefined,
    skt: Skt = .{},
    connected: bool = false,
    sendQ: MessageQueue = .{},
    currSend: MsgSender = .{},
    byeWasSend: bool = false,
    currRecv: MsgReceiver = .{},
    byeResponseReceived: bool = false,
    alreadySend: ?*Message = null,

    pub fn initServerSide(pool: *internal.Pool, cn: message.ChannelNumber, sskt: Skt) AmpeError!IoSkt {
        var ret: IoSkt = .{
            .pool = pool,
            .side = .server,
            .cn = cn,
            .skt = sskt,
            .connected = true,
            .sendQ = .{},
            .currSend = MsgSender.init(),
            .currRecv = MsgReceiver.init(pool),
            .byeWasSend = false,
            .byeResponseReceived = false,
            .alreadySend = null,
        };

        ret.currSend.set(cn, sskt.socket.?) catch unreachable;
        ret.currRecv.set(cn, sskt.socket.?) catch unreachable;

        return ret;
    }

    pub fn initClientSide(ios: *IoSkt, pool: *internal.Pool, hello: *Message, sc: *SocketCreator) AmpeError!void {
        ios.pool = pool;
        ios.side = .client;
        ios.cn = hello.bhdr.channel_number;
        ios.skt = try sc.parse(hello);
        ios.connected = false;
        ios.sendQ = .{};
        ios.currSend = MsgSender.init();
        ios.currRecv = MsgReceiver.init(pool);
        ios.byeResponseReceived = false;
        ios.byeWasSend = false;
        ios.alreadySend = null;

        hello.assert();

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

            if (!ioskt.connected) {
                return .{
                    .connect = .on,
                };
            }
        }

        var ret: Triggers = .{};
        if (!ioskt.sendQ.empty() or ioskt.currSend.started()) {
            if (!ioskt.byeWasSend) {
                ret.send = .on;
            }
        }

        if (!ioskt.byeResponseReceived) {
            const recvPossible = try ioskt.currRecv.recvIsPossible();

            if (recvPossible) {
                ret.recv = .on;
            } else {
                assert(ioskt.currRecv.ptrg == .on);
                ret.pool = .on;
            }
        }

        if (DBG) {
            const utrgs = internal.triggeredSkts.UnpackedTriggers.fromTriggers(ret);
            _ = utrgs;
        }

        return ret;
    }

    pub inline fn getSocket(self: *IoSkt) ?Socket {
        return self.skt.socket;
    }

    pub fn refreshPointers(ioskt: *IoSkt) void {
        ioskt.currRecv.refreshPointers();
        ioskt.currSend.refreshPointers();
    }

    pub fn addToSend(ioskt: *IoSkt, sndmsg: *Message) AmpeError!void {
        sndmsg.assert();

        if (sndmsg.bhdr.proto._internalA == .on) {
            ioskt.sendQ.pushFront(sndmsg);
        } else {
            ioskt.sendQ.enqueue(sndmsg);
        }
        return;
    }

    pub fn addForRecv(ioskt: *IoSkt, rcvmsg: *Message) AmpeError!void {
        return ioskt.currRecv.attach(rcvmsg);
    }

    pub fn tryConnect(ioskt: *IoSkt) AmpeError!bool {

        // Now it's ok to connect to already connected socket
        ioskt.connected = ioskt.skt.connect() catch |err| {
            // log.debug("<{d}> connect failed on channel {d} with error {any} ", .{ getCurrentTid(), ioskt.*.cn, err });
            return err;
        };

        if (ioskt.connected) {
            ioskt.postConnect();
        }

        return ioskt.connected;
    }

    fn postConnect(ioskt: *IoSkt) void {
        ioskt.currSend.set(ioskt.cn, ioskt.skt.socket.?) catch unreachable;
        ioskt.currRecv.set(ioskt.cn, ioskt.skt.socket.?) catch unreachable;

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

            // Replace "remote" channel_number with "local" one
            received.?.bhdr.channel_number = ioskt.cn;

            if (DBG) {
                if ((received.?.bhdr.proto.getType() == .hello) or (received.?.bhdr.proto.getType() == .bye)) {
                    received.?.bhdr.dumpMeta("<--rcv ");
                }
            }

            if (received.?.bhdr.proto.opCode == .ByeResponse) {
                ioskt.byeResponseReceived = true;
            }

            ret.enqueue(received.?);

            if (ioskt.byeResponseReceived) {
                break;
            }
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

            if (wasSend.?.bhdr.proto.getType() == .bye) {
                ioskt.byeWasSend = true;
            }

            ret.enqueue(wasSend.?);

            if (ioskt.byeWasSend) {
                break;
            }
        }

        return ret;
    }

    pub fn deinit(ioskt: *IoSkt) void {
        ioskt.skt.deinit();
        message.clearQueue(&ioskt.sendQ);

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
    ready: bool = false,
    cn: message.ChannelNumber = undefined,
    socket: Socket = undefined,
    msg: ?*Message = null,
    bh: BinaryHeader = .{},
    iov: [3]std.posix.iovec_const = undefined,
    vind: usize = 3,
    sndlen: usize = 0,
    iovPrepared: bool = false,

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

    pub fn refreshPointers(ms: *MsgSender) void {
        if (ms.msg == null or !ms.iovPrepared) return;

        // 1. Header in message
        if (ms.vind == 0) {
            const bh_ptr: [*]u8 = @ptrCast(@constCast(&ms.msg.?.bhdr));
            const consumed = BinaryHeader.BHSIZE - ms.iov[0].len;
            ms.iov[0].base = @ptrCast(@constCast(&bh_ptr[consumed]));
        }

        // 2. Text Headers
        if (ms.vind <= 1) {
            const hlen = ms.msg.?.actual_headers_len();
            if (hlen > 0) {
                const consumed = hlen - ms.iov[1].len;
                ms.iov[1].base = @ptrCast(@constCast(ms.msg.?.thdrs.buffer.body().?.ptr + consumed));
            }
        }

        // 3. Body
        if (ms.vind <= 2) {
            const blen = ms.msg.?.actual_body_len();
            if (blen > 0) {
                const consumed = blen - ms.iov[2].len;
                ms.iov[2].base = @ptrCast(@constCast(ms.msg.?.body.body().?.ptr + consumed));
            }
        }
    }

    pub fn attach(ms: *MsgSender, msg: *Message) !void {
        if (!ms.ready) {
            return AmpeError.NotAllowed;
        }

        if (ms.msg) |m| {
            m.destroy();
        }

        msg.assert();

        ms.msg = msg;
        ms.iovPrepared = false;

        return;
    }

    inline fn prepare(ms: *MsgSender) void {
        const hlen = ms.msg.?.actual_headers_len();
        const blen = ms.msg.?.actual_body_len();

        ms.msg.?.bhdr.@"<bl>" = @intCast(blen);
        ms.msg.?.bhdr.@"<thl>" = @intCast(hlen);

        // Save native-endian and marshal Big-Endian into message directly
        ms.bh = ms.msg.?.bhdr;
        ms.bh.toBytes(@ptrCast(&ms.msg.?.bhdr));

        ms.vind = 0;

        assert(@sizeOf(BinaryHeader) == 16);
        ms.msg.?.assert();

        ms.iov[0] = .{ .base = @ptrCast(&ms.msg.?.bhdr), .len = 16 };
        ms.sndlen = 16;

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
        if (ret) |m| {
            if (ms.iovPrepared and ms.vind == 0 and ms.iov[0].len > 0) {
                m.bhdr = ms.bh;
            }
        }
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

        ms.msg.?.assert();

        if (!ms.iovPrepared) {
            ms.prepare();
        }

        while (ms.vind < 3) : (ms.vind += 1) {
            while (ms.iov[ms.vind].len > 0) {
                const wasSend = sendBuf(ms.socket, ms.iov[ms.vind].base[0..ms.iov[ms.vind].len]) catch |err| {
                    if (ms.vind == 0 and ms.iov[0].len > 0) {
                        ms.msg.?.bhdr = ms.bh;
                    }
                    return err;
                };
                if (wasSend == null) {
                    return null;
                }
                ms.iov[ms.vind].base += wasSend.?;
                ms.iov[ms.vind].len -= wasSend.?;
                ms.sndlen -= wasSend.?;
            }
        }

        // Entire message fully sent - restore native-endian
        ms.msg.?.bhdr = ms.bh;

        const ret = ms.msg;
        ms.msg = null;

        if (DBG) {
            if (ret != null) {
                if ((ret.?.bhdr.proto.getType() == .hello) or (ret.?.bhdr.proto.getType() == .bye)) {
                    ret.?.bhdr.dumpMeta("-->snd ");
                }
            }
        }

        return ret;
    }

    pub fn sendBuf(socket: Socket, buf: []const u8) AmpeError!?usize {
        if (builtin.os.tag == .windows) {
            const ws2_32 = std.os.windows.ws2_32;
            const rc: i32 = ws2_32.send(socket, buf.ptr, @intCast(buf.len), 0);
            if (rc >= 0) return @intCast(rc);

            const err: ws2_32.WinsockError = ws2_32.WSAGetLastError();
            switch (err) {
                .WSAEWOULDBLOCK => return null,
                .WSAECONNRESET, .WSAECONNABORTED, .WSAESHUTDOWN => return AmpeError.PeerDisconnected,
                else => return AmpeError.CommunicationFailed,
            }
        }

        var wasSend: usize = 0;
        wasSend = std.posix.send(socket, buf, 0) catch |e| {
            switch (e) {
                std.posix.SendError.WouldBlock => {
                    return null;
                },
                std.posix.SendError.ConnectionResetByPeer, std.posix.SendError.BrokenPipe => return AmpeError.PeerDisconnected,
                else => return AmpeError.CommunicationFailed,
            }
        };

        if (wasSend == 0) {
            return null;
        }

        return wasSend;
    }

    pub fn sendBufTo(socket: Socket, buf: []const u8) AmpeError!?usize {
        if (builtin.os.tag == .windows) {
            const ws2_32 = std.os.windows.ws2_32;
            const rc: i32 = ws2_32.sendto(socket, buf.ptr, @intCast(buf.len), 0, null, 0);
            if (rc >= 0) return @intCast(rc);

            const err: ws2_32.WinsockError = ws2_32.WSAGetLastError();
            switch (err) {
                .WSAEWOULDBLOCK => return null,
                else => return AmpeError.CommunicationFailed,
            }
        }

        var wasSend: usize = 0;
        wasSend = std.posix.sendto(socket, buf, 0, null, 0) catch |e| {
            switch (e) {
                std.posix.SendError.WouldBlock => {
                    return null;
                },
                else => return AmpeError.CommunicationFailed,
            }
        };

        if (wasSend == 0) {
            return null;
        }

        return wasSend;
    }
};

pub const MsgReceiver = struct {
    ready: bool = false,
    cn: message.ChannelNumber = undefined,
    socket: Socket = undefined,
    pool: *internal.Pool = undefined,
    ptrg: Trigger = .off,
    bh: [BinaryHeader.BHSIZE]u8 = [_]u8{'-'} ** BinaryHeader.BHSIZE,
    iov: [3]std.posix.iovec = undefined,
    vind: usize = 3,
    rcvlen: usize = 0,
    msg: ?*Message = null,

    pub fn init(pool: *internal.Pool) MsgReceiver {
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
        assert(@sizeOf(message.BinaryHeader) == 16);

        mr.iov[0] = .{ .base = @ptrCast(&mr.msg.?.bhdr), .len = 16 };
        mr.iov[1] = .{ .base = mr.msg.?.thdrs.buffer.buffer.?.ptr, .len = 0 };
        mr.iov[2] = .{ .base = mr.msg.?.body.buffer.?.ptr, .len = 0 };

        mr.vind = 0;
        mr.rcvlen = 0;
        return;
    }

    fn getFromPool(mr: *MsgReceiver) AmpeError!*Message {
        const ret = mr.pool.get(.poolOnly) catch |e| {
            switch (e) {
                AmpeError.PoolEmpty => {
                    mr.ptrg = .on;
                    return e;
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

        if (DBG) {
            if (mr.msg == null) {
                log.err("MsgReceiver.recv: mr.msg is NULL after getFromPool/prepareMsg", .{});
                return AmpeError.AllocationFailed;
            }
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
                // Header received into mr.msg.?.bhdr - capture raw and unmarshal
                @memcpy(&mr.bh, std.mem.asBytes(&mr.msg.?.bhdr));
                mr.msg.?.bhdr.fromBytes(&mr.bh);

                if (mr.msg.?.bhdr.@"<thl>" > 0) {
                    mr.iov[1].len = mr.msg.?.bhdr.@"<thl>";

                    // Allow direct receive to the buffer of appendable without copy
                    mr.msg.?.thdrs.buffer.alloc(mr.iov[1].len) catch {
                        return AmpeError.AllocationFailed;
                    };
                    mr.msg.?.thdrs.buffer.change(mr.iov[1].len) catch unreachable;
                    mr.iov[1].base = mr.msg.?.thdrs.buffer.buffer.?.ptr;
                }
                if (mr.msg.?.bhdr.@"<bl>" > 0) {
                    mr.iov[2].len = mr.msg.?.bhdr.@"<bl>";

                    // Allow direct receive to the buffer of appendable without copy
                    mr.msg.?.body.alloc(mr.iov[2].len) catch {
                        return AmpeError.AllocationFailed;
                    };
                    mr.msg.?.body.change(mr.iov[2].len) catch unreachable;
                    mr.iov[2].base = mr.msg.?.body.buffer.?.ptr;
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

    pub fn refreshPointers(mr: *MsgReceiver) void {
        const m = mr.msg orelse return;

        // 1. Header in message (if still receiving header)
        if (mr.rcvlen < 16) {
            const bh_ptr: [*]u8 = @ptrCast(@constCast(&m.bhdr));
            mr.iov[0].base = @ptrCast(@constCast(&bh_ptr[mr.rcvlen]));
            mr.iov[0].len = 16 - mr.rcvlen;
        }

        // 2. Message buffers (if message is active)
        // Text Headers
        if (m.thdrs.buffer.buffer) |buf| {
            if (mr.vind == 1) {
                const consumed = m.bhdr.@"<thl>" - mr.iov[1].len;
                mr.iov[1].base = buf.ptr + consumed;
            } else if (mr.vind < 1) {
                mr.iov[1].base = buf.ptr;
            }
        }
        // Body
        if (m.body.buffer) |buf| {
            if (mr.vind == 2) {
                const consumed = m.bhdr.@"<bl>" - mr.iov[2].len;
                mr.iov[2].base = buf.ptr + consumed;
            } else if (mr.vind < 2) {
                mr.iov[2].base = buf.ptr;
            }
        }
    }

    pub fn deinit(mr: *MsgReceiver) void {
        if (mr.msg) |m| {
            m.destroy();
        }
        mr.msg = null;
        mr.rcvlen = 0;
        return;
    }

    pub fn recvToBuf(socket: Socket, buf: []u8) AmpeError!?usize {
        if (builtin.os.tag == .windows) {
            const ws2_32 = std.os.windows.ws2_32;
            const rc: i32 = ws2_32.recv(socket, buf.ptr, @intCast(buf.len), 0);
            if (rc > 0) return @intCast(rc);
            if (rc == 0) return AmpeError.PeerDisconnected;

            const err: ws2_32.WinsockError = ws2_32.WSAGetLastError();
            switch (err) {
                .WSAEWOULDBLOCK => return null,
                .WSAECONNRESET, .WSAECONNABORTED, .WSAESHUTDOWN => return AmpeError.PeerDisconnected,
                else => return AmpeError.CommunicationFailed,
            }
        }

        var wasRecv: usize = 0;
        wasRecv = std.posix.recv(socket, buf, 0) catch |e| {
            switch (e) {
                std.posix.RecvFromError.WouldBlock => {
                    return null;
                },
                std.posix.RecvFromError.ConnectionResetByPeer, std.posix.RecvFromError.ConnectionRefused => return AmpeError.PeerDisconnected,
                else => return AmpeError.CommunicationFailed,
            }
        };

        return wasRecv;
    }
};

pub const DumbSkt = struct {
    pub fn deinit(dskt: *DumbSkt) void {
        _ = dskt;
        return;
    }
};

const tofu = @import("../tofu.zig");
const internal = @import("internal.zig");

const message = tofu.message;
const MessageQueue = message.MessageQueue;
const Trigger = message.Trigger;
const BinaryHeader = message.BinaryHeader;
const Message = message.Message;
const DBG = tofu.DBG;
const AmpeError = tofu.status.AmpeError;
const AmpeStatus = tofu.status.AmpeStatus;

const SocketCreator = internal.SocketCreator;
const Skt = internal.Skt;
const Notifier = internal.Notifier;
const Notification = Notifier.Notification;

const std = @import("std");
const builtin = @import("builtin");
const Thread = std.Thread;
const getCurrentTid = Thread.getCurrentId;
const Socket = internal.Socket;
const log = std.log;
const assert = std.debug.assert;
