// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const MessageType = enum(u3) {
    application = 0,
    welcome = 1,
    hello = 2,
    bye = 3,
    control = 4,
    shutdown = 5,
    _reserved6,
    _reserved7,
};

pub const MessageMode = enum(u2) {
    invalid = 0,
    request = 1,
    response = 2,
    signal = 3,
};

pub const OriginFlag = enum(u1) {
    application = 0,
    protocol = 1,
};

pub const MoreMessagesFlag = enum(u1) {
    last = 0,
    more = 1,
};

pub const ProtocolControlBitFlag = enum(u1) {
    zero = 0, // Used and filled exclusively by the protocol for housekeeping. Opaque to the application and must not be modified.
};

// Nested struct for protocol fields, now public
pub const ProtoFields = packed struct(u8) {
    mtype: MessageType = .application,
    mode: MessageMode = .invalid,
    origin: OriginFlag = .application,
    more: MoreMessagesFlag = .last,
    pcb: ProtocolControlBitFlag = .zero,
};

pub const ChannelNumber = u16;

pub const MessageID = u64;

pub const BinaryHeader = packed struct {
    channel_number: ChannelNumber = 0,
    proto: ProtoFields = .{},
    status: u8 = 0,
    message_id: MessageID = 0,
    text_headers_len: u16 = 0,
    body_len: u16 = 0,

    pub const BHSIZE = @sizeOf(BinaryHeader); // Should be 16 bytes

    pub fn clean(bh: *BinaryHeader) void {
        bh = .{};
    }

    pub fn toBytes(self: *BinaryHeader, buf: *[BHSIZE]u8) void {
        if (is_be) {
            // On BE platform, copy directly from self to buf
            const src_be: *[BHSIZE]u8 = @ptrCast(self);
            @memcpy(buf, src_be);
        } else {
            // On LE platform, create a temporary big-endian version
            var be_header = BinaryHeader{
                .channel_number = std.mem.nativeToBig(u16, self.channel_number),
                .proto = self.proto, // ProtoFields are single byte, no endianness needed
                .status = self.status, // Single byte, no endianness needed
                .message_id = std.mem.nativeToBig(u64, self.message_id),
                .text_headers_len = std.mem.nativeToBig(u16, self.text_headers_len),
                .body_len = std.mem.nativeToBig(u16, self.body_len),
            };
            const src_le: *[BHSIZE]u8 = @ptrCast(&be_header);
            @memcpy(buf, src_le);
        }
    }

    pub fn fromBytes(self: *BinaryHeader, bytes: *const [BHSIZE]u8) void {
        const dest: *[BHSIZE]u8 = @ptrCast(self);
        @memcpy(dest, bytes);

        // Convert from big-endian to native if little-endian
        if (!is_be) {
            self.channel_number = std.mem.bigToNative(u16, self.channel_number);
            self.message_id = std.mem.bigToNative(u64, self.message_id);
            self.text_headers_len = std.mem.bigToNative(u16, self.text_headers_len);
            self.body_len = std.mem.bigToNative(u16, self.body_len);
        }
    }
};

// TextHeader is name-value pair
pub const TextHeader = struct {
    name: []const u8 = undefined,
    value: []const u8 = undefined,
};

// Each of TextHeader are saved within TextHeaders buffer as 'name: value\r\n'.
// Length of Textheader is part of the message header( means it's know to receipient),
// so additional CRLF at the end of headers are not used.
pub const TextHeaders = struct {
    buffer: Appendable = .{},

    pub fn init(hdrs: *TextHeaders, allocator: Allocator, len: u16) !void {
        try hdrs.buffer.init(allocator, len, null);
        return;
    }

    pub fn deinit(hdrs: *TextHeaders) void {
        hdrs.buffer.deinit();
    }

    pub fn appendSafe(hdrs: *TextHeaders, it: *TextHeaderIterator) !void {
        var next = it.next();

        while (next != null) : (next = it.next()) {
            try hdrs.appendTextHeader(next);
        }

        return;
    }

    pub fn appendNotSafe(hdrs: *TextHeaders, textheaders: []const u8) !void {
        try hdrs.buffer.append(textheaders);
        return;
    }

    pub fn appendTextHeader(hdrs: *TextHeaders, th: *TextHeader) !void {
        return hdrs.append(th.name, th.value);
    }

    pub fn append(hdrs: *TextHeaders, name: []const u8, value: []const u8) !void {
        const nam = std.mem.trim(u8, name, " \t\r\n");
        if (nam.len == 0) {
            return error.BadName;
        }

        if (value.len == 0) {
            return error.BadValue;
        }

        try hdrs.buffer.append(nam);
        try hdrs.buffer.append(":");
        try hdrs.buffer.append(value);
        try hdrs.buffer.append("\r\n");
        return;
    }

    pub fn reset(hdrs: *TextHeaders) void {
        hdrs.buffer.reset();
        return;
    }

    pub fn hiter(hdrs: *TextHeaders) TextHeaderIterator {
        const raw = hdrs.buffer.body();
        return TextHeaderIterator.init(raw);
    }
};

pub const ValidCombination = enum(u4) {
    WelcomeRequest,
    WelcomeResponse,
    HelloRequest,
    HelloResponse,
    ByeRequest,
    ByeResponse,
    ByeSignal,
    ControlRequest,
    ControlResponse,
    ControlSignal,
    AppRequest,
    AppResponse,
    AppSignal,
    _reserved1,
    _reserved2,
    _reserved3,
};

pub const Message = struct {
    prev: ?*Message = null,
    next: ?*Message = null,

    bhdr: BinaryHeader = .{},
    thdrs: TextHeaders = .{},
    body: Appendable = .{},

    const blen: u16 = 256;
    const tlen: u16 = 64;

    pub fn create(allocator: Allocator) !*Message {
        var msg = try allocator.create(Message);
        msg.* = .{};
        msg.bhdr = .{};
        try msg.thdrs.init(allocator, tlen);
        try msg.body.init(allocator, blen, null);
        return msg;
    }

    pub fn reset(msg: *Message) void {
        msg.bhdr = .{};
        msg.thdrs.reset();
        msg.body.reset();
        return;
    }

    pub fn set(msg: *Message, bhdr: *BinaryHeader, thdrs: ?*TextHeaders, body: ?[]const u8) !void {
        msg.bhdr = bhdr.*;
        msg._reset();

        if (thdrs) |hdrs| {
            const it = hdrs.hiter();
            try msg.thdrs.appendSafe(it);
        }
        if (body) |data| {
            try msg.body.copy(data);
        }

        return msg.validate();
    }

    pub fn setNotSafe(msg: *Message, bhdr: *BinaryHeader, thdrs: ?[]const u8, body: ?[]const u8) !void {
        msg.bhdr = bhdr.*;
        msg._reset();

        if (thdrs) |hdrs| {
            try msg.thdrs.appendNotSafe(hdrs);
        }
        if (body) |data| {
            try msg.body.copy(data);
        }

        return;
    }

    inline fn validate(msg: *Message) !void {
        _ = try check_and_prepare(msg);
        return;
    }

    fn _reset(msg: *Message) void {
        msg.thdrs.reset();
        msg.body.reset();
        return;
    }

    inline fn deinit(msg: *Message) void {
        msg.bhdr = .{};
        msg.thdrs.deinit();
        msg.body.deinit();
        return;
    }

    pub fn destroy(msg: *Message) void {
        // The same allocator is used for creation of Message and it's fields
        const allocator = msg.thdrs.buffer.allocator;
        msg.deinit();
        allocator.destroy(msg);
    }

    pub fn actual_body_len(msg: *Message) usize {
        return actuaLen(&msg.body);
    }

    pub fn actual_headers_len(msg: *Message) usize {
        return actuaLen(&msg.thdrs.buffer);
    }

    pub fn check_and_prepare(msg: *Message) !ValidCombination { // For applicatopm messages

        msg.bhdr.status = status_to_raw(.success);

        const bhdr: BinaryHeader = msg.bhdr; // For debugging
        const mtype = bhdr.proto.mtype;
        const mode = bhdr.proto.mode;
        const origin = bhdr.proto.origin;
        const more = bhdr.proto.more;

        if ((mode == .response) and (bhdr.message_id == 0)) {
            msg.bhdr.status = status_to_raw(.invalid_message_id);
            return AMPError.InvalidMessageId;
        }

        if (origin != .application) {
            msg.bhdr.status = status_to_raw(.not_allowed);
            return AMPError.NotAllowed;
        }

        if ((mtype != .application) and (more == .more)) {
            msg.bhdr.status = status_to_raw(.invalid_more_usage);
            return AMPError.InvalidMoreUsage;
        }

        const vc: ValidCombination = switch (mtype) {
            .application => switch (mode) {
                .request => .AppRequest,
                .response => .AppResponse,
                .signal => .AppSignal,
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AMPError.InvalidMessageMode;
                },
            },
            .welcome => switch (mode) {
                .request => .WelcomeRequest,
                .response => {
                    msg.bhdr.status = status_to_raw(.not_allowed);
                    return AMPError.NotAllowed;
                },
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AMPError.InvalidMessageMode;
                },
            },
            .hello => switch (mode) {
                .request => .HelloRequest,
                .response => .HelloResponse,
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AMPError.InvalidMessageMode;
                },
            },
            .bye => switch (mode) {
                .request => .ByeRequest,
                .response => .ByeResponse,
                .signal => .ByeSignal,
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AMPError.InvalidMessageMode;
                },
            },
            .control => switch (mode) {
                .request => .ControlRequest,
                .signal => .ControlSignal,
                .response => {
                    msg.bhdr.status = status_to_raw(.not_allowed);
                    return AMPError.NotAllowed;
                },
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AMPError.InvalidMessageMode;
                },
            },
            else => {
                msg.bhdr.status = status_to_raw(.invalid_message_type);
                return AMPError.InvalidMessageType;
            },
        };
        const channel_number = msg.bhdr.channel_number;
        if (channel_number == 0) {
            switch (vc) {
                .WelcomeRequest, .HelloRequest => {},
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_channel_number);
                    return AMPError.InvalidChannelNumber;
                },
            }
        }

        const actualHeadersLen = msg.actual_headers_len();
        if (actualHeadersLen > std.math.maxInt(u16)) {
            msg.bhdr.status = status_to_raw(.invalid_headers_len);
            return AMPError.InvalidHeadersLen;
        }
        msg.bhdr.text_headers_len = @intCast(actualHeadersLen);

        if ((msg.bhdr.text_headers_len == 0) and ((vc == .WelcomeRequest) or (vc == .HelloRequest))) {
            msg.bhdr.status = status_to_raw(.invalid_address);
            return AMPError.InvalidAddress;
        }

        const actualBodyLen = msg.actual_body_len();
        if (actualBodyLen > std.math.maxInt(u16)) {
            msg.bhdr.status = status_to_raw(.invalid_headers_len);
            return AMPError.InvalidHeadersLen;
        }
        msg.bhdr.body_len = @intCast(actualBodyLen);

        return vc;
    }

    pub fn next_mid() MessageID {
        return uid.fetchAdd(1, .monotonic);
    }
};

var uid: Atomic(MessageID) = .init(1);

pub inline fn actuaLen(apnd: *Appendable) usize {
    if (apnd.body()) |b| {
        return b.len;
    }
    return 0;
}

pub const MessageQueue = struct {
    const Self = @This();

    first: ?*Message = null,
    last: ?*Message = null,

    pub fn enqueue(fifo: *Self, msg: *Message) void {
        msg.prev = null;
        msg.next = null;

        if (fifo.last) |last| {
            last.next = msg;
            msg.prev = last;
        } else {
            fifo.first = msg;
        }

        fifo.last = msg;

        return;
    }

    pub fn dequeue(fifo: *Self) ?*Message {
        if (fifo.first == null) {
            return null;
        }

        var result = fifo.first;
        fifo.first = result.?.next;

        if (fifo.first == null) {
            fifo.last = null;
        } else {
            fifo.first.?.prev = fifo.first;
        }

        result.?.prev = null;
        result.?.next = null;

        return result;
    }

    pub fn destroy(fifo: *Self) void {
        var next = fifo.dequeue();
        while (next != null) {
            next.?.destroy();
            next = fifo.dequeue();
        }
    }
};

pub const TextHeaderIterator = @import("TextHeaderIterator.zig");
pub const Appendable = @import("nats").Appendable;

pub const status = @import("status.zig");
pub const AMPStatus = status.AMPStatus;
pub const AMPError = status.AMPError;
pub const raw_to_status = status.raw_to_status;
pub const raw_to_error = status.raw_to_error;
pub const status_to_raw = status.status_to_raw;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const is_be = builtin.target.cpu.arch.endian() == .big;

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicRmwOp = std.builtin.AtomicRmwOp;
