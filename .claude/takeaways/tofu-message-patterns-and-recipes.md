# Tofu Message Patterns and Recipe Guide

## Overview

This document explains how to work with tofu messages. It shows common patterns from the recipe files. It explains the message-as-cube concept.

---

## Message Anatomy: The Three Parts

Every tofu message has three parts:

### 1. **Persistent Fields** (Sent Between Peers)

#### BinaryHeader (16 bytes, big-endian on wire)
```zig
pub const BinaryHeader = packed struct {
    channel_number: u16,      // Which channel (connection)
    proto: ProtoFields,       // 8 bits: type, role, origin, more, oob
    status: u8,               // Success (0) or error code
    message_id: u64,          // Unique identifier
    @"<thl>": u16,           // Text headers length (engine-managed)
    @"<bl>": u16,            // Body length (engine-managed)
};
```

**ProtoFields contains:**
- `mtype` (3 bits): welcome, hello, bye, regular
- `role` (2 bits): request, response, signal
- `origin` (1 bit): application or engine
- `more` (1 bit): more messages in sequence coming
- `oob` (1 bit): out-of-band (high priority)

#### TextHeaders (Optional, HTTP-style key-value pairs)
```
PDL: PDF\r\n
JobTicket: JDF\r\n
Progress: [1:10]\r\n
\r\n
```

#### Body (Optional, application data)
Binary or text data. The tofu engine does not interpret this data.

### 2. **Transient Fields** (Not Sent)

```zig
@"<void*>": ?*anyopaque,  // Your application can use this
@"<ctx>": ?*anyopaque,    // Tofu engine uses this internally
```

### 3. **Intrusive List Nodes** (For Internal Queue Management)

```zig
prev: ?*Self,  // Previous message in queue
next: ?*Self,  // Next message in queue
```

---

## Message Lifecycle: Pool → Use → Pool

### The Rule
**Messages come from a pool. Messages return to the pool. Always use get() and put().**

```zig
// 1. Get message from pool
var msg: ?*Message = try ampe.get(.always);

// 2. Use defer to ensure message returns to pool
defer ampe.put(&msg);

// 3. Set message fields
msg.?.*.bhdr.proto.mtype = .hello;
msg.?.*.bhdr.proto.role = .request;
try msg.?.*.thdrs.add("Config", "value");

// 4. Send (ownership moves to engine, msg becomes null)
_ = try chnls.enqueueToPeer(&msg);

// After send, msg is null. You cannot use it anymore.
```

### Allocation Strategies

```zig
pub const AllocationStrategy = enum {
    poolOnly,  // Return null if pool is empty
    always,    // Create new message if pool is empty
};
```

**Use poolOnly when:**
- Performance is critical
- You want to handle pool_empty status yourself
- You have backup logic

**Use always when:**
- You want simpler code
- You do not want to handle null returns
- Pool exhaustion is rare

### Pool Configuration

```zig
pub const Options = struct {
    initialPoolMsgs: ?u16 = null,  // Messages created at start
    maxPoolMsgs: ?u16 = null,      // Maximum pool size
};

const DefaultOptions: Options = .{
    .initialPoolMsgs = 16,
    .maxPoolMsgs = 64,
};
```

**How to tune the pool:**
- Start with default values
- If you see frequent `pool_empty` status → increase `maxPoolMsgs`
- If memory usage is too high → decrease `maxPoolMsgs`
- Set `initialPoolMsgs` = expected number of concurrent messages

---

## Common Message Patterns

### Pattern 1: Request-Response

**From S/R Dialog:** "I will send a HelloRequest" → "Send me a HelloResponse"

```zig
// Client sends request
var request: ?*Message = try ampe.get(.always);
defer ampe.put(&request);

request.?.*.bhdr.proto.mtype = .hello;
request.?.*.bhdr.proto.role = .request;
request.?.*.bhdr.channel_number = 0;  // Hello uses channel 0

const sentBhdr: BinaryHeader = try chnls.enqueueToPeer(&request);

// Server receives and responds
var received: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&received);

assert(received.?.*.bhdr.proto.mtype == .hello);
assert(received.?.*.bhdr.proto.role == .request);

// Server reuses the received message to send response
received.?.*.bhdr.proto.role = .response;
_ = try chnls.enqueueToPeer(&received);

// Client receives response
var response: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&response);

assert(response.?.*.bhdr.message_id == sentBhdr.message_id);  // Same ID
```

**Important:** Response uses the same message_id as request.

### Pattern 2: Multi-Request Sequence

**From S/R Dialog:** "multi-requests with message ID equal to job ID"

```zig
const jobId: u64 = 12345;

// Send multiple messages for one job
for (chunks) |chunk| {
    var msg: ?*Message = try ampe.get(.always);
    defer ampe.put(&msg);

    msg.?.*.bhdr.proto.mtype = .regular;
    msg.?.*.bhdr.proto.role = .request;
    msg.?.*.bhdr.message_id = jobId;  // Same ID for all chunks
    msg.?.*.bhdr.channel_number = channelNum;

    // Is this the last chunk?
    if (chunk == chunks[chunks.len - 1]) {
        msg.?.*.bhdr.proto.more = .last;
    } else {
        msg.?.*.bhdr.proto.more = .expected;
    }

    // Add chunk data to body
    try msg.?.*.body.append(chunk);

    _ = try chnls.enqueueToPeer(&msg);
}
```

**Important:** Same message_id connects related messages.

### Pattern 3: Signal (One-Way)

**From S/R Dialog:** "I will send signals with the same message ID for progress"

```zig
// Progress update (no response expected)
var progress: ?*Message = try ampe.get(.always);
defer ampe.put(&progress);

progress.?.*.bhdr.proto.mtype = .regular;
progress.?.*.bhdr.proto.role = .signal;  // Signal means no response
progress.?.*.bhdr.message_id = jobId;
progress.?.*.bhdr.channel_number = channelNum;

// Add progress data
try progress.?.*.thdrs.add("Progress", "[5:10]");

_ = try chnls.enqueueToPeer(&progress);
```

**Important:** Signals do not expect responses. Fire and forget.

### Pattern 4: Out-of-Band (Priority)

```zig
// Close connection immediately
var bye: ?*Message = try ampe.get(.always);
defer ampe.put(&bye);

bye.?.*.bhdr.proto.mtype = .bye;
bye.?.*.bhdr.proto.role = .signal;
bye.?.*.bhdr.proto.oob = .on;  // High priority
bye.?.*.bhdr.channel_number = channelNum;

_ = try chnls.enqueueToPeer(&bye);
```

**Important:** OOB messages go to front of send queue.

---

## Recipe File Patterns

### Pattern A: EchoService (services.zig)

**Purpose:** Simple echo server. Receives request. Sends response.

**Code pattern:**
```zig
fn processMessage(echo: *EchoService, msg: *?*Message) bool {
    // Check if pool is empty
    if (status.raw_to_status(msg.*.?.*.bhdr.status) == .pool_empty) {
        return echo.*.addMessagesToPool();
    }

    // Change request to response
    if (msg.*.?.*.bhdr.proto.role == .request) {
        msg.*.?.*.bhdr.proto.role = .response;
    }

    // Send back
    _ = echo.*.sendTo.?.enqueueToPeer(msg) catch {
        return false;
    };

    return true;  // Continue processing
}
```

**What you learn:**
- Handle `pool_empty` by adding messages to pool
- You can reuse messages (change request to response)
- Return `true` to continue processing. Return `false` to stop.

### Pattern B: EchoClient (services.zig)

**Purpose:** Complete client: connect → exchange messages → disconnect

**Code pattern:**
```zig
fn connect(self: *Self) !void {
    // Send HelloRequest
    var helloRequest: ?*Message = self.*.ampe.get(.always) catch unreachable;
    defer self.*.ampe.put(&helloRequest);

    self.*.cfg.prepareRequest(helloRequest.?) catch unreachable;
    self.*.helloBh = try self.*.chnls.?.enqueueToPeer(&helloRequest);

    // Wait for response. Retry on pool_empty.
    while (true) {
        var response: ?*Message = try self.*.chnls.?.waitReceive(timeout);
        defer self.*.ampe.put(&response);

        // Check status
        const sts: AmpeStatus = status.raw_to_status(response.?.*.bhdr.status);

        if (sts == .pool_empty) {
            continue;  // defer returns message to pool. Try again.
        }

        if (response.?.*.bhdr.proto.origin == .engine) {
            // This error came from tofu engine
            return status.status_to_error(sts);
        }

        // Success
        assert(response.?.*.bhdr.proto.mtype == .hello);
        assert(response.?.*.bhdr.proto.role == .response);
        break;
    }
}
```

**What you learn:**
- Save BinaryHeader from send. You need it for correlation.
- Loop on `waitReceive` to handle pool_empty
- Check `origin` field. Distinguishes engine errors from application errors.
- Use defer pattern for all messages

### Pattern C: MultiHomed (MultiHomed.zig)

**Purpose:** One thread. Multiple listeners. Multiple clients.

**Code pattern:**
```zig
fn mainLoop(mh: *MultiHomed) void {
    while (true) {
        var receivedMsg: ?*Message = mh.*.chnls.?.waitReceive(timeout) catch {
            return;
        };
        defer mh.*.ampe.?.put(&receivedMsg);

        const sts: AmpeStatus = status.raw_to_status(receivedMsg.?.*.bhdr.status);

        // Check for stop command
        if (sts == .receiver_update) {
            return;
        }

        // Check if this is a listener channel
        if (mh.*.lstnChnls.?.contains(receivedMsg.?.*.bhdr.channel_number)) {
            // Listener channel has error
            return;
        }

        // This is a client channel. Pass to service.
        const cont: bool = mh.*.srvcs.onMessage(&receivedMsg);
        if (!cont) {
            return;
        }
    }
}
```

**What you learn:**
- One `waitReceive()` handles all channels
- You dispatch by channel_number
- `receiver_update` status means another thread woke you up
- Cooperative service pattern

### Pattern D: Reconnection (cookbook.zig)

**Purpose:** Handle connection failures without crashing

**Code pattern:**
```zig
fn tryToConnect(cc: *ClientConnector, recvd: *?*Message) !bool {
    defer cc.*.ampe.put(recvd);

    if (cc.*.connected) {
        return true;
    }

    // First time: send HelloRequest
    if (cc.helloBh == null) {
        var helloClone: ?*Message = try cc.*.helloRequest.?.*.clone();
        cc.*.helloBh = cc.*.chnls.?.enqueueToPeer(&helloClone) catch |err| {
            cc.*.ampe.put(&helloClone);
            return err;
        };
    }

    // No response yet
    if (recvd.* == null) {
        return false;
    }

    // Check status and decide what to do
    switch (status.raw_to_status((*recvd.*.?).bhdr.status)) {
        .success => {
            cc.*.connected = true;
            return true;
        },
        .connect_failed, .channel_closed => {
            cc.*.helloBh = null;  // Reset. Will retry.
            return false;
        },
        .invalid_address => return AmpeError.InvalidAddress,  // Fatal error
        .pool_empty => return false,  // Will retry
        else => |st| return status.status_to_error(st),
    }
}
```

**What you learn:**
- Save request message for retries. Clone if needed.
- Separate fatal errors from temporary errors
- Reset state on temporary failures
- Caller controls retry timing

---

## Error Handling Patterns

### Status Check Pattern

```zig
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

const st: u8 = msg.?.*.bhdr.status;
const ampeSt: AmpeStatus = status.raw_to_status(st);

// Check origin first
if (msg.?.*.bhdr.proto.origin == .engine) {
    // This is an engine status
    switch (ampeSt) {
        .success => {},
        .pool_empty => try addMessagesToPool(3),
        .connect_failed => return error.ConnectionFailed,
        .channel_closed => return error.ChannelClosed,
        else => return status.status_to_error(ampeSt),
    }
} else {
    // This is application status. Your custom logic.
    if (st != 0) {
        // Handle your application error
    }
}
```

### Pool Empty Handling

```zig
// Strategy 1: Add messages to pool
if (ampeSt == .pool_empty) {
    const allocator: Allocator = ampe.getAllocator();
    for (0..3) |_| {
        var newMsg: ?*Message = try Message.create(allocator);
        ampe.put(&newMsg);
    }
    continue;  // Retry operation
}

// Strategy 2: Use poolOnly and handle null
var msg: ?*Message = try ampe.get(.poolOnly);
if (msg == null) {
    // Pool is empty. Do something else or wait.
    std.Thread.sleep(100 * std.time.ns_per_ms);
    continue;
}
defer ampe.put(&msg);
```

---

## Threading Patterns

### Single-Threaded Pattern

```zig
// One engine. One channel group. One thread.
const rtr: *Reactor = try Reactor.Create(gpa, options);
defer rtr.*.Destroy();

const ampe: Ampe = try rtr.*.ampe();
const chnls: ChannelGroup = try ampe.create();
defer tofu.DestroyChannels(ampe, chnls);

// All operations happen on this thread
while (true) {
    var msg: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&msg);
    // Process msg here
}
```

### Multi-Threaded Pattern

```zig
// One engine. Multiple channel groups. Multiple threads.
const rtr: *Reactor = try Reactor.Create(gpa, options);
defer rtr.*.Destroy();

const ampe: Ampe = try rtr.*.ampe();

// Thread 1: Server
const serverChnls: ChannelGroup = try ampe.create();
const serverThread = try std.Thread.spawn(.{}, serverLoop, .{ampe, serverChnls});

// Thread 2: Client
const clientChnls: ChannelGroup = try ampe.create();
const clientThread = try std.Thread.spawn(.{}, clientLoop, .{ampe, clientChnls});

// These operations are thread-safe:
// - ampe.get() / ampe.put()
// - chnls.enqueueToPeer()
// - chnls.updateReceiver()

// This operation is NOT thread-safe:
// - chnls.waitReceive() - call from ONE thread only per ChannelGroup
```

### updateReceiver Pattern

```zig
// Thread A: Waiting for messages
while (true) {
    var msg: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&msg);

    if (status.raw_to_status(msg.?.*.bhdr.status) == .receiver_update) {
        // Another thread woke me up
        break;
    }
}

// Thread B: Wake Thread A
var nullMsg: ?*Message = null;
try chnls.updateReceiver(&nullMsg);  // Wake waitReceive

// Or send data to Thread A
var notifyMsg: ?*Message = try ampe.get(.always);
try notifyMsg.?.*.thdrs.add("Command", "stop");
try chnls.updateReceiver(&notifyMsg);  // notifyMsg becomes null
```

---

## Configuration Patterns

### TCP Server

```zig
var cfg: Configurator = .{
    .tcp_server = TCPServerConfigurator.init("0.0.0.0", port)
};

var msg: ?*Message = try ampe.get(.always);
try cfg.prepareRequest(msg.?);  // This adds TextHeaders to message

msg.?.*.bhdr.proto.mtype = .welcome;
msg.?.*.bhdr.proto.role = .request;
```

### TCP Client

```zig
var cfg: Configurator = .{
    .tcp_client = TCPClientConfigurator.init("127.0.0.1", port)
};

var msg: ?*Message = try ampe.get(.always);
try cfg.prepareRequest(msg.?);  // This adds TextHeaders to message

msg.?.*.bhdr.proto.mtype = .hello;
msg.?.*.bhdr.proto.role = .request;
```

### UDS Server/Client

```zig
const path: []const u8 = "/tmp/tofu.sock";

var srvCfg: Configurator = .{
    .uds_server = UDSServerConfigurator.init(path)
};

var cltCfg: Configurator = .{
    .uds_client = UDSClientConfigurator.init(path)
};
```

---

## Message as Cube: Real Example

The S/R dialog with actual message structures:

### Cube 1: Hello with PDL

```zig
// Worker tells server: I can handle PDF or PS
var hello: Message = .{
    .bhdr = .{
        .channel_number = 0,
        .proto = .{ .mtype = .hello, .role = .request, .origin = .application },
        .status = 0,
        .message_id = 1,
    },
};
try hello.thdrs.add("PDL", "PDF");  // Add PDL type to message
```

### Cube 2: Job Ticket

```zig
// First request: send ticket
var jobTicket: Message = .{
    .bhdr = .{
        .channel_number = channelNum,
        .proto = .{ .mtype = .regular, .role = .request, .origin = .application },
        .message_id = jobId,  // Job ID becomes message ID
    },
};
try jobTicket.thdrs.add("JobTicket", "JDF");
try jobTicket.body.append(ticketData);
```

### Cube 3: PDL Data

```zig
// Next requests: send PDL chunks
var pdfChunk: Message = .{
    .bhdr = .{
        .channel_number = channelNum,
        .proto = .{
            .mtype = .regular,
            .role = .request,
            .origin = .application,
            .more = .expected,  // More chunks are coming
        },
        .message_id = jobId,  // Same job
    },
};
try pdfChunk.thdrs.add("PDL", "PDF");
try pdfChunk.body.append(pdfData);
```

### Cube 4: Progress Signal

```zig
// Progress update
var progress: Message = .{
    .bhdr = .{
        .channel_number = channelNum,
        .proto = .{ .mtype = .regular, .role = .signal, .origin = .application },
        .message_id = jobId,  // Same job
    },
};
try progress.thdrs.add("Progress", "[5:10]");  // Page 5 of 10
```

**Pattern:** Each cube is independent. But they connect through:
- Same `channel_number` (one worker)
- Same `message_id` (one job)
- Different `role` (request vs signal)
- Different headers (JobTicket vs PDL vs Progress)

This shows **message-as-cube**. You combine simple cubes to build complex flows.

---

## Summary: Important Points

### 1. **Messages Use Pool**
Always use `get()` and `put()`. The defer pattern helps you.

### 2. **Send Transfers Ownership**
After `enqueueToPeer()`, message becomes null. You cannot use it. This prevents bugs.

### 3. **Message ID is Context**
Use message_id for correlation. Use it for business transactions. Use it for multi-message sequences.

### 4. **Roles Have Meaning**
- Request: expects response
- Response: completes request (same message_id)
- Signal: one-way notification

### 5. **Headers Extend Protocol**
Add your own headers. Old code ignores unknown headers. No breaking changes.

### 6. **Status Byte Has Errors**
Check `origin` first. Engine errors are different from application errors.

### 7. **One ChannelGroup = One waitReceive Thread**
But many threads can call `enqueueToPeer()` and `updateReceiver()`.

### 8. **Channels are Independent**
Each channel is separate. No message routing needed.

---

## Learning Path

1. Read `cookbook.zig` examples in order
2. Try `EchoService` pattern first (most simple)
3. Study `MultiHomed` for multiple listeners
4. Learn reconnection patterns
5. Design your own message flow (like S and R did)

Remember: tofu provides foundations. You build your communication on top. You use simple message passing.

---

## Files Referenced

- `/home/g41797/dev/root/github.com/g41797/tofu/recipes/cookbook.zig` - Basic patterns
- `/home/g41797/dev/root/github.com/g41797/tofu/recipes/services.zig` - Service patterns
- `/home/g41797/dev/root/github.com/g41797/tofu/recipes/MultiHomed.zig` - Multiple listeners
- `/home/g41797/dev/root/github.com/g41797/tofu/src/message.zig` - Message structure
- `/home/g41797/dev/root/github.com/g41797/tofu/src/status.zig` - Status handling
