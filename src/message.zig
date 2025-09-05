// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

/// Enum representing the type of a message, used to categorize messages for processing.
pub const MessageType = enum(u3) {
    application = 0,
    welcome = 1,
    hello = 2,
    bye = 3,
    status = 4,
    _reserved5,
    _reserved6,
    _reserved7,
};

/// Enum representing the mode of a message, indicating whether it is a request, response, or signal.
pub const MessageMode = enum(u2) {
    invalid = 0,
    request = 1,
    response = 2,
    signal = 3,
};

/// Enum indicating the origin of a message, either from the application or the engine.
pub const OriginFlag = enum(u1) {
    application = 0,
    engine = 1,
};

/// Enum indicating whether more messages are expected in a sequence.
pub const MoreMessagesFlag = enum(u1) {
    last = 0,
    more = 1,
};

/// If '.on' , indicates high priority message.
/// Oob message will be placed in the head of the queue of messages for send.
pub const Oob = Trigger;

/// Packed struct containing protocol fields for message metadata.
pub const ProtoFields = packed struct(u8) {
    mtype: MessageType = .application,
    mode: MessageMode = .invalid,
    origin: OriginFlag = .application,
    more: MoreMessagesFlag = .last,
    oob: Oob = .off,
};

/// Type alias for channel number, represented as a 16-bit unsigned integer.
pub const ChannelNumber = u16;

/// Type alias for message ID, represented as a 64-bit unsigned integer.
pub const MessageID = u64;

/// Packed struct representing the binary header of a message, containing metadata.
pub const BinaryHeader = packed struct {
    channel_number: ChannelNumber = 0,
    proto: ProtoFields = .{},
    status: u8 = 0,
    message_id: MessageID = 0,
    text_headers_len: u16 = 0,
    body_len: u16 = 0,

    /// Constant representing the size of the BinaryHeader in bytes (16 bytes).
    pub const BHSIZE = @sizeOf(BinaryHeader);

    /// Resets the binary header to its default state.
    pub fn clean(bh: *BinaryHeader) void {
        bh.* = .{};
    }

    /// Serializes the binary header to a byte array, handling endianness conversion if needed.
    pub fn toBytes(self: *BinaryHeader, buf: *[BHSIZE]u8) void {
        self.dump("send");

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
        return;
    }

    /// Deserializes a byte array into the binary header, handling endianness conversion if needed.
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

        self.dump("recv");

        return;
    }

    /// Logs debug information about the binary header if debugging is enabled.
    pub inline fn dump(self: *BinaryHeader, txt: []const u8) void {
        if (!DBG) {
            return;
        }

        const tn = std.enums.tagName(MessageType, self.*.proto.mtype).?;

        log.debug("{s} {s} chn {d} mid {d} thl {d} bl  {d}", .{ txt, tn, self.channel_number, self.message_id, self.text_headers_len, self.body_len });

        return;
    }
};

/// Structure representing a single text header as a name-value pair.
pub const TextHeader = struct {
    name: []const u8 = undefined,
    value: []const u8 = undefined,
};

/// Iterator for parsing text headers from a byte slice.
pub const TextHeaderIterator = struct {
    bytes: ?[]const u8 = null,
    index: usize = 0,

    /// Initializes a new TextHeaderIterator with the provided byte slice.
    pub fn init(bytes: ?[]const u8) TextHeaderIterator {
        return .{
            .bytes = bytes,
            .index = 0,
        };
    }

    /// Resets the iterator to the beginning of the byte slice.
    pub fn rewind(it: *TextHeaderIterator) void {
        it.index = 0;
    }

    /// Returns the next text header from the byte slice, or null if no more headers exist.
    pub fn next(it: *TextHeaderIterator) ?TextHeader {
        if (it.bytes == null) {
            return null;
        }

        if (it.bytes.?.len == 0) {
            return null;
        }

        const buffer = it.bytes.?;

        while (true) {
            if (it.index >= it.bytes.?.len) {
                return null;
            }

            const crlfaddr = std.mem.indexOfPosLinear(u8, buffer, it.index, "\r\n");

            if (crlfaddr == null) { // Without CRLF at the end
                var kv_it = std.mem.splitScalar(u8, buffer[it.index..], ':');
                const name = kv_it.first();
                const value = kv_it.rest();

                it.index = it.bytes.?.len;
                if (name.len == 0) {
                    return null;
                }

                return .{
                    .name = name,
                    .value = std.mem.trim(u8, value, " \t"),
                };
            }

            const end = crlfaddr.?;

            if (it.index == end) { // found empty field ????
                it.index = end + 2;
                continue;
            }

            // normal header
            var kv_it = std.mem.splitScalar(u8, buffer[it.index..end], ':');
            const name = kv_it.first();
            const value = kv_it.rest();

            it.index = end + 2;
            if (name.len == 0) {
                return null;
            }
            return .{
                .name = name,
                .value = std.mem.trim(u8, value, " \t"),
            };
        }
    }
};

/// Structure for managing a collection of text headers, stored in an Appendable buffer.
/// Headers are stored as "name: value\r\n" without a trailing CRLF.
pub const TextHeaders = struct {
    buffer: Appendable = .{},

    /// Initializes the TextHeaders structure with an allocator and initial buffer length.
    pub fn init(hdrs: *TextHeaders, allocator: Allocator, len: u16) !void {
        try hdrs.buffer.init(allocator, len, null);
        return;
    }

    /// Deallocates the TextHeaders buffer.
    pub fn deinit(hdrs: *TextHeaders) void {
        hdrs.buffer.deinit();
    }

    /// Safely appends text headers from an iterator, ensuring proper formatting.
    pub fn appendSafe(hdrs: *TextHeaders, it: *TextHeaderIterator) !void {
        var next = it.next();

        while (next != null) : (next = it.next()) {
            try hdrs.appendTextHeader(next);
        }

        return;
    }

    /// Appends raw text headers without validation, assuming correct formatting.
    pub fn appendNotSafe(hdrs: *TextHeaders, textheaders: []const u8) !void {
        try hdrs.buffer.append(textheaders);
        return;
    }

    /// Appends a single text header from a TextHeader structure.
    pub fn appendTextHeader(hdrs: *TextHeaders, th: *TextHeader) !void {
        return hdrs.append(th.name, th.value);
    }

    /// Appends a name-value pair as a text header, ensuring proper formatting.
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

    /// Resets the TextHeaders buffer to an empty state.
    pub fn reset(hdrs: *TextHeaders) void {
        hdrs.buffer.reset();
        return;
    }

    /// Returns an iterator for the text headers in the buffer.
    pub fn hiter(hdrs: *TextHeaders) TextHeaderIterator {
        const raw = hdrs.buffer.body();
        return TextHeaderIterator.init(raw);
    }
};

/// Enum representing valid message type and mode combinations allowed for sending by the application.
pub const ValidCombination = enum(u4) {
    WelcomeRequest,
    WelcomeResponse,
    HelloRequest,
    HelloResponse,
    ByeRequest,
    ByeResponse,
    ByeSignal,
    AppRequest,
    AppResponse,
    AppSignal,
    _reserved1,
    _reserved2,
    _reserved3,
    _reserved4,
    _reserved5,
};

/// Structure representing a complete message, including binary header, text headers, and body.
pub const Message = struct {
    prev: ?*Message = null,
    next: ?*Message = null,
    bhdr: BinaryHeader = .{},
    thdrs: TextHeaders = .{},
    body: Appendable = .{},

    const blen: u16 = 256;
    const tlen: u16 = 64;

    /// Creates a new Message instance with initialized body and text headers.
    pub fn create(allocator: Allocator) AmpeError!*Message {
        var msg = allocator.create(Message) catch {
            return AmpeError.AllocationFailed;
        };

        msg.* = .{};
        msg.bhdr = .{};

        errdefer msg.destroy();

        msg.body.init(allocator, blen, null) catch {
            return AmpeError.AllocationFailed;
        };

        msg.thdrs.init(allocator, tlen) catch {
            return AmpeError.AllocationFailed;
        };

        return msg;
    }

    /// Creates a deep copy of the Message, including its headers and body.
    pub fn clone(self: *Message) !*Message {
        const alc = self.body.allocator;
        var msg = try alc.create(Message);
        errdefer msg.destroy(); //???

        msg.* = .{};
        msg.bhdr = self.bhdr;

        try msg.body.init(alc, @max(self.body.buffer.?.len, blen), null);
        if (self.body.body()) |src| {
            try msg.body.copy(src);
        }

        try msg.thdrs.init(alc, @intCast(@max(self.thdrs.buffer.buffer.?.len, tlen)));
        if (self.thdrs.buffer.body()) |src| {
            try msg.thdrs.buffer.copy(src);
        }

        return msg;
    }

    /// Resets the message to its initial state, clearing headers and body.
    pub fn reset(msg: *Message) void {
        msg.bhdr = .{};
        msg.thdrs.reset();
        msg.body.reset();
        return;
    }

    /// Sets the message's binary header, text headers, and body, with validation.
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

    /// Sets the message's binary header, text headers, and body without validation.
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

    /// Validates the message, ensuring it conforms to allowed type and mode combinations.
    inline fn validate(msg: *Message) !void {
        _ = try check_and_prepare(msg);
        return;
    }

    /// Internal function to reset text headers and body without touching the binary header.
    fn _reset(msg: *Message) void {
        msg.thdrs.reset();
        msg.body.reset();
        return;
    }

    /// Deallocates the message's text headers and body.
    inline fn deinit(msg: *Message) void {
        msg.bhdr = .{};
        msg.thdrs.deinit();
        msg.body.deinit();
        return;
    }

    /// Destroys the message, deallocating all resources including the message itself.
    pub fn destroy(msg: *Message) void {
        const allocator = msg.thdrs.buffer.allocator;
        msg.deinit();
        allocator.destroy(msg);
    }

    /// If message was not successfully send, destroy it
    pub fn DestroySendMsg(msgoptptr: *?*Message) void {
        const msgopt = msgoptptr.*;
        if (msgopt) |msg| {
            msg.destroy();
            msgoptptr.* = null;
        }
    }

    /// Returns the actual length of the message body.
    pub fn actual_body_len(msg: *Message) usize {
        return actuaLen(&msg.body);
    }

    /// Returns the actual length of the text headers.
    pub fn actual_headers_len(msg: *Message) usize {
        return actuaLen(&msg.thdrs.buffer);
    }

    /// Validates the message and updates its binary header fields based on content lengths.
    pub fn check_and_prepare(msg: *Message) AmpeError!ValidCombination {
        msg.bhdr.status = status_to_raw(.success);

        const bhdr: BinaryHeader = msg.bhdr;
        const mtype = bhdr.proto.mtype;
        const mode = bhdr.proto.mode;
        const origin = bhdr.proto.origin;
        const more = bhdr.proto.more;

        if ((mode == .response) and (bhdr.message_id == 0)) {
            msg.bhdr.status = status_to_raw(.invalid_message_id);
            return AmpeError.InvalidMessageId;
        }

        if (origin != .application) {
            msg.bhdr.status = status_to_raw(.not_allowed);
            return AmpeError.NotAllowed;
        }

        if ((mtype != .application) and (more == .more)) {
            msg.bhdr.status = status_to_raw(.invalid_more_usage);
            return AmpeError.InvalidMoreUsage;
        }

        const vc: ValidCombination = switch (mtype) {
            .application => switch (mode) {
                .request => .AppRequest,
                .response => .AppResponse,
                .signal => .AppSignal,
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AmpeError.InvalidMessageMode;
                },
            },
            .welcome => switch (mode) {
                .request => .WelcomeRequest,
                .response => {
                    msg.bhdr.status = status_to_raw(.not_allowed);
                    return AmpeError.NotAllowed;
                },
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AmpeError.InvalidMessageMode;
                },
            },
            .hello => switch (mode) {
                .request => .HelloRequest,
                .response => .HelloResponse,
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AmpeError.InvalidMessageMode;
                },
            },
            .bye => switch (mode) {
                .request => .ByeRequest,
                .response => .ByeResponse,
                .signal => .ByeSignal,
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_message_mode);
                    return AmpeError.InvalidMessageMode;
                },
            },
            .status => {
                msg.bhdr.status = status_to_raw(.not_allowed);
                return AmpeError.NotAllowed;
            },
            else => {
                msg.bhdr.status = status_to_raw(.invalid_message_type);
                return AmpeError.InvalidMessageType;
            },
        };
        const channel_number = msg.bhdr.channel_number;
        if (channel_number == 0) {
            switch (vc) {
                .WelcomeRequest, .HelloRequest => {},
                else => {
                    msg.bhdr.status = status_to_raw(.invalid_channel_number);
                    return AmpeError.InvalidChannelNumber;
                },
            }
        }

        const actualHeadersLen = msg.actual_headers_len();
        if (actualHeadersLen > std.math.maxInt(u16)) {
            msg.bhdr.status = status_to_raw(.invalid_headers_len);
            return AmpeError.InvalidHeadersLen;
        }
        msg.bhdr.text_headers_len = @intCast(actualHeadersLen);

        if ((msg.bhdr.text_headers_len == 0) and ((vc == .WelcomeRequest) or (vc == .HelloRequest))) {
            msg.bhdr.status = status_to_raw(.invalid_address);
            return AmpeError.InvalidAddress;
        }

        const actualBodyLen = msg.actual_body_len();
        if (actualBodyLen > std.math.maxInt(u16)) {
            msg.bhdr.status = status_to_raw(.invalid_headers_len);
            return AmpeError.InvalidHeadersLen;
        }
        msg.bhdr.body_len = @intCast(actualBodyLen);

        return vc;
    }

    /// Generates the next unique message ID using an atomic counter.
    pub fn next_mid() MessageID {
        return uid.fetchAdd(1, .monotonic);
    }
};

/// Atomic counter for generating unique message IDs.
var uid: Atomic(MessageID) = .init(1);

/// Returns the actual length of an Appendable buffer's content.
pub inline fn actuaLen(apnd: *Appendable) usize {
    if (apnd.body()) |b| {
        return b.len;
    }
    return 0;
}

/// Structure for managing a queue of messages in a FIFO order.
pub const MessageQueue = struct {
    const Self = @This();

    first: ?*Message = null,
    last: ?*Message = null,

    /// Adds a message to the end of the queue.
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

    /// Removes and returns the message at the front of the queue, or null if empty.
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

    /// Checks if the queue is empty.
    pub fn empty(fifo: *Self) bool {
        return (fifo.first == null);
    }

    /// Clears the queue, destroying all messages.
    pub fn clear(fifo: *Self) void {
        var next = fifo.dequeue();
        while (next != null) {
            next.?.destroy();
            next = fifo.dequeue();
        }
    }

    /// Returns the number of messages in the queue.
    pub fn count(fifo: *Self) usize {
        var ret: usize = 0;
        var next = fifo.first;
        while (next != null) : (ret += 1) {
            next = next.?.next;
        }
        return ret;
    }

    /// Moves all messages from one queue to another.
    pub fn move(src: *MessageQueue, dest: *MessageQueue) void {
        var next = src.dequeue();
        while (next != null) {
            dest.enqueue(next.?);
            next = src.dequeue();
        }
    }
};

pub const Trigger = enum(u1) {
    on = 1,
    off = 0,
};

const Appendable = @import("nats").Appendable;

const status = @import("status.zig");
const AmpeStatus = status.AmpeStatus;
const AmpeError = status.AmpeError;
const status_to_raw = status.status_to_raw;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const is_be = builtin.target.cpu.arch.endian() == .big;

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicRmwOp = std.builtin.AtomicRmwOp;

const log = std.log;
const DBG = @import("engine.zig").DBG;
