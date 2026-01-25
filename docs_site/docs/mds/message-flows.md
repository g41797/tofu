

# Message Flows

tofu is async. Understanding the message flow helps you write correct code.

---

## The Two Queues

tofu uses two internal queues:

```
Your Code                    tofu Engine                    Network
    │                            │                             │
    ├──post()──►  [Send Queue]  ─┼──► socket.write() ──────────►
    │                            │                             │
    ◄──waitReceive()── [Recv Queue] ◄── socket.read() ◄────────┤
    │                            │                             │
```

- **Send Queue:** Messages waiting to be sent
- **Recv Queue:** Messages received and waiting for you

---

## post() Is Not send()

`post()` puts a message in the send queue. It returns immediately.

```zig
const bhdr = try chnls.post(&msg);
// Message is in queue. Not sent yet.
// bhdr contains the assigned channel and message_id
```

!!! info "What post() returns"
    The BinaryHeader with assigned values:

    - `channel_number` - assigned channel (for HelloRequest/WelcomeRequest)
    - `message_id` - assigned ID (if you left it at 0)

The actual send happens on tofu's internal thread. You find out the result via `waitReceive()`.

---

## Async Completion

Every operation completes asynchronously via `waitReceive()`.

### WelcomeRequest flow

```
You                          tofu                         OS
 │                            │                            │
 ├─post(WelcomeRequest)──────►│                            │
 │  returns channel_number    │                            │
 │                            ├──create socket────────────►│
 │                            ├──bind()───────────────────►│
 │                            ├──listen()─────────────────►│
 │                            │◄──────────────────success──┤
 │◄──waitReceive()────────────┤                            │
 │  WelcomeResponse           │                            │
 │  status=0 (success)        │                            │
```

### HelloRequest flow

```
Client                       tofu                        Server
 │                            │                            │
 ├─post(HelloRequest)────────►│                            │
 │  returns channel_number    │                            │
 │                            ├──connect()────────────────►│
 │                            ├──send(HelloRequest)───────►│
 │                            │◄──────────HelloRequest─────┤
 │                            │                            ├─waitReceive()
 │                            │◄──────────HelloResponse────┤
 │◄──waitReceive()────────────┤                            │
 │  HelloResponse             │                            │
```

---

## Failure Paths

When something fails, you get the original message back with error status.

### Connection failure

```zig
var helloReq: ?*Message = try ampe.get(.always);
try addr.format(helloReq.?);
_ = try chnls.post(&helloReq);

var resp: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&resp);

if (resp.?.isFromEngine()) {
    // Connection failed - this is your HelloRequest returned
    const sts = tofu.status.raw_to_status(resp.?.bhdr.status);
    // sts could be: connect_failed, invalid_address, etc.
}
```

!!! warning "Check origin first"
    - `origin == application` → message from peer
    - `origin == engine` → status notification from tofu

### Send failure

If the network fails after connection, you get your message back:

```zig
_ = try chnls.post(&request);

var resp: ?*Message = try chnls.waitReceive(timeout);

if (resp.?.isFromEngine() and resp.?.bhdr.status != 0) {
    // This is your request, returned with error
    const sts = tofu.status.raw_to_status(resp.?.bhdr.status);
    // sts could be: send_failed, channel_closed, peer_disconnected
}
```

---

## Message Ownership

Messages move between you and tofu.

### After post()

```zig
var msg: ?*Message = try ampe.get(.always);
defer ampe.put(&msg);  // Safe - put() handles null

// ... fill message ...

_ = try chnls.post(&msg);
// msg is now null - tofu owns it
// defer will call put(null) which is a no-op
```

### After waitReceive()

```zig
var resp: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&resp);  // You must return it

// You own the message until you put() it
```

!!! note "defer handles both cases"
    Always use `defer ampe.put(&msg)` right after `get()`.
    It works whether you post (msg becomes null) or keep the message.

---

## Pool Empty Notification

When the pool runs low, tofu sends a signal:

```zig
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

if (msg.?.isFromEngine()) {
    const sts = tofu.status.raw_to_status(msg.?.bhdr.status);
    if (sts == .pool_empty) {
        // Pool needs more messages
        // The signal message itself goes back to pool via defer
    }
}
```

??? question "NAQ: What should I do when pool is empty?"
    Return messages to pool faster. The `pool_empty` signal message itself
    goes back to pool when you `put()` it, which helps immediately.

---

## Channel Closed Notification

When a channel closes (by you or peer), tofu notifies:

```zig
if (msg.?.isFromEngine()) {
    const sts = tofu.status.raw_to_status(msg.?.bhdr.status);
    if (sts == .channel_closed) {
        const closed_ch = msg.?.bhdr.channel_number;
        // Remove this channel from your tracking
    }
}
```

You get `channel_closed` for:

- ByeRequest/ByeResponse completion
- ByeSignal
- Peer disconnect
- Network failure

---

## Timeout Handling

`waitReceive()` can timeout:

```zig
var msg: ?*Message = try chnls.waitReceive(5 * tofu.waitReceive_SEC_TIMEOUT);

if (msg == null) {
    // Timeout - nothing received within 5 seconds
}
```

Constants:

- `waitReceive_INFINITE_TIMEOUT` - wait forever
- `waitReceive_SEC_TIMEOUT` - 1 second
- Multiply for longer timeouts

---

## Main Loop Pattern

A typical receive loop:

```zig
while (running) {
    var msg: ?*Message = try chnls.waitReceive(tofu.waitReceive_SEC_TIMEOUT);

    if (msg == null) {
        // Timeout - do housekeeping, check shutdown flag
        continue;
    }

    defer ampe.put(&msg);

    // Check origin first
    if (msg.?.isFromEngine()) {
        const sts = tofu.status.raw_to_status(msg.?.bhdr.status);
        switch (sts) {
            .pool_empty => continue,
            .channel_closed => {
                removeChannel(msg.?.bhdr.channel_number);
                continue;
            },
            else => {
                handleError(msg);
                continue;
            },
        }
    }

    // Application message from peer
    switch (msg.?.bhdr.proto.opCode) {
        .HelloRequest => handleNewConnection(msg, chnls),
        .Request => handleRequest(msg, chnls),
        .Signal => handleSignal(msg),
        .ByeRequest => handleClose(msg, chnls),
        else => {},
    }
}
```

---

## Summary

| What you do | What happens |
|-------------|--------------|
| `post(&msg)` | Message goes to send queue, msg becomes null |
| `waitReceive()` | Returns next message from recv queue (or null on timeout) |
| Success | You get the expected response from peer |
| Failure | You get your message back with error status, origin=engine |

