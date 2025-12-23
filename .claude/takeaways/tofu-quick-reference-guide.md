# Tofu Quick Reference Guide

## Purpose

This document provides quick reference for developers working with tofu. Use this when you need to quickly look up common operations, patterns, or error handling.

For detailed explanations, see:
- `tofu-philosophy-and-advantages.md` - Why tofu works this way
- `message-patterns-and-recipes.md` - Detailed patterns and examples

---

## Core Concepts (30-Second Summary)

**Tofu Philosophy:**
- Message is the API
- Design through conversation (like S/R dialog)
- Messages are cubes - combine them to build flows

**Three Main Components:**
1. **Ampe** - The engine (owns resources)
2. **ChannelGroup** - Manages message exchange
3. **Message** - Data + command (16-byte header + optional text headers + optional body)

**Message Roles:**
- **Request** - expects response
- **Response** - replies to request (same message_id)
- **Signal** - one-way, no response

---

## Common Operations Reference

### 1. Initialize Engine

```zig
// Create reactor (engine implementation)
var rtr: *Reactor = try Reactor.Create(gpa, DefaultOptions);
defer rtr.*.Destroy();

// Get Ampe interface
const ampe: Ampe = try rtr.*.ampe();

// Create channel group
const chnls: ChannelGroup = try ampe.create();
defer tofu.DestroyChannels(ampe, chnls);
```

### 2. Get and Release Messages

```zig
// Get message from pool
var msg: ?*Message = try ampe.get(.always);
defer ampe.put(&msg);  // Always use defer

// Configure message
msg.?.*.bhdr.proto.mtype = .hello;
msg.?.*.bhdr.proto.role = .request;
msg.?.*.bhdr.channel_number = channelNum;

// Send (msg becomes null after this)
_ = try chnls.enqueueToPeer(&msg);
```

### 3. Start TCP Server

```zig
const port: u16 = try tofu.FindFreeTcpPort();

var cfg: Configurator = .{
    .tcp_server = TCPServerConfigurator.init("0.0.0.0", port)
};

var welcomeMsg: ?*Message = try ampe.get(.always);
defer ampe.put(&welcomeMsg);

try cfg.prepareRequest(welcomeMsg.?);

const bhdr: BinaryHeader = try chnls.enqueueToPeer(&welcomeMsg);

var response: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
defer ampe.put(&response);

// Check response.?.*.bhdr.status == 0 for success
```

### 4. Connect TCP Client

```zig
var cfg: Configurator = .{
    .tcp_client = TCPClientConfigurator.init("127.0.0.1", port)
};

var helloMsg: ?*Message = try ampe.get(.always);
defer ampe.put(&helloMsg);

try cfg.prepareRequest(helloMsg.?);

const bhdr: BinaryHeader = try chnls.enqueueToPeer(&helloMsg);

var response: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&response);

// Check response for connection status
```

### 5. Send Request

```zig
var request: ?*Message = try ampe.get(.always);
defer ampe.put(&request);

request.?.*.bhdr.proto.mtype = .regular;
request.?.*.bhdr.proto.role = .request;
request.?.*.bhdr.channel_number = channelNum;

// Optional: Add text headers
try request.?.*.thdrs.add("MyHeader", "value");

// Optional: Add body
try request.?.*.body.append(data);

const sentBhdr: BinaryHeader = try chnls.enqueueToPeer(&request);
```

### 6. Send Response

```zig
// Reuse received message
receivedMsg.?.*.bhdr.proto.role = .response;
receivedMsg.?.*.bhdr.proto.origin = .application;

// Optionally modify body or headers

_ = try chnls.enqueueToPeer(&receivedMsg);
```

### 7. Send Signal

```zig
var signal: ?*Message = try ampe.get(.always);
defer ampe.put(&signal);

signal.?.*.bhdr.proto.mtype = .regular;
signal.?.*.bhdr.proto.role = .signal;
signal.?.*.bhdr.channel_number = channelNum;
signal.?.*.bhdr.message_id = correlationId;

_ = try chnls.enqueueToPeer(&signal);
```

### 8. Receive Messages

```zig
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

if (msg == null) {
    // Timeout occurred
    return;
}

// Check status
const st: u8 = msg.?.*.bhdr.status;
if (st != 0) {
    // Handle error (see error handling section)
}

// Process message based on type and role
switch (msg.?.*.bhdr.proto.mtype) {
    .hello => {}, // Handle hello
    .bye => {},   // Handle bye
    .regular => {}, // Handle application message
    else => {},
}
```

### 9. Close Connection (Graceful)

```zig
var byeRequest: ?*Message = try ampe.get(.always);
defer ampe.put(&byeRequest);

byeRequest.?.*.bhdr.proto.mtype = .bye;
byeRequest.?.*.bhdr.proto.role = .request;
byeRequest.?.*.bhdr.channel_number = channelNum;

_ = try chnls.enqueueToPeer(&byeRequest);

// Wait for ByeResponse
var byeResponse: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&byeResponse);
```

### 10. Close Connection (Force)

```zig
var byeSignal: ?*Message = try ampe.get(.always);
defer ampe.put(&byeSignal);

byeSignal.?.*.bhdr.proto.mtype = .bye;
byeSignal.?.*.bhdr.proto.role = .signal;
byeSignal.?.*.bhdr.proto.oob = .on;  // High priority
byeSignal.?.*.bhdr.channel_number = channelNum;

_ = try chnls.enqueueToPeer(&byeSignal);

// Wait for channel_closed status
var closeMsg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&closeMsg);
```

---

## Error Handling Reference

### Check Message Status

```zig
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

const st: u8 = msg.?.*.bhdr.status;
const ampeSt: AmpeStatus = status.raw_to_status(st);

// Check who created this status
if (msg.?.*.bhdr.proto.origin == .engine) {
    // Engine status
    switch (ampeSt) {
        .success => {},
        .pool_empty => try handlePoolEmpty(),
        .connect_failed => return error.ConnectFailed,
        .channel_closed => return error.ChannelClosed,
        else => return status.status_to_error(ampeSt),
    }
} else {
    // Application status - your custom logic
    if (st != 0) {
        // Handle your error
    }
}
```

### Common Status Values

| Status | Meaning | Action |
|--------|---------|--------|
| `.success` | Operation succeeded | Continue |
| `.pool_empty` | Message pool is empty | Add messages to pool |
| `.connect_failed` | Connection failed | Retry or abort |
| `.channel_closed` | Channel closed | Clean up |
| `.invalid_address` | Bad IP/port/path | Fix configuration |
| `.uds_path_not_found` | UDS file not found | Check path or retry |
| `.receiver_update` | Wake signal from updateReceiver | Handle notification |

### Handle Pool Empty

```zig
// Method 1: Add messages to pool
if (ampeSt == .pool_empty) {
    const allocator: Allocator = ampe.getAllocator();
    for (0..3) |_| {
        var newMsg: ?*Message = try Message.create(allocator);
        ampe.put(&newMsg);
    }
    continue;  // Retry
}

// Method 2: Use poolOnly strategy
var msg: ?*Message = try ampe.get(.poolOnly);
if (msg == null) {
    // Pool empty - handle it
    std.Thread.sleep(100 * std.time.ns_per_ms);
    continue;
}
defer ampe.put(&msg);
```

---

## Threading Reference

### Thread-Safe Operations

These can be called from **multiple threads**:
```zig
ampe.get()              // Get message from pool
ampe.put()              // Return message to pool
ampe.create()           // Create channel group
ampe.destroy()          // Destroy channel group
chnls.enqueueToPeer()   // Send message
chnls.updateReceiver()  // Wake or notify receiver
```

### Single-Thread Operations

These can be called from **ONE thread only** per ChannelGroup:
```zig
chnls.waitReceive()     // Wait for message
```

### Wake Receiver from Another Thread

```zig
// Thread A: Waiting
while (true) {
    var msg: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&msg);

    if (status.raw_to_status(msg.?.*.bhdr.status) == .receiver_update) {
        break;  // Woken up
    }
}

// Thread B: Wake Thread A
var nullMsg: ?*Message = null;
try chnls.updateReceiver(&nullMsg);
```

---

## Configuration Quick Reference

### TCP Server

```zig
.tcp_server = TCPServerConfigurator.init("0.0.0.0", port)
```
- `"0.0.0.0"` = listen on all interfaces
- `"127.0.0.1"` = listen on localhost only
- Specific IP = listen on that interface only

### TCP Client

```zig
.tcp_client = TCPClientConfigurator.init("127.0.0.1", port)
```
- Use server IP address
- Use server port number

### UDS Server

```zig
.uds_server = UDSServerConfigurator.init("/tmp/tofu.sock")
```
- Use file path
- Path must not exist (will be created)

### UDS Client

```zig
.uds_client = UDSClientConfigurator.init("/tmp/tofu.sock")
```
- Use same path as server
- Path must exist

---

## Message Structure Quick Reference

### BinaryHeader Fields

```zig
.channel_number: u16   // Which connection
.proto.mtype           // .welcome, .hello, .bye, .regular
.proto.role            // .request, .response, .signal
.proto.origin          // .application, .engine
.proto.more            // .last, .expected (for multi-message)
.proto.oob             // .off, .on (priority)
.status: u8            // 0 = success, non-zero = error
.message_id: u64       // Correlation ID
```

### Message Types

| Type | Channel | Used For |
|------|---------|----------|
| `.welcome` | 0 | Server starts listening |
| `.hello` | 0 | Client connects |
| `.bye` | Non-zero | Close connection |
| `.regular` | Non-zero | Application messages |

### Message Roles

| Role | Meaning | Message ID |
|------|---------|------------|
| `.request` | Expects response | Auto-generated or custom |
| `.response` | Replies to request | Same as request |
| `.signal` | One-way | Auto-generated or custom |

---

## Common Patterns Quick Reference

### Request-Response Pattern

```zig
// Send request, save BinaryHeader
const sentBh: BinaryHeader = try chnls.enqueueToPeer(&request);

// Receive response, check message_id
var response: ?*Message = try chnls.waitReceive(timeout);
assert(response.?.*.bhdr.message_id == sentBh.message_id);
```

### Multi-Request Pattern

```zig
const jobId: u64 = 12345;

// Send multiple requests with same message_id
for (chunks) |chunk, i| {
    msg.?.*.bhdr.message_id = jobId;
    msg.?.*.bhdr.proto.more = if (i == chunks.len - 1) .last else .expected;
    // Send chunk
}
```

### Progress Signal Pattern

```zig
// Send progress updates with same message_id as job
progress.?.*.bhdr.proto.role = .signal;
progress.?.*.bhdr.message_id = jobId;
try progress.?.*.thdrs.add("Progress", "[5:10]");
```

---

## Pool Configuration Reference

```zig
pub const Options = struct {
    initialPoolMsgs: ?u16 = null,  // Created at start
    maxPoolMsgs: ?u16 = null,      // Maximum size
};

const DefaultOptions: Options = .{
    .initialPoolMsgs = 16,
    .maxPoolMsgs = 64,
};
```

**Tuning Guide:**
- See frequent `pool_empty` → increase `maxPoolMsgs`
- High memory usage → decrease `maxPoolMsgs`
- Set `initialPoolMsgs` = expected concurrent messages

---

## Timeout Constants

```zig
tofu.waitReceive_INFINITE_TIMEOUT  // Wait forever
tofu.waitReceive_SEC_TIMEOUT       // 1 second
```

**Custom timeout:**
```zig
const timeout: u64 = 5 * std.time.ns_per_s;  // 5 seconds
```

---

## Allocation Strategies

```zig
.poolOnly   // Return null if pool empty
.always     // Create new if pool empty
```

**When to use:**
- `.poolOnly` - Performance critical, handle pool_empty yourself
- `.always` - Simpler code, pool exhaustion rare

---

## Text Headers Reference

### Add Header

```zig
try msg.?.*.thdrs.add("Name", "Value");
```

### Read Headers

```zig
var it: TextHeaderIterator = TextHeaderIterator.init(msg.?.*.thdrs.slice());
while (it.next()) |header| {
    // header.name
    // header.value
}
```

---

## Debugging Tips

### Dump Message Metadata

```zig
msg.?.*.bhdr.dumpMeta("received message");
```

Output example:
```
received message: ch=123 mtype=regular role=request origin=application status=0 mid=456
```

### Check Channel Number

```zig
log.debug("Channel: {d}", .{msg.?.*.bhdr.channel_number});
```

### Check Message ID

```zig
log.debug("Message ID: {d}", .{msg.?.*.bhdr.message_id});
```

---

## Common Mistakes

### ❌ Using Message After Send

```zig
_ = try chnls.enqueueToPeer(&msg);
msg.?.*.bhdr.status = 0;  // WRONG! msg is null now
```

✅ **Correct:**
```zig
const bhdr: BinaryHeader = try chnls.enqueueToPeer(&msg);
// msg is null, but you saved bhdr
```

### ❌ Forgetting defer

```zig
var msg: ?*Message = try ampe.get(.always);
// Forgot defer - message leaks if error occurs
```

✅ **Correct:**
```zig
var msg: ?*Message = try ampe.get(.always);
defer ampe.put(&msg);  // Always runs
```

### ❌ Multiple Threads, One waitReceive

```zig
// Thread 1
var msg1: ?*Message = try chnls.waitReceive(timeout);  // WRONG!

// Thread 2
var msg2: ?*Message = try chnls.waitReceive(timeout);  // WRONG!
```

✅ **Correct:**
```zig
// One thread per ChannelGroup for waitReceive
// Or create separate ChannelGroup per thread
```

### ❌ Ignoring Status

```zig
var msg: ?*Message = try chnls.waitReceive(timeout);
// Didn't check msg.?.*.bhdr.status
```

✅ **Correct:**
```zig
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

const st: u8 = msg.?.*.bhdr.status;
if (st != 0) {
    // Handle error
}
```

---

## File Locations

### Recipe Files (Examples)
- `recipes/cookbook.zig` - Basic patterns
- `recipes/services.zig` - Service patterns (EchoService, EchoClient)
- `recipes/MultiHomed.zig` - Multiple listeners

### Core Source Files
- `src/tofu.zig` - Public API exports
- `src/ampe.zig` - Ampe interface
- `src/message.zig` - Message structure
- `src/status.zig` - Status/error handling
- `src/configurator.zig` - TCP/UDS configuration

### Test Files
- `tests/reactor_tests.zig` - Engine tests
- `tests/message_tests.zig` - Message tests
- `tests/configurator_tests.zig` - Configuration tests

---

## Quick Start Checklist

1. ✅ Create Reactor (engine)
2. ✅ Get Ampe interface
3. ✅ Create ChannelGroup
4. ✅ Configure server (Welcome) or client (Hello)
5. ✅ Start message loop (waitReceive)
6. ✅ Handle messages based on type/role
7. ✅ Clean up (Destroy ChannelGroup, Destroy Reactor)

---

## When Things Go Wrong

### Connection Fails
- Check IP address and port
- Ensure server is running first
- Check firewall
- Check `status == .connect_failed`

### Pool Empty
- Increase `maxPoolMsgs`
- Add messages to pool dynamically
- Check for message leaks (missing put())

### Channel Closed Unexpectedly
- Check peer disconnected
- Check network errors
- Handle `.channel_closed` status

### waitReceive Blocks Forever
- Use timeout instead of INFINITE_TIMEOUT
- Check peer is sending messages
- Use updateReceiver to wake

---

## Learning Resources

**Start here:**
1. `tofu-philosophy-and-advantages.md` - Understand why
2. `message-patterns-and-recipes.md` - Learn how
3. This file - Quick lookup

**Code examples:**
1. `recipes/cookbook.zig` - Read from top to bottom
2. Try EchoService pattern first
3. Study MultiHomed for advanced patterns

**Key dialog:**
- S/R dialog in README.md - Shows how to design protocols

---

## Contact and Feedback

- GitHub Issues: https://github.com/anthropics/claude-code/issues
- Documentation: https://g41797.github.io/tofu/

---

## Version Info

This quick reference is for tofu using Zig 0.14.0+

Main protocol: YAAAMP (Yet Another Asynchronous Application Messaging Protocol)

---

**Last Updated:** Generated during documentation update session
**Target Audience:** Developers (including non-English speakers)
**Companion Docs:** `tofu-philosophy-and-advantages.md`, `message-patterns-and-recipes.md`
