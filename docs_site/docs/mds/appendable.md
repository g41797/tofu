

# Appendable

The body buffer type used in messages. Manages a growable byte buffer.

---

## What It Is

`Appendable` is a dynamically growable byte buffer. Messages use it for the body field:

```zig
pub const Message = struct {
    bhdr: BinaryHeader = .{},
    thdrs: TextHeaders = .{},
    body: Appendable = .{},   // <-- This
    // ...
};
```

You don't create Appendable directly. tofu creates and manages it. You just use it.

---

## Reading Data

Get the current content:

```zig
const data = msg.?.body.body();  // Returns ?[]const u8
```

Returns `null` if:

- Buffer not allocated
- Buffer is empty (length = 0)

Safe pattern:

```zig
if (msg.?.body.body()) |data| {
    // data is []const u8
    processData(data);
} else {
    // No body data
}
```

---

## Writing Data

Add bytes to the buffer:

```zig
try msg.?.body.append(my_data);  // Grows automatically if needed
```

Replace all content:

```zig
try msg.?.body.copy(new_data);   // Resets then appends
```

Clear the buffer:

```zig
msg.?.body.reset();  // Sets length to 0, keeps memory allocated
```

---

## Methods Summary

| Method | Returns | Description |
|--------|---------|-------------|
| `body()` | `?[]const u8` | Current data slice, or null if empty |
| `append(data)` | `!void` | Add bytes, auto-grows buffer |
| `copy(data)` | `!void` | Replace content (reset + append) |
| `reset()` | `void` | Clear length to 0, keep memory |

---

## Size Limit

!!! warning "64 KiB - 1 maximum"
    Body content is limited to 65535 bytes (64 KiB - 1).
    For larger data, use streaming with the `more` flag.

---

## Memory Management

tofu handles all memory:

- Buffer is pre-allocated when message is created
- `append()` grows buffer automatically if needed
- `reset()` clears without freeing (efficient for reuse)

[//]: # (- Buffer is freed when message returns to pool) - consider add this functionality to pool

You never need to call `init()` or `deinit()`.

---

## Common Patterns

### Check before read

```zig
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

if (msg.?.body.body()) |data| {
    // Process data
} else {
    // Empty body - handle accordingly
}
```

### Build response in place

```zig
// Reuse received message for response
msg.?.bhdr.proto.opCode = .Response;
msg.?.body.reset();                    // Clear old content
try msg.?.body.append("result: ");     // Add new content
try msg.?.body.append(result_data);
_ = try chnls.post(&msg);
```

### Accumulate streamed data

```zig
var buffer = std.ArrayList(u8).init(allocator);
defer buffer.deinit();

while (true) {
    var msg: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&msg);

    if (msg.?.body.body()) |chunk| {
        try buffer.appendSlice(chunk);
    }

    if (!msg.?.hasMore()) break;
}
// buffer.items contains all accumulated data
```

