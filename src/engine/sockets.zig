// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Trigger = enum(u1) {
    on = 1,
    off = 0,
};

pub const Triggers = packed struct(u6) {
    notify: Trigger = .off,
    accept: Trigger = .off,
    connect: Trigger = .off,
    send: Trigger = .off,
    recv: Trigger = .off,
    pool: Trigger = .off,
};

pub const PolledSkt = union(enum) {
    notification: NotificationSkt,
    accept: AcceptSkt,
    io: IoSkt,
};

pub const Skt = struct {
    socket: std.posix.socket_t = undefined,
    address: std.net.Address = undefined,

    pub fn deinit(skr: *Skt) void {
        posix.close(skr.socket);
    }
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
        return null;
    }

    pub fn tryRecvNotification(nskt: *NotificationSkt) !Notification {
        _ = nskt;
        return AMPError.NotImplementedYet;
    }

    pub fn deinit(nskt: *NotificationSkt) void {
        _ = nskt;
        return;
    }
};

pub const AcceptSkt = struct {
    skt: Skt = undefined,

    pub fn init(wlcm: *Message) AMPError!AcceptSkt {
        _ = wlcm;
        return AMPError.NotImplementedYet;
    }

    pub fn triggers(askt: *AcceptSkt) ?Triggers {
        _ = askt;
        return null;
    }

    pub fn tryAccept(askt: *AcceptSkt) AMPError!?Skt {
        _ = askt;
        return AMPError.NotImplementedYet;
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
    // root: channels.ActiveChannel = undefined,
    skt: Skt = undefined,
    connected: bool = undefined,
    sendQ: MessageQueue = undefined,
    currSend: MsgSender = undefined,
    currRecv: MsgReceiver = undefined,
    hello: ?*Message = undefined,

    pub fn initServerSide(pool: *Pool, sskt: Skt) AMPError!IoSkt {
        var ret: IoSkt = .{
            .pool = pool,
            .side = .server,
            .skt = sskt,
            .connected = true,
            .sendQ = .{},
            .currSend = MsgSender.init(),
            .currRecv = MsgReceiver.init(),
            .hello = null,
        };

        ret.currSend.set(sskt.socket) catch unreachable;
        ret.currRecv.set(sskt.socket) catch unreachable;

        return ret;
    }

    pub fn initClientSide(pool: *Pool, hello: *Message) AMPError!IoSkt {
        return .{
            .pool = pool,
            .side = .client,
            .connected = false,
            .sendQ = .{},
            .currSend = MsgSender.init(),
            .currRecv = MsgReceiver.init(),
            .hello = hello,
        };
    }

    pub fn triggers(ioskt: *IoSkt) ?Triggers {
        _ = ioskt;
        return null;
    }

    pub fn addToSend(ioskt: *IoSkt, sndmsg: *Message) AMPError!void {
        _ = ioskt;
        _ = sndmsg;
        return AMPError.NotImplementedYet;
    }

    pub fn tryConnect(ioskt: *IoSkt) AMPError!?*Message {
        _ = ioskt;
        return AMPError.NotImplementedYet;
    }

    pub fn tryRecv(ioskt: *IoSkt) AMPError!?*Message {
        _ = ioskt;
        return AMPError.NotImplementedYet;
    }

    pub fn trySend(ioskt: *IoSkt) AMPError!?*Message {
        _ = ioskt;
        return AMPError.NotImplementedYet;
    }

    pub fn deinit(ioskt: *IoSkt) void {
        std.posix.close(ioskt.skt.socket);
        ioskt.sendQ.destroy();
        if (ioskt.currSend != null) {
            ioskt.currSend.?.destroy();
            ioskt.currSend = null;
        }
        if (ioskt.currRecv != null) {
            ioskt.currRecv.?.destroy();
            ioskt.currRecv = null;
        }
        if (ioskt.hello != null) {
            ioskt.hello.?.destroy();
            ioskt.hello = null;
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
            return AMPError.NotAllowed;
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
            return AMPError.NotAllowed;
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

    inline fn wasAttached(ms: *MsgSender) bool {
        return (ms.msg != null);
    }

    pub fn dettach(ms: *MsgSender) ?*Message {
        const ret = ms.msg;
        ms.msg = null;
        ms.sndlen = 0;
        ms.vind = 3;
        return ret;
    }

    pub fn send(ms: *MsgSender) !?*Message {
        if (!ms.ready) {
            return AMPError.NotAllowed;
        }
        if (ms.msg == null) {
            return error.NothingToSend; // to  prevent bug
        }

        while (ms.vind < 3) : (ms.vind += 1) {
            while (ms.iov[ms.vind].len > 0) {
                const wasSend = std.posix.send(ms.socket, ms.iov[ms.vind].base[0..ms.iov[ms.vind].len], 0) catch |e| {
                    switch (e) {
                        std.posix.SendError.WouldBlock => return null,
                        std.posix.SendError.ConnectionResetByPeer, std.posix.SendError.BrokenPipe => return AMPError.PeerDisconnected,
                        else => return AMPError.CommunicatioinFailed,
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
            return AMPError.NotAllowed;
        }
        mr.socket = socket;
        mr.ready = true;
    }

    inline fn recvStarted(mr: *MsgReceiver) bool {
        return (mr.msg != null);
    }

    pub fn recv(mr: *MsgReceiver) !?*Message {
        if (!mr.ready) {
            return AMPError.NotAllowed;
        }
        if (mr.msg == null) {
            mr.msg = mr.pool.get(.poolOnly) catch |e| {
                mr.ptrg = .on;
                switch (e) {
                    error.ClosedPool => return AMPError.NotAllowed,
                    error.EmptyPool => return AMPError.PoolEmpty,
                    else => return AMPError.AllocationFailed,
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
                        std.posix.RecvFromError.ConnectionResetByPeer, std.posix.RecvFromError.ConnectionRefused => return AMPError.PeerDisconnected,
                        else => return AMPError.CommunicatioinFailed,
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
                        return AMPError.AllocationFailed;
                    };
                    mr.msg.?.thdrs.buffer.change(mr.iov[1].len) catch unreachable;
                }
                if (mr.msg.?.bhdr.body_len > 0) {
                    mr.iov[2].len = mr.msg.?.bhdr.body_len;

                    // Allow direct receive to the buffer of appendable without copy
                    mr.msg.?.body.buffer.alloc(mr.iov[2].len) catch {
                        return AMPError.AllocationFailed;
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

pub const SocketCreator = struct {
    allocator: Allocator = undefined,
    cnfgr: Configurator = undefined,

    pub fn init(allocator: Allocator) SocketCreator {
        return .{
            .allocator = allocator,
            .cnfgr = .wrong,
        };
    }

    pub fn fromMessage(sc: *SocketCreator, msg: *Message) AMPError!Skt {
        const cnfgr = Configurator.fromMessage(msg);

        return sc.fromConfigurator(cnfgr);
    }

    pub fn fromConfigurator(sc: *SocketCreator, cnfgr: Configurator) AMPError!Skt {
        sc.cnfgr = cnfgr;

        switch (sc.cnfgr) {
            .wrong => return AMPError.InvalidAddress,
            .tcp_server => return sc.createTcpServer(),
            .tcp_client => return sc.createTcpClient(),
            .uds_server => return sc.createUdsServer(),
            .uds_client => return sc.createUdsServer(&sc.cnf.uds_client),
        }
    }

    pub fn createTcpServer(sc: *SocketCreator) AMPError!Skt {
        const cnf: *TCPServerConfigurator = &sc.cnfgr.tcp_server;

        const address = std.net.Address.resolveIp(cnf.ip.?, cnf.ip.?) catch {
            return AMPError.InvalidAddress;
        };

        const skt = createListenerSocket(&address) catch {
            return AMPError.InvalidAddress;
        };

        return skt;
    }

    pub fn createTcpClient(sc: *SocketCreator) AMPError!Skt {
        const cnf: *TCPClientConfigurator = &sc.cnfgr.tcp_server;

        const list = std.net.getAddressList(sc.allocator, cnf.addr.?, cnf.port.?) catch {
            return AMPError.InvalidAddress;
        };
        defer list.deinit();

        if (list.addrs.len == 0) {
            return AMPError.InvalidAddress;
        }

        for (list.addrs) |addr| {
            const ret = createConnectSocket(&addr) catch {
                continue;
            };
            return ret;
        }
        return AMPError.InvalidAddress;
    }

    pub fn createUdsServer(sc: *SocketCreator) AMPError!Skt {
        return createUdsListener(sc.cnfgr.uds_server.path);
    }

    pub fn createUdsListener(path: []const u8) AMPError!Skt {
        var address = std.net.Address.initUnix(path) catch {
            return AMPError.InvalidAddress;
        };

        const skt = createListenerSocket(&address) catch {
            return AMPError.InvalidAddress;
        };

        return skt;
    }

    pub fn createUdsClient(sc: *SocketCreator) AMPError!Skt {
        return createUdsSocket(sc.cnfgr.uds_client.path);
    }

    pub fn createUdsSocket(path: []const u8) AMPError!Skt {
        const address = std.net.Address.initUnix(path) catch {
            return AMPError.InvalidAddress;
        };

        const skt = createConnectSocket(&address) catch {
            return AMPError.InvalidAddress;
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

    ret.socket = posix.socket(ret.address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(ret.socket);

    return ret;
}

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

const Poller = @import("Poller.zig");

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
const AMPStatus = status.AMPStatus;
const AMPError = status.AMPError;
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

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Socket = std.posix.socket_t;
