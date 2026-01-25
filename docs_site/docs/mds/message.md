

# Message

A tofu message has three parts. Only the first is required.

```
┌─────────────────┐
│  BinaryHeader   │  ← Always present (routing, type, status)
├─────────────────┤
│  TextHeaders    │  ← Optional (key-value metadata)
├─────────────────┤
│  Body           │  ← Optional (your data)
└─────────────────┘
```

---

## BinaryHeader

The fixed-size header that tofu uses for routing and processing.

```zig title="BinaryHeader structure"
pub const BinaryHeader = packed struct {
    channel_number: u16 = 0,    // Which channel this message belongs to
    proto: ProtoFields = .{},   // Operation type, origin, more flag
    status: u8 = 0,             // 0 = success, else error code
    message_id: u64 = 0,        // Your correlation ID
    // (internal length fields omitted)
};
```

### channel_number

Identifies which channel this message belongs to.

| Value | Meaning |
|-------|---------|
| `0` | Not assigned yet (used for HelloRequest, WelcomeRequest) |
| `1-65534` | Valid assigned channel |
| `65535` | Reserved for tofu internal use |

!!! warning "Only tofu assigns channel numbers"
    You create messages with channel 0. tofu assigns a real number during `post()`.
    Save the returned number for future use.

### proto (ProtoFields)

Contains the operation type and flags.

```zig title="ProtoFields structure"
pub const ProtoFields = packed struct(u8) {
    opCode: OpCode,           // 4 bits: what type of message
    origin: OriginFlag,       // 1 bit: from you or from tofu?
    more: MoreMessagesFlag,   // 1 bit: more coming?
    // (internal bits omitted)
};
```

### status

The result code. Zero means success.

```zig
if (msg.?.bhdr.status == 0) {
    // Success
} else {
    // Check what went wrong
    const sts = status.raw_to_status(msg.?.bhdr.status);
}
```

See [Errors and Statuses](statuses.md) for the full list.

### message_id

Your correlation ID. tofu preserves it but doesn't interpret it.

Use it to:

- Match responses to requests
- Track jobs across multiple messages
- Correlate progress updates with their job

```zig
// Send request with job ID
request.?.bhdr.message_id = job_id;
_ = try chnls.post(&request);

// Later, match response
if (response.?.bhdr.message_id == job_id) {
    // This is the response to our request
}
```

??? tip "NAQ: What if I don't set message_id?"
    If you leave it at 0, tofu assigns a sequential process-unique number during `post()`.
    The assigned value is returned in the BinaryHeader from `post()`.

---

## OpCode

The operation type. This tells tofu (and your peer) what the message means.

```zig title="All OpCodes"
pub const OpCode = enum(u4) {
    Request = 0,           // Ask peer for something
    Response = 1,          // Answer to a request
    Signal = 2,            // One-way notification
    HelloRequest = 3,      // Client: "I want to connect"
    HelloResponse = 4,     // Server: "Connection accepted"
    ByeRequest = 5,        // "Let's close gracefully"
    ByeResponse = 6,       // "OK, closing"
    ByeSignal = 7,         // "Close NOW" (no response)
    WelcomeRequest = 8,    // Server: "Start listening"
    WelcomeResponse = 9,   // tofu: "Listener ready"
};
```

### Grouping by purpose

**Setup messages:**

| OpCode | Who sends | Purpose |
|--------|-----------|---------|
| WelcomeRequest | Server app | Start listening for connections |
| WelcomeResponse | tofu | Confirm listener is ready |
| HelloRequest | Client app | Connect to a server |
| HelloResponse | Server app | Accept the connection |

**Data messages (after connection):**

| OpCode | Who sends | Purpose |
|--------|-----------|---------|
| Request | Either peer | Ask for something |
| Response | Either peer | Answer a request |
| Signal | Either peer | One-way notification |

**Close messages:**

| OpCode | Who sends | Purpose |
|--------|-----------|---------|
| ByeRequest | Either peer | Start graceful close |
| ByeResponse | Either peer | Acknowledge close |
| ByeSignal | Either peer | Close immediately |

### Setting OpCode

```zig
// For regular messages
msg.?.bhdr.proto.opCode = .Request;

// For connection messages, use address helpers (they set opCode automatically)
var addr: Address = .{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", 7099) };
try addr.format(msg.?);  // Sets opCode to .HelloRequest
```

---

## Origin Flag

Tells you where the message came from.

```zig
pub const OriginFlag = enum(u1) {
    application = 0,  // From your code or peer's code
    engine = 1,       // From tofu itself
};
```

**Why this matters:**

When you receive a message via `waitReceive()`, check origin first:

```zig
var msg = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

if (msg.?.isFromEngine()) {
    // This is a status notification from tofu
    // Check status field for what happened
    const sts = status.raw_to_status(msg.?.bhdr.status);
    switch (sts) {
        .pool_empty => { /* pool needs messages */ },
        .channel_closed => { /* channel died */ },
        else => {},
    }
} else {
    // This is a message from your peer
    // Process normally
}
```

!!! note "Always check origin first"
    Engine messages mean something happened internally (pool empty, channel closed, send failed).
    Application messages are from your peer.

---

## More Flag

For streaming multiple messages as one logical unit.

```zig
pub const MoreMessagesFlag = enum(u1) {
    last = 0,  // This is the final message
    more = 1,  // More messages coming with same message_id
};
```

**Example: Sending a file in chunks**

```zig
const job_id: u64 = getNextJobId();

while (hasMoreChunks()) {
    var msg = try ampe.get(.always);
    defer ampe.put(&msg);

    msg.?.bhdr.proto.opCode = .Request;
    msg.?.bhdr.channel_number = peer_channel;
    msg.?.bhdr.message_id = job_id;  // Same for all chunks
    msg.?.bhdr.proto.more = if (hasMoreChunks()) .more else .last;

    try msg.?.body.appendSlice(getNextChunk());
    _ = try chnls.post(&msg);
}
```

The receiver knows the stream is complete when `more == .last`.

---

## TextHeaders

Key-value pairs for structured metadata. Like HTTP headers.

```zig title="Adding a header"
try msg.?.thdrs.append("Content-Type", "application/json");
try msg.?.thdrs.append("Job-ID", "12345");
```

```zig title="Reading headers"
var it = msg.?.thdrs.hiter();
while (it.next()) |header| {
    // header.name, header.value
}
```

### Required headers

Some messages require specific headers:

| Message | Required Header | Example |
|---------|-----------------|---------|
| HelloRequest | `~connect_to` | `tcp\|127.0.0.1\|7099` |
| WelcomeRequest | `~listen_on` | `tcp\|0.0.0.0\|7099` |

!!! tip "Use address helpers"
    Don't build these headers manually. Use the address helpers:
    ```zig
    var addr: Address = .{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", 7099) };
    try addr.format(msg.?);  // Adds the header for you
    ```

---

## Body

Binary payload for your application data.

```zig title="Writing to body"
try msg.?.body.appendSlice(my_data);
```

```zig title="Reading body"
const data = msg.?.body.slc();
const length = msg.?.actual_body_len();
```

The body can hold any binary data. tofu doesn't interpret it.

---

## Creating Messages

### Get from pool

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);  // Always use defer
```

### Set up for sending

```zig title="Regular Request"
msg.?.bhdr.proto.opCode = .Request;
msg.?.bhdr.channel_number = peer_channel;
msg.?.bhdr.message_id = my_job_id;
try msg.?.body.appendSlice(my_data);
```

```zig title="HelloRequest (connecting)"
var addr: Address = .{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", 7099) };
try addr.format(msg.?);  // Sets opCode and adds address header
```

```zig title="WelcomeRequest (listening)"
var addr: Address = .{ .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", 7099) };
try addr.format(msg.?);  // Sets opCode and adds address header
```

### Submit for processing

```zig
const bhdr = try chnls.post(&msg);
// msg is now null (tofu took it)
// bhdr contains assigned channel_number and message_id
```

---

## Message Lifecycle

```
┌──────────────────────────────────────────────────────────────────┐
│                         YOUR CODE                                │
├──────────────────────────────────────────────────────────────────┤
│  1. msg = ampe.get(.always)     ← Get from pool                  │
│  2. Fill message (opCode, channel, body)                         │
│  3. bhdr = chnls.post(&msg)     ← Submit (msg becomes null)      │
│  4. resp = chnls.waitReceive()  ← Wait for result                │
│  5. ampe.put(&resp)             ← Return to pool                 │
└──────────────────────────────────────────────────────────────────┘
```

!!! warning "Memory rules"
    1. Always `defer ampe.put(&msg)` right after getting a message
    2. After `post()`, msg becomes null (tofu owns it)
    3. defer is still safe (put ignores null)
    4. Always return received messages to pool

---

## Quick Reference

### Check message type
```zig
switch (msg.?.bhdr.proto.opCode) {
    .HelloRequest => { /* new connection */ },
    .Request => { /* peer wants something */ },
    .Signal => { /* notification */ },
    // ...
}
```

### Check origin
```zig
if (msg.?.isFromEngine()) {
    // From tofu (status notification)
} else {
    // From peer (application message)
}
```

### Check if streaming
```zig
if (msg.?.hasMore()) {
    // More messages coming with same message_id
}
```

### Get helper methods
```zig
msg.?.bhdr.proto.getType()  // MessageType: .welcome, .hello, .regular, .bye
msg.?.bhdr.proto.getRole()  // MessageRole: .request, .response, .signal
```

