

# Protocol Operations

tofu has 10 operations. Each operation is a specific message type.

---

## Terminology

| Term | What it is |
|------|------------|
| **OpCode** | The 4-bit identifier for an operation |
| **Message Type** | The domain: `welcome`, `hello`, `regular`, `bye` |
| **Message Role** | The pattern: `request`, `response`, `signal` |

An operation = type + role. Example: `HelloRequest` = hello type + request role.

---

## All Operations

```zig
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
};
```

---

## Setup Operations

These operations establish connections. They happen before regular data exchange.

### WelcomeRequest (OpCode 8)

Server sends this to start listening.

| Aspect | Value |
|--------|-------|
| Transferred? | No. Local only (app ↔ tofu). |
| Channel | Created with 0. tofu assigns a listener channel. |
| Direction | Server app → tofu |
| Response | WelcomeResponse |

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

var addr: Address = .{ .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", 7099) };
try addr.format(msg.?);

const bhdr = try chnls.post(&msg);
const listener_ch = bhdr.channel_number;  // Save this
```

??? question "NAQ: Why is WelcomeRequest not transferred?"
    It's a local setup command. You tell your local tofu "start listening".
    No network involved yet. The listener channel accepts future connections.

---

### WelcomeResponse (OpCode 9)

tofu sends this to confirm listener is ready.

| Aspect | Value |
|--------|-------|
| Transferred? | No. Local only. |
| Channel | Same listener channel from WelcomeRequest. |
| Direction | tofu → server app |
| Received via | `waitReceive()` |

```zig
var resp = try chnls.waitReceive(timeout);
defer ampe.put(&resp);

if (resp.?.bhdr.proto.opCode == .WelcomeResponse) {
    // Listener is ready
    if (resp.?.bhdr.status != 0) {
        // Failed to start listener
    }
}
```

---

### HelloRequest (OpCode 3)

Client sends this to connect to a server.

| Aspect | Value |
|--------|-------|
| Transferred? | Yes. Goes over network. |
| Channel | Client creates with 0. tofu assigns on both sides. |
| Direction | Client app → network → server app |
| Response | HelloResponse (or ByeSignal on reject) |

**Client side:**
```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

var addr: Address = .{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", 7099) };
try addr.format(msg.?);

const bhdr = try chnls.post(&msg);
const peer_ch = bhdr.channel_number;  // Save this for all future messages
```

**Server side (receives HelloRequest):**
```zig
var req = try chnls.waitReceive(timeout);
defer ampe.put(&req);

if (req.?.bhdr.proto.opCode == .HelloRequest) {
    const client_ch = req.?.bhdr.channel_number;  // Server's local channel for this client
    // Decide: accept or reject?
}
```

??? question "NAQ: Why do client and server have different channel numbers?"
    Each side has its own channel table. tofu maps between them automatically.
    Client's channel 7 might be server's channel 12. You don't need to care.

---

### HelloResponse (OpCode 4)

Server sends this to accept a connection.

| Aspect | Value |
|--------|-------|
| Transferred? | Yes. Goes over network. |
| Channel | Server uses its local channel for this client. |
| Direction | Server app → network → client app |
| Effect | Connection established. Both sides are now peers. |

!!! note "After HelloResponse"
    Both sides become equal peers. Either can send Request, Response, or Signal.
    The original client/server distinction is gone.

**Server sends:**
```zig
var resp = try ampe.get(.always);
defer ampe.put(&resp);

resp.?.bhdr.proto.opCode = .HelloResponse;
resp.?.bhdr.channel_number = client_ch;  // From HelloRequest
_ = try chnls.post(&resp);
```

**Client receives:**
```zig
var resp = try chnls.waitReceive(timeout);
defer ampe.put(&resp);

if (resp.?.bhdr.proto.opCode == .HelloResponse) {
    // Connected. Use peer_ch for all communication.
}
```

---

## Data Operations

After connection, peers exchange data using these operations.

### Request (OpCode 0)

Ask the peer for something. Expects a Response.

| Aspect | Value |
|--------|-------|
| Transferred? | Yes |
| Channel | Existing peer channel |
| Direction | Either peer → other peer |
| Response | Usually Response (app decides) |
| Streaming | Supports `more` flag for multi-message requests |

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

msg.?.bhdr.proto.opCode = .Request;
msg.?.bhdr.channel_number = peer_ch;
msg.?.bhdr.message_id = job_id;
try msg.?.body.appendSlice(request_data);

_ = try chnls.post(&msg);
```

---

### Response (OpCode 1)

Answer to a Request.

| Aspect | Value |
|--------|-------|
| Transferred? | Yes |
| Channel | Existing peer channel |
| Direction | Either peer → other peer |
| Correlation | Use same `message_id` as Request |
| Streaming | Supports `more` flag for multi-message responses |

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

msg.?.bhdr.proto.opCode = .Response;
msg.?.bhdr.channel_number = requester_ch;
msg.?.bhdr.message_id = request.?.bhdr.message_id;  // Same ID
try msg.?.body.appendSlice(response_data);

_ = try chnls.post(&msg);
```

---

### Signal (OpCode 2)

One-way notification. No response expected.

| Aspect | Value |
|--------|-------|
| Transferred? | Yes |
| Channel | Existing peer channel |
| Direction | Either peer → other peer |
| Response | None expected |
| Use cases | Progress updates, events, notifications |

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

msg.?.bhdr.proto.opCode = .Signal;
msg.?.bhdr.channel_number = peer_ch;
msg.?.bhdr.message_id = job_id;  // To correlate with a job
try msg.?.body.appendSlice(progress_data);

_ = try chnls.post(&msg);
```

??? question "NAQ: When should I use Signal vs Request?"
    Use Signal when you don't need a response. Progress updates, heartbeats, events.
    Use Request when you expect the peer to send something back.

---

## Close Operations

These operations end connections.

### ByeRequest (OpCode 5)

Start a graceful close. Waits for pending messages to send.

| Aspect | Value |
|--------|-------|
| Transferred? | Yes |
| Channel | Channel to close |
| Direction | Either peer → other peer |
| Response | ByeResponse |
| Behavior | Queued after pending messages |

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

msg.?.bhdr.proto.opCode = .ByeRequest;
msg.?.bhdr.channel_number = peer_ch;

_ = try chnls.post(&msg);
// Wait for ByeResponse
```

---

### ByeResponse (OpCode 6)

Acknowledge graceful close.

| Aspect | Value |
|--------|-------|
| Transferred? | Yes |
| Channel | Same channel as ByeRequest |
| Direction | Responder → initiator |
| Effect | Channel closed on both sides |

```zig
// Received ByeRequest
var resp = try ampe.get(.always);
defer ampe.put(&resp);

resp.?.bhdr.proto.opCode = .ByeResponse;
resp.?.bhdr.channel_number = requester_ch;

_ = try chnls.post(&resp);
// Channel closes after send
```

---

### ByeSignal (OpCode 7)

!!! warning "Abruptive close"
    ByeSignal discards pending messages and closes the socket immediately.
    Use only when you need to abort, not for normal shutdown.

Close immediately. No response. Discards pending messages.

| Aspect | Value |
|--------|-------|
| Transferred? | No. Local only. |
| Channel | Channel to abort |
| Direction | App → local tofu |
| Response | None (channel_closed from engine) |
| Behavior | Inserted at head of queue. Aborts socket. |

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

msg.?.bhdr.proto.opCode = .ByeSignal;
msg.?.bhdr.channel_number = peer_ch;

_ = try chnls.post(&msg);
// Channel closes immediately
// Receive channel_closed from engine
```

??? question "NAQ: When should I use ByeSignal vs ByeRequest?"
    ByeRequest: Graceful. Finishes pending work. Use for normal shutdown.
    ByeSignal: Immediate. Discards pending messages. Use for errors, timeouts, rejection.

---

## Quick Reference

| OpCode | Name | Transferred | Direction | Purpose |
|--------|------|-------------|-----------|---------|
| 8 | WelcomeRequest | No | App → tofu | Start listener |
| 9 | WelcomeResponse | No | tofu → App | Confirm listener |
| 3 | HelloRequest | Yes | Client → Server | Connect |
| 4 | HelloResponse | Yes | Server → Client | Accept connection |
| 0 | Request | Yes | Peer ↔ Peer | Ask for something |
| 1 | Response | Yes | Peer ↔ Peer | Answer request |
| 2 | Signal | Yes | Peer ↔ Peer | One-way notification |
| 5 | ByeRequest | Yes | Peer ↔ Peer | Graceful close |
| 6 | ByeResponse | Yes | Peer ↔ Peer | Acknowledge close |
| 7 | ByeSignal | No | App → tofu | Immediate close |

