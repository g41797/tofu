// SPDX-FileCopyrightText: Copyright (c) 2025 g41797
// SPDX-License-Identifier: MIT

test {
    std.testing.log_level = .debug;
    std.log.debug("message_tests\r\n", .{});
}

test "sequential message id" {
    const mid = message.Message.next_mid();
    const nextmid = message.Message.next_mid();
    try testing.expectEqual(mid + 1, nextmid);
}

test "BinaryHeader marshalling and demarshalling" {
    var header = message.BinaryHeader{
        .channel_number = 0x1234,
        .proto = .{
            .mtype = .hello,
            .role = .request,
            .origin = .application,
            .more = .last,
            .oob = .off,
        },
        .status = 0xFF,
        .message_id = 0xAABBCCDDEEFF0011,
        .@"<thl>" = 0x5678,
        .@"<bl>" = 0x9ABC,
    };

    var buf: [message.BinaryHeader.BHSIZE]u8 = undefined;
    header.toBytes(&buf);

    var demarshaled: message.BinaryHeader = undefined;
    demarshaled.fromBytes(&buf);

    try std.testing.expectEqual(header.channel_number, demarshaled.channel_number);
    try std.testing.expectEqual(header.proto.mtype, demarshaled.proto.mtype);
    try std.testing.expectEqual(header.proto.role, demarshaled.proto.role);
    try std.testing.expectEqual(header.status, demarshaled.status);
    try std.testing.expectEqual(header.message_id, demarshaled.message_id);
    try std.testing.expectEqual(header.@"<thl>", demarshaled.@"<thl>");
    try std.testing.expectEqual(header.@"<bl>", demarshaled.@"<bl>");
}

test "TextHeaderIterator no CRLF" {
    var it = TextHeaderIterator.init("a: b");
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("a", header.name);
        try std.testing.expectEqualStrings("b", header.value);
    }
    try std.testing.expectEqual(null, it.next());
}

test "TextHeaderIterator next" {
    var it = TextHeaderIterator.init("a: b\r\nc:  \r\nd:e\r\n\r\nf: g\r\n\r\n");
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("a", header.name);
        try std.testing.expectEqualStrings("b", header.value);
    }
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("c", header.name);
        try std.testing.expectEqualStrings("", header.value);
    }
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("d", header.name);
        try std.testing.expectEqualStrings("e", header.value);
    }
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("f", header.name);
        try std.testing.expectEqualStrings("g", header.value);
    }
    try std.testing.expectEqual(null, it.next());

    it = TextHeaderIterator.init(": ss\r\n\r\n");
    try std.testing.expectEqual(null, it.next());

    it = TextHeaderIterator.init("a:b\r\n\r\n: ss\r\n\r\n");
    {
        const header = it.next().?;
        try std.testing.expectEqualStrings("a", header.name);
        try std.testing.expectEqualStrings("b", header.value);
    }
    try std.testing.expectEqual(null, it.next());
}

test "TextHeaderIterator empty" {
    var it: TextHeaderIterator = .{};
    try std.testing.expectEqual(null, it.next());
}

test "struct pointer to message and back" {
    var msg = try message.Message.create(std.testing.allocator);
    defer msg.destroy();

    const MyStruct = struct {
        x: u32,
        y: u32,
    };

    var my_struct_instance = MyStruct{ .x = 100, .y = 200 };
    const original_ptr = &my_struct_instance;

    _ = msg.ptrToBody(MyStruct, &my_struct_instance);

    const retrieved_ptr = msg.bodyToPtr(MyStruct);

    try testing.expectEqual(original_ptr, retrieved_ptr.?);
}

test "struct pointer to slice and back with destination" {
    const MyStruct = struct {
        x: u32,
        y: u32,
    };

    var my_struct_instance = MyStruct{ .x = 100, .y = 200 };
    const original_ptr = &my_struct_instance;

    // Create a stack-allocated buffer to receive the pointer's address.
    var buffer: [(@sizeOf(usize))]u8 = undefined;

    // Call ptrToSlice with the destination buffer.
    const ptr_slice = message.ptrToSlice(MyStruct, original_ptr, &buffer);

    try std.testing.expectEqual(ptr_slice.len, @sizeOf(usize));

    // Convert the returned slice back to a pointer.
    const restored_ptr = message.sliceToPtr(MyStruct, ptr_slice);

    // Verify the restored pointer is not null and matches the original.
    try std.testing.expect(restored_ptr != null);
    try std.testing.expect(restored_ptr.? == original_ptr);
    try std.testing.expectEqual(restored_ptr.?.x, 100);
}

test "ptrToSlice with too small destination" {
    const MyStruct = struct {
        x: u32,
    };
    var my_struct_instance = MyStruct{ .x = 10 };

    // Create a destination slice that is too small.
    var small_buffer = [_]u8{0};

    // Call the function and expect an empty slice.
    const ptr_slice = message.ptrToSlice(MyStruct, &my_struct_instance, &small_buffer);

    try std.testing.expectEqual(ptr_slice.len, 0);
}

test "structToSlice and structFromSlice" {
    const MyStruct = struct {
        a: u32,
        b: u32,
    };
    const struct_size = @sizeOf(MyStruct);

    // Initial struct instance
    var original_struct = MyStruct{ .a = 1, .b = 2 };

    // Create a destination buffer
    var buffer: [struct_size]u8 = undefined;

    // Convert the struct to the slice (copying data)
    const filled_slice = message.structToSlice(MyStruct, &original_struct, &buffer);
    try std.testing.expectEqual(filled_slice.len, struct_size);

    // Create a new struct to restore the data into
    var restored_struct = MyStruct{ .a = 0, .b = 0 };

    // Convert the slice back to the struct (copying data)
    const success = message.structFromSlice(MyStruct, filled_slice, &restored_struct);
    try std.testing.expect(success);

    // Verify the restored data
    try std.testing.expectEqual(restored_struct.a, 1);
    try std.testing.expectEqual(restored_struct.b, 2);
}

test "structToSlice with too small destination" {
    const MyStruct = struct {
        a: u32,
        b: u32,
    };
    const struct_size = @sizeOf(MyStruct);

    var original_struct = MyStruct{ .a = 1, .b = 2 };

    // Create a destination buffer that is too small
    var small_buffer: [struct_size - 1]u8 = undefined;

    const result = message.structToSlice(MyStruct, &original_struct, &small_buffer);
    try std.testing.expectEqual(result.len, 0);
}

test "structFromSlice with invalid size" {
    const MyStruct = struct {
        a: u32,
        b: u32,
    };

    // Create a slice with an incorrect size
    const invalid_slice = [_]u8{ 1, 2, 3, 4 };

    var restored_struct = MyStruct{ .a = 0, .b = 0 };
    const success = message.structFromSlice(MyStruct, &invalid_slice, &restored_struct);
    try std.testing.expect(!success);
}

const message = @import("tofu").message;
const TextHeaderIterator = message.TextHeaderIterator;

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
