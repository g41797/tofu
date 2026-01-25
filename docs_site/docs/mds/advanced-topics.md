

# Advanced Topics

Details for production use.

---

## Channel Lifecycle

Channels go through states. You don't manage states directly, but understanding helps.

### Listener Channel

```
WelcomeRequest ──► [opening] ──► WelcomeResponse ──► [ready]
                                    │
                   status != 0 ─────┘ (failed)
```

After `ready`: accepts incoming connections, creates IO channels.

### IO Channel (Client Side)

```
HelloRequest ──► [connecting] ──► HelloResponse ──► [ready]
                                      │
                     status != 0 ─────┘ (failed)
```

### IO Channel (Server Side)

```
HelloRequest received ──► [ready]
```

Server's IO channel is ready immediately when HelloRequest arrives.

### Closing

```
ByeRequest ──► [closing] ──► ByeResponse ──► [closed]

ByeSignal ──► [closed] (immediate)
```

---

## Channel Number Reuse

tofu reuses channel numbers after channels close.

```
1. Channel 5 opened for Client A
2. Client A disconnects, channel 5 closed
3. Client B connects, gets channel 5 again
```

!!! warning "Don't cache channel numbers long-term"
    If you store channel numbers, update them on `channel_closed`.
    An old channel number might refer to a different connection later.

---

## Memory Management

### Message Pool

tofu pre-allocates messages in a pool. Configure pool size at startup:

```zig
const options: tofu.Options = .{
    .initialPoolMsgs = 32,   // Start with 32 messages
    .maxPoolMsgs = 128,      // Can grow to 128
};

var rtr: *Reactor = try Reactor.create(gpa, options);
```

### Allocation Strategy

`ampe.get()` takes a strategy:

```zig
// Only from pool - returns null if empty
var msg = try ampe.get(.poolOnly);

// Pool first, allocate if empty - never returns null
var msg = try ampe.get(.always);
```

Use `.poolOnly` when you can handle null (non-critical messages).
Use `.always` when you must have a message (critical operations).

### Returning Messages

Always return messages promptly:

```zig
// Good - defer immediately after get
var msg = try ampe.get(.always);
defer ampe.put(&msg);

// Good - return received messages
var resp = try chnls.waitReceive(timeout);
defer ampe.put(&resp);
```

!!! tip "defer handles post() correctly"
    After `post()`, msg becomes null. `put(null)` is a no-op.
    So `defer ampe.put(&msg)` is always safe.

### Adding Messages to Pool

If pool runs low, you can add messages:

```zig
fn addToPool(ampe: Ampe, count: usize) !void {
    const allocator = ampe.getAllocator();
    for (0..count) |_| {
        var msg: ?*Message = try Message.create(allocator);
        ampe.put(&msg);
    }
}
```

---

## Multiple ChannelGroups

You can create multiple ChannelGroups for different purposes:

```zig
const ampe: Ampe = try rtr.ampe();

// Separate groups for different subsystems
const clientChannels: ChannelGroup = try ampe.create();
const serverChannels: ChannelGroup = try ampe.create();
const adminChannels: ChannelGroup = try ampe.create();

defer tofu.DestroyChannels(ampe, clientChannels);
defer tofu.DestroyChannels(ampe, serverChannels);
defer tofu.DestroyChannels(ampe, adminChannels);
```

Each group has its own `waitReceive()`. Messages go to the group that owns the channel.

??? question "NAQ: When should I use multiple ChannelGroups?"
    When you have separate subsystems that should process messages independently.
    Example: main protocol on one group, admin/monitoring on another.

---

## Multi-Listener Server

One server can listen on multiple addresses (TCP + UDS):

```zig
// TCP listener
var tcpAddr: Address = .{
    .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", 8080)
};
var tcpReq: ?*Message = try ampe.get(.always);
defer ampe.put(&tcpReq);
try tcpAddr.format(tcpReq.?);
const tcpBhdr = try chnls.post(&tcpReq);

// UDS listener
var udsAddr: Address = .{
    .uds_server_addr = address.UDSServerAddress.init("/var/run/myapp.sock")
};
var udsReq: ?*Message = try ampe.get(.always);
defer ampe.put(&udsReq);
try udsAddr.format(udsReq.?);
const udsBhdr = try chnls.post(&udsReq);

// Wait for both confirmations
var resp1 = try chnls.waitReceive(timeout);
defer ampe.put(&resp1);
var resp2 = try chnls.waitReceive(timeout);
defer ampe.put(&resp2);

// Both listeners ready
// HelloRequests from either transport arrive via waitReceive()
```

---

## UpdateReceiver

Wake up a blocked `waitReceive()` from another thread:

```zig
// Thread A: blocked on waitReceive
var msg = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);

// Thread B: wake up Thread A
var signal: ?*Message = null;  // or a message with data
try chnls.updateReceiver(&signal);
```

Thread A receives a message with `status == .receiver_update`.

Use for:

- Shutdown signal
- New work available
- Configuration change

```zig
// Check for updateReceiver signal
if (msg.?.isFromEngine()) {
    const sts = tofu.status.raw_to_status(msg.?.bhdr.status);
    if (sts == .receiver_update) {
        if (shutdown_requested) {
            break;
        }
        // Handle other updates
    }
}
```

---

## Threading Model

tofu uses internal threads for I/O:

```
Your Thread(s)              tofu Threads
     │                           │
     ├──post()───────────►  IO Thread ──► socket
     │                           │
     ◄──waitReceive()─────  IO Thread ◄── socket
     │                           │
```

- `post()` and `waitReceive()` are thread-safe
- Multiple threads can call them on the same ChannelGroup
- Each ChannelGroup has its own receive queue

!!! note "Thread safety"
    You can call `post()` from any thread.
    Only one thread should call `waitReceive()` per ChannelGroup at a time.

---

## Performance Tips

### Pool Size

Set pool size based on expected concurrency:

```zig
const options: tofu.Options = .{
    .initialPoolMsgs = concurrent_requests * 2,
    .maxPoolMsgs = concurrent_requests * 4,
};
```

### Reuse Messages

Reuse received messages for responses:

```zig
// Instead of get() + put() + get()
var msg = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

// Reuse for response
msg.?.bhdr.proto.opCode = .Response;
msg.?.body.clear();
try msg.?.body.appendSlice(result);
_ = try chnls.post(&msg);
// defer handles the now-null msg
```

### Batch Operations

Process multiple messages per loop iteration:

```zig
while (true) {
    // Process all available messages
    while (true) {
        var msg = try chnls.waitReceive(0);  // No wait
        if (msg == null) break;
        defer ampe.put(&msg);
        handleMessage(msg);
    }

    // Then wait for more
    var msg = try chnls.waitReceive(tofu.waitReceive_SEC_TIMEOUT);
    if (msg == null) continue;
    defer ampe.put(&msg);
    handleMessage(msg);
}
```

---

## Debugging

### Message Dumps

BinaryHeader has a dump method:

```zig
msg.?.bhdr.dumpMeta("received: ");
// Prints channel, opCode, status, message_id
```

### Status Names

Convert status to readable name:

```zig
const sts = tofu.status.raw_to_status(msg.?.bhdr.status);
std.debug.print("Status: {}\n", .{sts});
```

### Common Issues

| Symptom | Likely cause |
|---------|--------------|
| `waitReceive` returns null | Timeout, no messages |
| Got my message back | Check origin and status |
| `channel_closed` unexpected | Peer disconnected or network failure |
| `pool_empty` frequent | Return messages faster, increase pool |
| Wrong channel in response | Channel reuse - track carefully |

---

## Cleanup

Proper shutdown:

```zig
// Stop accepting new work
running = false;

// Close all channels gracefully
for (active_channels.items) |ch| {
    var bye: ?*Message = try ampe.get(.always);
    bye.?.bhdr.proto.opCode = .ByeSignal;  // Fast close
    bye.?.bhdr.channel_number = ch;
    _ = try chnls.post(&bye);
}

// Drain remaining messages
while (true) {
    var msg = try chnls.waitReceive(tofu.waitReceive_SEC_TIMEOUT);
    if (msg == null) break;
    ampe.put(&msg);
}

// Destroy in reverse order
tofu.DestroyChannels(ampe, chnls);
rtr.destroy();
```

