// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Skt = struct {
    socket: std.posix.socket_t = undefined,
    address: std.net.Address = undefined,

    pub fn deinit(skr: *Skt) void {
        posix.close(skr.socket);
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

        const address = std.net.Address.resolveIp(cnf.ip.?, cnf.ip.?) catch {
            return AmpeError.InvalidAddress;
        };

        const skt = createListenerSocket(&address) catch {
            return AmpeError.InvalidAddress;
        };

        return skt;
    }

    pub fn createTcpClient(sc: *SocketCreator) AmpeError!Skt {
        const cnf: *TCPClientConfigurator = &sc.cnfgr.tcp_server;

        const list = std.net.getAddressList(sc.allocator, cnf.addr.?, cnf.port.?) catch {
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
        return createUdsListener(sc.cnfgr.uds_server.path);
    }

    pub fn createUdsListener(path: []const u8) AmpeError!Skt {
        var address = std.net.Address.initUnix(path) catch {
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
    fn createListenerSocket(address: *std.net.Address) !Skt {
        var ret: Skt = .{
            .address = address.*,
            .socket = undefined,
        };

        const kernel_backlog = 64;
        ret.socket = try posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(ret.socket);

        try posix.setsockopt(ret.socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
        try posix.bind(ret.socket, &ret.address.any, address.getOsSockLen());
        try posix.listen(ret.socket, kernel_backlog);

        // set address to the OS-chosen information - check for UDS!!!.
        var slen: posix.socklen_t = address.getOsSockLen();
        try posix.getsockname(ret.socket, &ret.address.any, &slen);

        return ret;
    }
};

pub fn createConnectSocket(address: *std.net.Address) !Skt {
    var ret: Skt = .{
        .address = address.*,
        .socket = undefined,
    };

    ret.socket = try posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(ret.socket);

    return ret;
}

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
};

const NotificationTriggers: Triggers = .{
    .notify = .on,
};

pub const NotificationSkt = struct {
    socket: Socket = undefined,

    pub fn init(socket: Socket) NotificationSkt { // prnt.ntfr.receiver
        return .{
            .socket = socket,
        };
    }

    pub fn triggers(nskt: *NotificationSkt) ?Triggers {
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

    pub fn triggers(askt: *AcceptSkt) ?Triggers {
        _ = askt;
        return AcceptTriggers;
    }

    pub inline fn getSocket(self: *AcceptSkt) Socket {
        return self.skt.socket;
    }

    pub fn tryAccept(askt: *AcceptSkt) AmpeError!?Skt {
        var skt: Skt = .{};

        var addr_len = @sizeOf(skt.address);

        skt.socket = std.posix.accept(
            askt.skt.socket,
            &skt.address.any,
            @ptrCast(&addr_len),
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

        return skt;
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
    skt: Skt = undefined,
    connected: bool = undefined,
    sendQ: MessageQueue = undefined,
    currSend: MsgSender = undefined,
    currRecv: MsgReceiver = undefined,
    lastSend: ?*Message = undefined,

    pub fn initServerSide(pool: *Pool, sskt: Skt) AmpeError!IoSkt {
        var ret: IoSkt = .{
            .pool = pool,
            .side = .server,
            .skt = sskt,
            .connected = true,
            .sendQ = .{},
            .currSend = MsgSender.init(),
            .currRecv = MsgReceiver.init(),
            .lastSend = null,
        };

        ret.currSend.set(sskt.socket) catch unreachable;
        ret.currRecv.set(sskt.socket) catch unreachable;

        return ret;
    }

    pub fn initClientSide(pool: *Pool, hello: *Message, sc: *SocketCreator) AmpeError!IoSkt {
        const ret = .{
            .pool = pool,
            .side = .client,
            .skt = try sc.fromMessage(hello),
            .connected = false,
            .sendQ = .{},
            .currSend = MsgSender.init(),
            .currRecv = MsgReceiver.init(),
            .hello = hello,
        };

        errdefer ret.skt.deinit();

        ret.connected = true;

        std.posix.connect(
            ret.skt.socket,
            &ret.skt.addr.any,
            ret.skt.addr.getOsSockLen(),
        ) catch |e| switch (e) {
            std.posix.ConnectError.WouldBlock => {
                ret.connected = false;
            },
            else => return AmpeError.PeerDisconnected,
        };

        if (ret.connected) {
            ret.postConnect;
        }

        return ret;
    }

    pub fn triggers(ioskt: *IoSkt) ?Triggers {
        if (!ioskt.connected) {
            return .{
                .connect = .on,
            };
        }
        var ret: Triggers = .{};
        if (!ioskt.sendQ.empty() or ioskt.currSend.started()) {
            ret.send = .on;
        }

        if (ioskt.currRecv.started()) {
            ret.recv = .on;
        } else {
            ret.pool = .on;
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

    // tryConnect is called by Distributor for succ. connection.
    // So actually  tryConnect functionality - to allow further Hello send.
    // For the failed connection Distributor uses detach: get Hello request , convert to filed Hello response...
    pub fn tryConnect(ioskt: *IoSkt) AmpeError!void {
        if (ioskt.connected) {
            return AmpeError.NotAllowed;
        }

        ioskt.connected = true;

        ioskt.postConnect();
    }

    fn postConnect(ioskt: *IoSkt) void {
        ioskt.currSend.set(ioskt.skt.socket) catch unreachable;
        ioskt.currRecv.set(ioskt.skt.socket) catch unreachable;

        ioskt.currSend.attach(ioskt.hello) catch unreachable;
        ioskt.hello = null;
        return;
    }

    pub fn detach(ioskt: *IoSkt) ?*Message {
        const ret = ioskt.lastSend;
        ioskt.lastSend = null;
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
                        return null;
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

    pub fn trySend(ioskt: *IoSkt) AmpeError!?*Message {
        var ret: ?*Message = null;

        if (!ioskt.connected) {
            return AmpeError.NotAllowed;
        }

        while (true) {
            if (!ioskt.currSend.started()) {
                if (ioskt.sendQ.empty()) {
                    break;
                }

                ioskt.lastSend = ioskt.sendQ.dequeue();

                ioskt.currSend.attach(ioskt.lastSend) catch unreachable;

                if (ret != null) {
                    // We already have message and prepared sender for the next send
                    // on the next poll loop
                    break;
                }
            }

            const wasSend = try ioskt.currSend.send();
            if (wasSend == null) {
                break;
            }
            ioskt.lastSend = null;
            ret = wasSend.?;
        }
        return ret;
    }

    pub fn deinit(ioskt: *IoSkt) void {
        ioskt.skt.deinit();
        ioskt.sendQ.destroy();
        if (ioskt.currSend != null) {
            ioskt.currSend.?.destroy();
            ioskt.currSend = null;
        }
        if (ioskt.currRecv != null) {
            ioskt.currRecv.?.destroy();
            ioskt.currRecv = null;
        }
        if (ioskt.lastSend != null) {
            ioskt.lastSend.?.destroy();
            ioskt.lastSend = null;
        }
        return;
    }
};

pub const MsgSender = struct {
    ready: bool = undefined,
    socket: Socket = undefined,
    msg: ?*Message = undefined,
    bh: [BinaryHeader.BHSIZE]u8 = undefined,
    iov: [3]std.posix.iovec_const = undefined,
    vind: usize = undefined,
    sndlen: usize = undefined,

    pub fn init() MsgSender {
        return .{
            .ready = false,
            .msg = null,
            .sndlen = 0,
            .vind = 3,
        };
    }

    pub fn set(ms: *MsgSender, socket: Socket) !void {
        if (ms.ready) {
            return AmpeError.NotAllowed;
        }
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
        msg.bhdr.toBytes(&ms.bh);
        ms.vind = 0;

        ms.iov[0] = .{ .base = &ms.bh, .len = ms.bh.len };
        ms.sndlen = ms.bh.len;

        const hlen = msg.actual_headers_len();
        if (hlen == 0) {
            ms.iov[1] = .{ .base = null, .len = 0 };
        } else {
            ms.iov[1] = .{ .base = msg.thdrs.buffer.body().?, .len = hlen };
            ms.sndlen += hlen;
        }

        const blen = msg.actual_body_len();
        if (blen == 0) {
            ms.iov[2] = .{ .base = null, .len = 0 };
        } else {
            ms.iov[2] = .{ .base = msg.body.body().?, .len = blen };
            ms.sndlen += blen;
        }

        return;
    }

    pub inline fn started(ms: *MsgSender) bool {
        return (ms.msg != null);
    }

    pub fn dettach(ms: *MsgSender) ?*Message {
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
            return error.NothingToSend; // to  prevent bug
        }

        while (ms.vind < 3) : (ms.vind += 1) {
            while (ms.iov[ms.vind].len > 0) {
                const wasSend = std.posix.send(ms.socket, ms.iov[ms.vind].base[0..ms.iov[ms.vind].len], 0) catch |e| {
                    switch (e) {
                        std.posix.SendError.WouldBlock => return null,
                        std.posix.SendError.ConnectionResetByPeer, std.posix.SendError.BrokenPipe => return AmpeError.PeerDisconnected,
                        else => return AmpeError.CommunicatioinFailed,
                    }
                };

                ms.iov[ms.vind].base += wasSend;
                ms.iov[ms.vind].len -= wasSend;
                ms.sndlen -= wasSend;

                if (ms.sndlen > 0) {
                    continue;
                }

                const ret = ms.msg;
                ms.msg = null;
                return ret;
            }
        }
        return error.NothingToSend; // to  prevent bug
    }
};

pub const MsgReceiver = struct {
    ready: bool = undefined,
    socket: Socket = undefined,
    pool: *Pool = undefined,
    ptrg: Trigger = undefined,
    bh: [BinaryHeader.BHSIZE]u8 = undefined,
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

    pub fn set(mr: *MsgReceiver, socket: Socket) !void {
        if (mr.ready) {
            return AmpeError.NotAllowed;
        }
        mr.socket = socket;
        mr.ready = true;
    }

    pub inline fn started(mr: *MsgReceiver) bool {
        return (mr.msg != null);
    }

    pub fn recv(mr: *MsgReceiver) !?*Message {
        if (!mr.ready) {
            return AmpeError.NotAllowed;
        }
        if (mr.msg == null) {
            mr.msg = mr.pool.get(.poolOnly) catch |e| {
                mr.ptrg = .on;
                switch (e) {
                    error.ClosedPool => return AmpeError.NotAllowed,
                    error.EmptyPool => return AmpeError.PoolEmpty,
                    else => return AmpeError.AllocationFailed,
                }
            };

            mr.msg.?.reset();

            mr.iov[0] = .{ .base = &mr.bh, .len = mr.bh.len };
            mr.iov[1] = .{ .base = mr.msg.?.thdrs.buffer.buffer.?, .len = 0 };
            mr.iov[2] = .{ .base = mr.msg.?.body.buffer.?, .len = 0 };

            mr.vind = 0;
            mr.rcvlen = 0;
        }

        while (mr.vind < 3) : (mr.vind += 1) {
            while (mr.iov[mr.vind].len > 0) {
                const wasRecv = std.posix.recv(mr.socket, mr.iov[mr.vind].base[0..mr.iov[mr.vind].len], 0) catch |e| {
                    switch (e) {
                        std.posix.RecvFromError.WouldBlock => return null,
                        std.posix.RecvFromError.ConnectionResetByPeer, std.posix.RecvFromError.ConnectionRefused => return AmpeError.PeerDisconnected,
                        else => return AmpeError.CommunicatioinFailed,
                    }
                };

                mr.iov[mr.vind].base += wasRecv;
                mr.iov[mr.vind].len -= wasRecv;
                mr.rcvlen += wasRecv;
            }

            if (mr.vind == 0) {
                mr.msg.?.bhdr.fromBytes(mr.bh);
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
                    mr.msg.?.body.buffer.alloc(mr.iov[2].len) catch {
                        return AmpeError.AllocationFailed;
                    };
                    mr.msg.?.body.buffer.change(mr.iov[2].len) catch unreachable;
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

pub const TriggeredSkt = union(enum) {
    notification: NotificationSkt,
    accept: AcceptSkt,
    io: IoSkt,

    pub fn triggers(tsk: *TriggeredSkt) ?Triggers {
        return switch (tsk.*) {
            inline else => |sk| sk.triggers(),
        };
    }

    pub inline fn getSocket(tsk: *TriggeredSkt) Socket {
        return switch (tsk.*) {
            inline else => |sk| sk.getSocket(),
        };
    }

    pub fn tryRecvNotification(tsk: *TriggeredSkt) !Notification {
        return switch (tsk.*) {
            .notification => |sk| sk.tryRecvNotification(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryAccept(tsk: *TriggeredSkt) !?Skt {
        return switch (tsk.*) {
            .accept => |sk| sk.tryAccept(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryConnect(tsk: *TriggeredSkt) !void {
        return switch (tsk.*) {
            .io => |sk| sk.tryConnect(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn tryRecv(tsk: *TriggeredSkt) !MessageQueue {
        return switch (tsk.*) {
            .io => |sk| sk.tryRecv(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn trySend(tsk: *TriggeredSkt) !?*Message {
        return switch (tsk.*) {
            .io => |sk| sk.trySend(),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn addToSend(tsk: *TriggeredSkt, sndmsg: *Message) !void {
        return switch (tsk.*) {
            .io => |sk| sk.addToSend(sndmsg),
            inline else => return AmpeError.NotAllowed,
        };
    }

    pub fn detach(tsk: *TriggeredSkt) ?*Message { // consider MessageQueue
        return switch (tsk.*) {
            .io => |sk| sk.detach(),
            inline else => return null,
        };
    }

    pub fn deinit(tsk: *TriggeredSkt) void {
        return switch (tsk.*) {
            inline else => |sk| sk.deinit(),
        };
    }
};

const message = @import("../message.zig");
const MessageType = message.MessageType;
const MessageMode = message.MessageMode;
const OriginFlag = message.OriginFlag;
const MoreMessagesFlag = message.MoreMessagesFlag;
const ProtoFields = message.ProtoFields;
const BinaryHeader = message.BinaryHeader;
const TextHeader = message.TextHeader;
const TextHeaderIterator = @import("../TextHeaderIterator.zig");
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
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Socket = std.posix.socket_t;
