// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

pub const Trigger = enum(u1) {
    on = 1,
    off = 0,
};

pub const MessageType = enum(u2) {
    regular = 0,
    welcome = 1,
    hello = 2,
    bye = 3,
};

pub const MessageRole = enum(u2) {
    request = 0,
    response = 1,
    signal = 2,
};

pub const OpCode = enum(u4) {
    Request = 0,
    Response = 1,
    Signal = 2,
    HelloRequest = 3,
    HelloResponse = 4,
    ByeRequest = 5,
    ByeResponse = 6,
    ByeSignal = 7,
    WelcomeRequest = 8,
    WelcomeResponse = 9,

    pub inline fn isValid(oc: OpCode) bool {
        return std.enums.fromInt(OpCode, @intFromEnum(oc)) != null;
    }

    pub fn isRequest(oc: OpCode) bool {
        return switch (oc) {
            .Request, .HelloRequest, .ByeRequest, .WelcomeRequest => true,
            else => false,
        };
    }

    pub fn isResponse(oc: OpCode) bool {
        return switch (oc) {
            .Response, .HelloResponse, .ByeResponse, .WelcomeResponse => true,
            else => false,
        };
    }

    pub fn isSignal(oc: OpCode) bool {
        return switch (oc) {
            .Signal, .ByeSignal => true,
            else => false,
        };
    }

    pub fn getType(oc: OpCode) MessageType { // No validation
        return switch (oc) {
            .Request,
            .Response,
            .Signal,
            => .regular,
            .ByeRequest,
            .ByeResponse,
            .ByeSignal,
            => .bye,
            .HelloRequest,
            .HelloResponse,
            => .hello,
            .WelcomeRequest,
            .WelcomeResponse,
            => .welcome,
        };
    }

    pub fn getRole(oc: OpCode) MessageRole { // No validation
        return switch (oc) {
            .Request, .HelloRequest, .ByeRequest, .WelcomeRequest => .request,
            .Response, .HelloResponse, .ByeResponse, .WelcomeResponse => .response,
            .Signal, .ByeSignal => .signal,
        };
    }

    pub fn echo(oc: OpCode) error{
        InvalidOpCode,
    }!OpCode {
        if (!oc.isValid()) {
            return AmpeError.InvalidOpCode;
        }

        if (!oc.isRequest()) {
            return AmpeError.InvalidOpCode;
        }

        return switch (oc) {
            .Request => .Response,
            .HelloRequest => .HelloResponse,
            .ByeRequest => .ByeResponse,
            .WelcomeRequest => .WelcomeResponse,
            else => unreachable,
        };
    }
};

pub const OriginFlag = enum(u1) {
    application = 0,
    engine = 1,
};

pub const MoreMessagesFlag = enum(u1) {
    last = 0,
    more = 1,
};

/// High priority. Goes to head of queue.
pub const Oob = Trigger;

pub const ProtoFields = packed struct(u8) {
    opCode: OpCode = .Request,
    origin: OriginFlag = .application,
    more: MoreMessagesFlag = .last,
    oob: Oob = .off,
    _internal: u1 = 0,

    pub fn default(oc: OpCode) ProtoFields {
        var pf: ProtoFields = .{
            .opCode = oc,
        };

        switch (oc) {
            .ByeSignal => pf.oob = .on,
            .WelcomeResponse => pf.origin = .engine,
            else => {},
        }

        return pf;
    }

    pub fn isValid(pf: ProtoFields) bool {
        return pf.opCode.isValid();
    }

    pub inline fn getType(pf: ProtoFields) MessageType {
        return pf.opCode.getType();
    }

    pub inline fn getRole(pf: ProtoFields) MessageRole {
        return pf.opCode.getRole();
    }

    pub fn fromByte(byte: u8) .InvalidOpCode!ProtoFields {
        const pf: ProtoFields = @bitCast(byte);

        if (std.enums.fromInt(OpCode, @intFromEnum(pf.opCode)) == null) {
            return .InvalidOpCode;
        }

        return pf;
    }

    pub fn asByte(pf: ProtoFields) u8 {
        return @bitCast(pf);
    }
};

pub const ChannelNumber = u16;

pub const SpecialMinChannelNumber = std.math.minInt(u16);

pub const SpecialMaxChannelNumber = std.math.maxInt(u16);

pub const MessageID = u64;

pub const BinaryHeader = packed struct {
    channel_number: ChannelNumber = 0,
    proto: ProtoFields = .{},
    status: u8 = 0,
    message_id: MessageID = 0,

    /// Engine internal. Don't touch.
    @"<thl>": u16 = 0,

    /// Engine internal. Don't touch.
    @"<bl>": u16 = 0,

    pub const BHSIZE = @sizeOf(BinaryHeader);

    pub fn init(oc: OpCode) BinaryHeader {
        return .{
            .proto = .default(oc),
        };
    }

    pub fn clean(bh: *BinaryHeader) void {
        bh.* = .{};
    }

    // Contributed by Grok
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
                .@"<thl>" = std.mem.nativeToBig(u16, self.@"<thl>"),
                .@"<bl>" = std.mem.nativeToBig(u16, self.@"<bl>"),
            };
            const src_le: *[BHSIZE]u8 = @ptrCast(&be_header);
            @memcpy(buf, src_le);
        }
        return;
    }

    // Contributed by Grok
    pub fn fromBytes(self: *BinaryHeader, bytes: *const [BHSIZE]u8) void {
        const dest: *[BHSIZE]u8 = @ptrCast(self);
        @memcpy(dest, bytes);

        // Convert from big-endian to native if little-endian
        if (!is_be) {
            self.channel_number = std.mem.bigToNative(u16, self.channel_number);
            self.message_id = std.mem.bigToNative(u64, self.message_id);
            self.@"<thl>" = std.mem.bigToNative(u16, self.@"<thl>");
            self.@"<bl>" = std.mem.bigToNative(u16, self.@"<bl>");
        }

        return;
    }

    pub inline fn dump(self: *BinaryHeader, txt: []const u8) void {
        if (!DBG) {
            return;
        }

        const tn = std.enums.tagName(OpCode, self.*.proto.opCode).?;

        log.debug("{s} {s} chn {d} mid {d} thl {d} bl  {d}", .{ txt, tn, self.channel_number, self.message_id, self.@"<thl>", self.@"<bl>" });

        return;
    }

    pub inline fn dumpMeta(self: *BinaryHeader, txt: []const u8) void {
        if (!DBG) {
            return;
        }

        const proto: message.ProtoFields = self.*.proto;

        const oc = std.enums.tagName(OpCode, proto.opCode).?;
        const org = std.enums.tagName(OriginFlag, proto.origin).?;
        const mr = std.enums.tagName(MoreMessagesFlag, proto.more).?;
        const ob = std.enums.tagName(Oob, proto.oob).?;

        log.debug("    [mid {d}] ({d}) {s} {s} {s} {s} {s} {s}", .{ self.*.message_id, self.*.channel_number, txt, oc, org, mr, ob, @tagName(status.raw_to_status(self.*.status)) });

        return;
    }
};

pub const TextHeader = struct {
    name: []const u8 = undefined,
    value: []const u8 = undefined,
};

pub const TextHeaderIterator = struct {
    bytes: ?[]const u8 = null,
    index: usize = 0,

    pub fn init(bytes: ?[]const u8) TextHeaderIterator {
        return .{
            .bytes = bytes,
            .index = 0,
        };
    }

    pub fn rewind(it: *TextHeaderIterator) void {
        it.index = 0;
    }

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

/// key-value pairs similar to HTTP headers
/// Format: "name: value\r\n"
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

pub const Message = struct {
    prev: ?*Message = null,
    next: ?*Message = null,

    /// Actual data
    bhdr: BinaryHeader = .{},
    thdrs: TextHeaders = .{},
    body: Appendable = .{},

    /// App usage. Be careful.
    @"<void*>": ?*anyopaque = null,

    /// Engine internal. Don't touch.
    @"<ctx>": ?*anyopaque = null,

    const blen: u16 = 256;
    const tlen: u16 = 64;

    pub fn create(allocator: Allocator) AmpeError!*Message {
        var msg: *Message = allocator.create(Message) catch {
            return AmpeError.AllocationFailed;
        };

        msg.* = .{};

        errdefer msg.*.destroy();

        msg.body.init(allocator, blen, null) catch {
            return AmpeError.AllocationFailed;
        };

        msg.thdrs.init(allocator, tlen) catch {
            return AmpeError.AllocationFailed;
        };

        return msg;
    }

    pub fn clone(self: *Message) !*Message {
        const alc = self.body.allocator;
        const msg: *Message = try alc.create(Message);
        errdefer msg.*.destroy(); //???

        msg.* = .{};
        msg.*.bhdr = self.bhdr;
        msg.*.@"<ctx>" = null;

        try msg.*.body.init(alc, @max(self.body.buffer.?.len, blen), null);
        if (self.body.body()) |src| {
            try msg.*.body.copy(src);
        }

        try msg.*.thdrs.init(alc, @intCast(@max(self.thdrs.buffer.buffer.?.len, tlen)));
        if (self.thdrs.buffer.body()) |src| {
            try msg.*.thdrs.buffer.copy(src);
        }

        return msg;
    }

    /// Resets the message to its initial state,
    /// clearing headers , body and transient fields.
    /// Pay attention - message is not valid for enqueueToPeer
    pub fn reset(msg: *Message) void {
        msg.bhdr = .{};
        msg.thdrs.reset();
        msg.body.reset();
        msg.@"<void*>" = null;
        msg.@"<ctx>" = null;
        return;
    }

    /// Sets the message's binary header, text headers, and body, with validation.
    pub fn set(msg: *Message, bhdr: *BinaryHeader, thdrs: ?*TextHeaders, body: ?[]const u8) !void {
        msg.*.bhdr = bhdr.*;
        msg.*._reset();

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

    // 2DO - replace, use @"<ctx>" instead...
    pub fn ptrToBody(msg: *Message, comptime T: type, ptr: *T) []u8 {
        msg.body.change(@sizeOf(usize)) catch unreachable;

        var destination: []u8 = msg.body.buffer.?[0..@sizeOf(usize)];

        const addr = @intFromPtr(ptr); // Corrected function
        const addr_bytes = std.mem.asBytes(&addr);

        // Copy the raw address bytes into the destination slice.
        std.mem.copyForwards(u8, destination[0..@sizeOf(usize)], addr_bytes);

        // Return a slice of the filled portion.
        return destination[0..@sizeOf(usize)];
    }

    pub fn bodyToPtr(msg: *Message, comptime T: type) ?*T {
        const slice = msg.body.buffer.?[0..msg.body.actual_len];

        if (slice.len < @sizeOf(usize)) {
            return null;
        }

        var addr: usize = undefined;
        std.mem.copyForwards(u8, std.mem.asBytes(&addr), slice[0..@sizeOf(usize)]);

        return @ptrFromInt(addr);
    }

    inline fn validate(msg: *Message) !void {
        _ = try msg.*.check_and_prepare();
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

    pub fn actual_body_len(msg: *Message) usize {
        return actuaLen(&msg.body);
    }

    pub fn actual_headers_len(msg: *Message) usize {
        return actuaLen(&msg.thdrs.buffer);
    }

    pub fn check_and_prepare(msg: *Message) AmpeError!void {
        errdefer msg.*.bhdr.dumpMeta("illegal message");

        if (!msg.*.bhdr.proto.opCode.isValid()) {
            return AmpeError.InvalidOpCode;
        }

        // Fix possible wrong fields
        msg.bhdr.proto.origin = .application;
        msg.bhdr.status = status_to_raw(.success);
        msg.bhdr.@"<bl>" = 0;
        msg.bhdr.@"<thl>" = 0;

        const bhdr: BinaryHeader = msg.bhdr;
        const oc: OpCode = bhdr.proto.opCode;
        const mtype = oc.getType();
        const role = oc.getRole();
        const more = bhdr.proto.more;

        if ((role == .response) and (bhdr.message_id == 0)) {
            msg.bhdr.status = status_to_raw(.invalid_message_id);
            return AmpeError.InvalidMessageId;
        }

        if ((mtype != .regular) and (more == .more)) {
            msg.bhdr.status = status_to_raw(.invalid_more_usage);
            return AmpeError.InvalidMoreUsage;
        }

        const channel_number = msg.bhdr.channel_number;
        if (channel_number == 0) {
            switch (oc) {
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
        msg.bhdr.@"<thl>" = @intCast(actualHeadersLen);

        if ((msg.bhdr.@"<thl>" == 0) and ((oc == .WelcomeRequest) or (oc == .HelloRequest))) {
            msg.bhdr.status = status_to_raw(.wrong_address);
            return AmpeError.WrongAddress;
        }

        const actualBodyLen = msg.actual_body_len();
        if (actualBodyLen > std.math.maxInt(u16)) {
            msg.bhdr.status = status_to_raw(.invalid_body_len);
            return AmpeError.InvalidBodyLen;
        }
        msg.bhdr.@"<bl>" = @intCast(actualBodyLen);

        if (msg.bhdr.message_id == 0) {
            msg.bhdr.message_id = next_mid();
        }

        return;
    }

    /// Debug: channel_number == 0 means simultaneous usage.
    pub inline fn assert(msg: *Message) void {
        if ((msg.*.bhdr.proto.origin == .application) and (msg.bhdr.channel_number == message.SpecialMinChannelNumber)) {
            var bh: ?BinaryHeader = msg.bhVal();
            if (bh != null) {
                bh.?.dumpMeta(" !!!!! former header ?????");
            }
            std.debug.assert(msg.bhdr.channel_number != message.SpecialMinChannelNumber);
        }
        return;
    }

    pub fn copyBh2Body(msg: *Message) void {
        _ = message.structToSlice(message.BinaryHeader, &msg.*.bhdr, msg.*.body.buffer.?);
        msg.*.body.change(@sizeOf(message.BinaryHeader)) catch unreachable;
        return;
    }

    // For debugging - return binary header from body
    // Returns null if body does not contains binary header (compare lengths)
    pub fn bhVal(msg: *Message) ?message.BinaryHeader {
        if (msg.*.actual_body_len() != @sizeOf(message.BinaryHeader)) {
            return null;
        }

        var ret: message.BinaryHeader = .{};

        if (!structFromSlice(message.BinaryHeader, msg.*.body.body().?, &ret)) {
            return null;
        }

        return ret;
    }

    pub fn getOpCode(msg: *Message) error{InvalidOpCode}!OpCode {
        const oc: OpCode = msg.*.bhdr.proto.opCode;
        if (!oc.isValid()) {
            return AmpeError.InvalidOpCode;
        }
        return oc;
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

pub fn clearQueue(queue: *MessageQueue) void {
    var next = queue.dequeue();
    while (next != null) {
        next.?.destroy();
        next = queue.dequeue();
    }
}

pub const MessageQueue = @import("ampe/IntrusiveQueue.zig").IntrusiveQueue(Message);

const is_be = builtin.target.cpu.arch.endian() == .big;

// ====================================
//       Gemini generated helpers
// ====================================

/// Returns empty slice if destination too small.
pub fn ptrToSlice(comptime T: type, ptr: *T, destination: []u8) []u8 {
    // Check if the destination slice is large enough.
    if (destination.len < @sizeOf(usize)) {
        return &[_]u8{}; // Return an empty slice to indicate failure.
    }

    const addr = @intFromPtr(ptr); // Corrected function
    const addr_bytes = std.mem.asBytes(&addr);

    // Copy the raw address bytes into the destination slice.
    std.mem.copyForwards(u8, destination[0..@sizeOf(usize)], addr_bytes);

    // Return a slice of the filled portion.
    return destination[0..@sizeOf(usize)];
}

/// Returns null if slice too small.
pub fn sliceToPtr(comptime T: type, slice: []const u8) ?*T {
    if (slice.len < @sizeOf(usize)) {
        return null;
    }

    var addr: usize = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&addr), slice[0..@sizeOf(usize)]);

    return @ptrFromInt(addr); // Corrected function
}

/// Returns empty slice if destination too small.
pub fn structToSlice(comptime T: type, ptr: *const T, destination: []u8) []u8 {
    const struct_size = @sizeOf(T);
    if (destination.len < struct_size) {
        return &[_]u8{}; // Return an empty slice if destination is too small ???
    }
    std.mem.copyForwards(u8, destination[0..struct_size], std.mem.asBytes(ptr));
    return destination[0..struct_size];
}

/// Returns false if slice length doesn't match struct size.
pub fn structFromSlice(comptime T: type, slice: []const u8, destination: *T) bool {
    const struct_size = @sizeOf(T);
    if (slice.len != struct_size) {
        return false;
    }
    std.mem.copyForwards(u8, std.mem.asBytes(destination), slice);
    return true;
}

const SliceTooSmallError = error{SliceTooSmall};

/// Native endianness. Returns empty slice if destination too small.
pub fn valueToSlice(comptime T: type, value: T, dest: []u8) []u8 {
    // 1. Comptime error check for aggregate types
    comptime {
        const info = @typeInfo(T);
        // FIX: Added `.Pointer` to the list of blocked aggregate types.
        if (info == .Struct or info == .Array or info == .Union) {
            @compileError("Type '" ++ @typeName(T) ++ "' is an aggregate (struct/array/union) and not supported for scalar conversion.");
        }
    }

    const value_size = @sizeOf(T);

    // 2. Destination size check
    if (dest.len < value_size) {
        return dest[0..0]; // Return empty slice
    }

    // 3. Conversion and copying
    // std.mem.span safely provides a []const u8 view of the scalar value.
    const value_bytes = std.mem.span(&value);
    std.mem.copy(u8, dest[0..value_size], value_bytes);

    // 4. Return filled slice
    return dest[0..value_size];
}

/// Native endianness. Returns error if slice too small.
pub fn sliceToValue(comptime T: type, slice: []const u8) SliceTooSmallError!T {
    // 1. Comptime error check for aggregate types (including .Pointer)
    comptime {
        const info = @typeInfo(T);
        // FIX: Added `.Pointer` to the list of blocked aggregate types.
        if (info == .Struct or info == .Array or info == .Union or info == .Pointer) {
            @compileError("Target type '" ++ @typeName(T) ++ "' is an aggregate (struct/array/pointer/union) and not supported for scalar conversion.");
        }
    }

    const value_size = @sizeOf(T);

    // 2. Slice size check
    if (slice.len < value_size) {
        return SliceTooSmallError;
    }

    // 3. Decoding by copying bytes into an aligned variable
    var result: T = undefined;
    const result_bytes: []u8 = std.mem.span(&result);

    // Copy only the required size from the input slice
    std.mem.copy(u8, result_bytes, slice[0..value_size]);

    return result;
}

const DBG = @import("ampe.zig").DBG;
pub const status = @import("status.zig");
pub const AmpeStatus = status.AmpeStatus;
pub const AmpeError = status.AmpeError;
pub const status_to_raw = status.status_to_raw;
pub const Appendable = @import("Appendable");
const message = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicRmwOp = std.builtin.AtomicRmwOp;
const log = std.log;
const builtin = @import("builtin");
