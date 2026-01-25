

# Error Handling

tofu reports errors through messages. Check origin first, then status.

---

## The Origin-First Rule

Every received message: check origin before anything else.

```zig
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

if (msg.?.isFromEngine()) {
    // Status notification from tofu
    handleEngineMessage(msg);
} else {
    // Message from peer
    handlePeerMessage(msg);
}
```

!!! warning "Always check origin first"
    Engine messages look like regular messages but mean something different.
    A "Request" from engine is not a request - it's your failed request returned.

---

## Engine Messages

When `origin == engine`, the message is a notification from tofu.

| Status | Meaning | What to do |
|--------|---------|------------|
| `pool_empty` | Message pool is low | Return messages faster |
| `channel_closed` | Channel was closed | Remove from tracking |
| `connect_failed` | Connection failed | Retry or report error |
| `send_failed` | Send operation failed | Handle or retry |
| `recv_failed` | Receive operation failed | Handle failure |
| `peer_disconnected` | Peer closed connection | Clean up |
| `invalid_address` | Bad address format | Fix address |

```zig
fn handleEngineMessage(msg: *Message) void {
    const sts = tofu.status.raw_to_status(msg.bhdr.status);
    const ch = msg.bhdr.channel_number;

    switch (sts) {
        .pool_empty => {
            // Pool needs messages - this message itself helps
        },
        .channel_closed => {
            removeChannel(ch);
        },
        .connect_failed => {
            // Your HelloRequest failed
            handleConnectFailure(ch);
        },
        .send_failed, .recv_failed => {
            // Communication error on this channel
            handleChannelError(ch);
        },
        .peer_disconnected => {
            removeChannel(ch);
        },
        else => {
            // Log unexpected status
        },
    }
}
```

---

## Connection Errors

When HelloRequest fails, you get it back with error status.

```zig
var helloReq: ?*Message = try ampe.get(.always);
defer ampe.put(&helloReq);

try addr.format(helloReq.?);
const bhdr = try chnls.post(&helloReq);

var resp: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&resp);

if (resp.?.isFromEngine()) {
    const sts = tofu.status.raw_to_status(resp.?.bhdr.status);
    switch (sts) {
        .connect_failed => {
            // Server not reachable or refused connection
        },
        .invalid_address => {
            // Address format wrong
        },
        .uds_path_not_found => {
            // Unix socket file doesn't exist
        },
        else => {},
    }
    return error.ConnectionFailed;
}

// Success - resp is HelloResponse from server
```

??? question "NAQ: How do I retry a failed connection?"
    Send a new HelloRequest. tofu doesn't auto-retry.
    ```zig
    var attempts: u8 = 0;
    while (attempts < 5) {
        // ... send HelloRequest ...
        if (connected) break;
        attempts += 1;
        std.Thread.sleep(std.time.ns_per_s);
    }
    ```

---

## Listener Errors

WelcomeRequest can fail if address is in use or invalid.

```zig
var welcomeReq: ?*Message = try ampe.get(.always);
defer ampe.put(&welcomeReq);

try addr.format(welcomeReq.?);
_ = try chnls.post(&welcomeReq);

var resp: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&resp);

if (resp.?.bhdr.status != 0) {
    const sts = tofu.status.raw_to_status(resp.?.bhdr.status);
    switch (sts) {
        .address_in_use => {
            // Port already bound
        },
        .invalid_address => {
            // Bad IP or path
        },
        else => {},
    }
    return error.ListenerFailed;
}

// Listener ready
```

---

## Send Errors

If send fails after connection, you get your message back.

```zig
var req: ?*Message = try ampe.get(.always);
defer ampe.put(&req);

req.?.bhdr.proto.opCode = .Request;
req.?.bhdr.channel_number = server_ch;
try req.?.body.append(data);

_ = try chnls.post(&req);

var resp: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&resp);

if (resp.?.isFromEngine()) {
    if (resp.?.bhdr.channel_number == server_ch) {
        // Our request failed
        const sts = tofu.status.raw_to_status(resp.?.bhdr.status);
        switch (sts) {
            .send_failed => {
                // Network error during send
            },
            .channel_closed => {
                // Channel died
            },
            else => {},
        }
    }
}
```

---

## Channel Closed

You get `channel_closed` when:

- You sent ByeRequest and got ByeResponse
- You sent ByeSignal
- Peer sent ByeRequest/ByeSignal
- Network connection dropped

```zig
if (msg.?.isFromEngine()) {
    const sts = tofu.status.raw_to_status(msg.?.bhdr.status);
    if (sts == .channel_closed) {
        const ch = msg.?.bhdr.channel_number;

        // Remove from your tracking
        _ = clients.remove(ch);
        _ = pending_requests.remove(ch);

        // If this was an important connection, maybe reconnect
        if (ch == main_server_ch) {
            scheduleReconnect();
        }
    }
}
```

---

## Pool Empty

tofu sends `pool_empty` when the message pool is low.

```zig
if (sts == .pool_empty) {
    // The signal message itself goes back to pool via defer
    // This immediately helps

    // If you have cached messages, return them
    returnCachedMessages();

    // Don't allocate more unless necessary
}
```

!!! note "pool_empty is a warning, not an error"
    You can continue operating. Just return messages promptly.
    The signal message you received helps when you return it.

---

## Timeout Handling

`waitReceive()` returns null on timeout.

```zig
var msg: ?*Message = try chnls.waitReceive(5 * tofu.waitReceive_SEC_TIMEOUT);

if (msg == null) {
    // Nothing received in 5 seconds
    // This is not an error - just no messages

    // Good time for housekeeping
    checkPendingTimeouts();
    continue;
}
```

---

## Error Recovery Pattern

A robust receive loop:

```zig
while (running) {
    var msg: ?*Message = try chnls.waitReceive(tofu.waitReceive_SEC_TIMEOUT);

    if (msg == null) {
        // Timeout - housekeeping
        checkTimeouts();
        continue;
    }

    defer ampe.put(&msg);

    // Engine messages first
    if (msg.?.isFromEngine()) {
        const sts = tofu.status.raw_to_status(msg.?.bhdr.status);
        const ch = msg.?.bhdr.channel_number;

        switch (sts) {
            .pool_empty => {
                // Signal goes back to pool via defer
            },
            .channel_closed => {
                cleanupChannel(ch);
            },
            .connect_failed => {
                if (shouldRetry(ch)) {
                    scheduleReconnect(ch);
                } else {
                    reportError(ch, sts);
                }
            },
            .send_failed, .recv_failed => {
                // Message in body is the failed message
                handleFailedMessage(msg);
            },
            else => {
                logUnexpectedStatus(sts);
            },
        }
        continue;
    }

    // Application messages
    handlePeerMessage(msg);
}
```

---

## Converting Status to Error

Use `raw_to_error` when you need to propagate:

```zig
const sts = msg.?.bhdr.status;

if (sts != 0) {
    return tofu.status.raw_to_error(sts);
    // Returns AmpeError.ConnectFailed, AmpeError.SendFailed, etc.
}
```

---

## Summary

| Check | What it means |
|-------|---------------|
| `msg == null` | Timeout, no message |
| `msg.?.isFromEngine()` | Status notification from tofu |
| `msg.?.bhdr.status != 0` | Error or status code |
| `msg.?.isFromApplication()` | Regular message from peer |

| Common errors | Cause |
|---------------|-------|
| `connect_failed` | Server not reachable |
| `channel_closed` | Connection ended |
| `send_failed` | Network error |
| `pool_empty` | Return messages faster |
| `invalid_address` | Bad address format |

