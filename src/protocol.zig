// Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const MessageType = enum(u3) {
    application = 0,
    welcome = 1,
    hello = 2,
    bye = 3,
    control = 4,
    _reserved5,
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
    type: MessageType = .application,
    mode: MessageMode = .invalid,
    origin: OriginFlag = .application,
    more: MoreMessagesFlag = .last,
    pcb: ProtocolControlBitFlag = .zero,
};

pub const BinaryHeader = packed struct {
    channel_number: u16 = 0,
    proto: ProtoFields = .{},
    status: u8 = 0,
    message_id: u64 = 0,
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
            try hdrs.appendTextHeader(next.?);
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

    pub fn hiter(hdrs: *TextHeaders) !TextHeaderIterator {
        const raw = hdrs.buffer.body();
        if (raw == null) {
            return error.WithoutHeaders;
        }
        return TextHeaderIterator.init(raw.?);
    }
};

pub const Message = struct {
    prev: ?*Message = null,
    next: ?*Message = null,

    bhdr: BinaryHeader = undefined,
    thdrs: TextHeaders = undefined,
    body: Appendable = undefined,

    pub fn reset(msg: *Message) void {
        msg.bhdr = .{};
        msg.thdrs.reset();
        msg.body.reset();
        return;
    }

    pub fn set(msg: *Message, bhdr: *BinaryHeader, thdrs: ?*TextHeaders, body: ?[]const u8) !void {
        _ = bhdr;
        _ = thdrs;
        _ = body;
        return msg.validate();
    }

    pub fn setNotSafe(msg: *Message, bhdr: *BinaryHeader, thdrs: ?[]const u8, body: ?[]const u8) !void {
        _ = bhdr;
        _ = thdrs;
        _ = body;
        return msg.validate();
    }

    pub fn validate(msg: *Message) !void {
        _ = msg;
        return;
    }
};

pub const AMP = struct {
    impl: *anyopaque = undefined,
    functions: *const Functions = undefined,

    pub const Functions = struct {
        /// Initiates asynchronous send of Message to peer
        /// Returns errors (TBD) or filled BinaryHeader of the Message.
        start_send: *const fn (impl: *anyopaque, msg: *Message) anyerror!BinaryHeader,

        /// Waits *Message on internal queue.
        /// If during timeout_ns message was not received, return null.
        wait_receive: *const fn (impl: *anyopaque, timeout_ns: u64) anyerror!?*Message,

        /// Gets *Message from internal pool.
        /// If message is not available, allocates new and returns result (force == true) or null otherwice.
        /// If pool was closed, returns null
        get: *const fn (impl: *anyopaque, force: bool) ?*Message,

        /// Returns *Message to internal pool.
        put: *const fn (impl: *anyopaque, msg: *Message) void,

        /// Free *Message
        free: *const fn (impl: *anyopaque, msg: *Message) void,

        deinit: *const fn (impl: *anyopaque) anyerror!void,
    };

    // Initiates asynchronous send of Message to peer
    // Returns errors (TBD) or filled BinaryHeader of the Message.
    pub fn start_send(amp: *AMP, msg: *Message) !BinaryHeader {
        return try amp.functions.start_send(amp.impl, msg);
    }

    // Waits *Message on internal queue.
    // If during timeout_ns message was not received, return null.
    pub fn wait_receive(amp: *AMP, timeout_ns: u64) !?*Message {
        return try amp.functions.wait_receive(amp.impl, timeout_ns);
    }

    // Gets *Message from internal pool.
    // If message is not available, allocates new and returns result (force == true) or null otherwice.
    // If pool was closed, returns null
    pub fn get(amp: *AMP, force: bool) ?*Message {
        return try amp.functions.get(amp.impl, force);
    }

    // Returns *Message to internal pool.
    pub fn put(amp: *AMP, msg: *Message) void {
        return amp.functions.put(amp.impl, msg);
    }

    // Free *Message
    pub fn free(amp: *AMP, msg: *Message) void {
        return amp.functions.free(amp.impl, msg);
    }

    // Release resources
    pub fn deinit(amp: *AMP) !void {
        return amp.functions.deinit(amp.impl);
    }
};

pub const Options = struct {
    // Placeholder
};

pub fn init(allocator: Allocator, options: Options) !AMP {
    var gt: Gate = .{};

    try gt.init(allocator, options);

    return gt.amp();
}

const is_be = builtin.target.cpu.arch.endian() == .big;

pub const TextHeaderIterator = @import("TextHeaderIterator.zig");
pub const Appendable = @import("nats").Appendable;
const Gate = @import("protocol/Gate.zig");
const Pool = @import("protocol/Pool.zig");

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
