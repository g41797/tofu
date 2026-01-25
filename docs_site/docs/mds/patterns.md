

# Patterns

Common patterns for tofu applications.

---

## Request/Response

The basic pattern. Client sends Request, server sends Response.

```zig
// Client
var req: ?*Message = try ampe.get(.always);
defer ampe.put(&req);

req.?.bhdr.proto.opCode = .Request;
req.?.bhdr.channel_number = server_ch;
req.?.bhdr.message_id = job_id;
try req.?.body.append(request_data);

_ = try chnls.post(&req);

// Wait for response
var resp: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&resp);

if (resp.?.bhdr.message_id == job_id) {
    // This is our response
}
```

```zig
// Server
var msg: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&msg);

if (msg.?.bhdr.proto.opCode == .Request) {
    // Process request
    const result = process(msg.?.body.body().?);

    // Reuse message for response
    msg.?.bhdr.proto.opCode = .Response;
    msg.?.body.clear();
    try msg.?.body.append(result);

    _ = try chnls.post(&msg);
}
```

---

## Correlation

Use `message_id` to match responses to requests.

```zig
// Track pending requests
var pending = std.AutoHashMap(u64, RequestInfo).init(allocator);
defer pending.deinit();

// Send request
var req: ?*Message = try ampe.get(.always);
defer ampe.put(&req);

req.?.bhdr.proto.opCode = .Request;
req.?.bhdr.channel_number = server_ch;
req.?.bhdr.message_id = nextJobId();

try pending.put(req.?.bhdr.message_id, .{ .sent_at = now() });

_ = try chnls.post(&req);

// Later, match response
var resp: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&resp);

if (pending.get(resp.?.bhdr.message_id)) |info| {
    // Found the matching request
    _ = pending.remove(resp.?.bhdr.message_id);
    handleResponse(resp, info);
}
```

!!! tip "tofu assigns message_id if you don't"
    If you leave `message_id` at 0, tofu assigns a unique value during `post()`.
    The assigned value is in the returned BinaryHeader.

---

## Streaming (Client to Server)

Send multiple messages as one logical request. Use the `more` flag.

```zig
// Client: send file in chunks
const job_id = nextJobId();
var chunk_index: usize = 0;

while (chunk_index < chunks.len) {
    var msg: ?*Message = try ampe.get(.always);
    defer ampe.put(&msg);

    msg.?.bhdr.proto.opCode = .Request;
    msg.?.bhdr.channel_number = server_ch;
    msg.?.bhdr.message_id = job_id;  // Same for all chunks

    // Set more flag
    const is_last = (chunk_index == chunks.len - 1);
    msg.?.bhdr.proto.more = if (is_last) .last else .more;

    try msg.?.body.append(chunks[chunk_index]);
    _ = try chnls.post(&msg);

    chunk_index += 1;
}

// Wait for single response
var resp: ?*Message = try chnls.waitReceive(timeout);
defer ampe.put(&resp);
```

```zig
// Server: receive streamed request
var buffer = std.ArrayList(u8).init(allocator);
defer buffer.deinit();

while (true) {
    var msg: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&msg);

    if (msg.?.bhdr.proto.opCode == .Request) {
        try buffer.appendSlice(msg.?.body.body().?);

        if (!msg.?.hasMore()) {
            // Last chunk - process complete data
            const result = process(buffer.items);

            // Send response
            msg.?.bhdr.proto.opCode = .Response;
            msg.?.body.clear();
            try msg.?.body.append(result);
            _ = try chnls.post(&msg);
            break;
        }
    }
}
```

---

## Streaming (Server to Client)

Server sends multiple response messages for one request.

```zig
// Server: stream response
var msg: ?*Message = try chnls.waitReceive(timeout);
const client_ch = msg.?.bhdr.channel_number;
const job_id = msg.?.bhdr.message_id;
ampe.put(&msg);

// Send multiple response chunks
var chunk_index: usize = 0;
while (chunk_index < result_chunks.len) {
    var resp: ?*Message = try ampe.get(.always);
    defer ampe.put(&resp);

    resp.?.bhdr.proto.opCode = .Response;
    resp.?.bhdr.channel_number = client_ch;
    resp.?.bhdr.message_id = job_id;

    const is_last = (chunk_index == result_chunks.len - 1);
    resp.?.bhdr.proto.more = if (is_last) .last else .more;

    try resp.?.body.append(result_chunks[chunk_index]);
    _ = try chnls.post(&resp);

    chunk_index += 1;
}
```

```zig
// Client: receive streamed response
var buffer = std.ArrayList(u8).init(allocator);
defer buffer.deinit();

while (true) {
    var resp: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&resp);

    if (resp.?.bhdr.message_id == job_id) {
        try buffer.appendSlice(resp.?.body.body().?);

        if (!resp.?.hasMore()) {
            // Complete response received
            break;
        }
    }
}
```

---

## Progress Updates

Use Signal for one-way notifications during long operations.

```zig
// Server: send progress while processing
fn processWithProgress(chnls: ChannelGroup, ampe: Ampe, client_ch: u16, job_id: u64, data: []const u8) !void {
    const total_steps = 10;

    for (0..total_steps) |step| {
        // Do work
        doStep(step, data);

        // Send progress signal
        var sig: ?*Message = try ampe.get(.always);
        defer ampe.put(&sig);

        sig.?.bhdr.proto.opCode = .Signal;
        sig.?.bhdr.channel_number = client_ch;
        sig.?.bhdr.message_id = job_id;

        // Progress in body (your format)
        const progress = @as(u8, @intCast((step + 1) * 100 / total_steps));
        try sig.?.body.append(progress);

        _ = try chnls.post(&sig);
    }

    // Send final response
    var resp: ?*Message = try ampe.get(.always);
    defer ampe.put(&resp);

    resp.?.bhdr.proto.opCode = .Response;
    resp.?.bhdr.channel_number = client_ch;
    resp.?.bhdr.message_id = job_id;
    try resp.?.body.append("done");

    _ = try chnls.post(&resp);
}
```

```zig
// Client: receive progress and final response
while (true) {
    var msg: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&msg);

    if (msg.?.bhdr.message_id != job_id) continue;

    switch (msg.?.bhdr.proto.opCode) {
        .Signal => {
            const progress = msg.?.body.body().?[0];
            std.debug.print("Progress: {}%\n", .{progress});
        },
        .Response => {
            std.debug.print("Complete!\n", .{});
            break;
        },
        else => {},
    }
}
```

??? question "NAQ: Why Signal instead of Response for progress?"
    Response means "answer to your request". Signal means "notification".
    Progress is a notification, not an answer. The answer comes at the end.

---

## Bidirectional Communication

After connection, either peer can send Request/Response/Signal.

```zig
// Peer A sends request to Peer B
var reqToB: ?*Message = try ampe.get(.always);
reqToB.?.bhdr.proto.opCode = .Request;
reqToB.?.bhdr.channel_number = peerB_ch;
_ = try chnls.post(&reqToB);

// Peer B sends request to Peer A (at the same time)
var reqToA: ?*Message = try ampe.get(.always);
reqToA.?.bhdr.proto.opCode = .Request;
reqToA.?.bhdr.channel_number = peerA_ch;
_ = try chnls.post(&reqToA);

// Both receive each other's requests via waitReceive()
```

!!! note "Peer symmetry"
    After HelloRequest/HelloResponse, both sides are equal peers.
    Either can initiate requests. Your protocol decides who does what.

??? tip "Bidirectional streaming"
    You saw client streaming (multiple requests → one response) and server streaming (one request → multiple responses).

    Both peers are symmetric. Both can use the `more` flag. Both can stream simultaneously.

    Bidirectional streaming? Combine what you learned. Good exercise for you.

---

## Heartbeat

Keep connection alive with periodic signals.

```zig
// Sender thread
fn heartbeatLoop(chnls: ChannelGroup, ampe: Ampe, peer_ch: u16) void {
    while (running) {
        var hb: ?*Message = ampe.get(.always) catch continue;
        defer ampe.put(&hb);

        hb.?.bhdr.proto.opCode = .Signal;
        hb.?.bhdr.channel_number = peer_ch;
        // Empty body = heartbeat

        _ = chnls.post(&hb) catch break;

        std.Thread.sleep(30 * std.time.ns_per_s);
    }
}
```

```zig
// Receiver: detect missing heartbeat
var last_seen = std.time.timestamp();

while (true) {
    var msg: ?*Message = try chnls.waitReceive(10 * tofu.waitReceive_SEC_TIMEOUT);

    if (msg == null) {
        // Timeout
        if (std.time.timestamp() - last_seen > 60) {
            // No message for 60 seconds - peer dead?
            break;
        }
        continue;
    }

    defer ampe.put(&msg);
    last_seen = std.time.timestamp();

    // Process message...
}
```

---

## Multiple Clients

Server tracks each client by channel number.

```zig
const ClientInfo = struct {
    channel: u16,
    connected_at: i64,
    // ... your data ...
};

var clients = std.AutoHashMap(u16, ClientInfo).init(allocator);
defer clients.deinit();

while (true) {
    var msg: ?*Message = try chnls.waitReceive(timeout);
    defer ampe.put(&msg);

    const ch = msg.?.bhdr.channel_number;

    // Handle engine notifications
    if (msg.?.isFromEngine()) {
        const sts = tofu.status.raw_to_status(msg.?.bhdr.status);
        if (sts == .channel_closed) {
            _ = clients.remove(ch);
        }
        continue;
    }

    switch (msg.?.bhdr.proto.opCode) {
        .HelloRequest => {
            // New client
            try clients.put(ch, .{
                .channel = ch,
                .connected_at = std.time.timestamp(),
            });

            msg.?.bhdr.proto.opCode = .HelloResponse;
            _ = try chnls.post(&msg);
        },
        .Request => {
            if (clients.get(ch)) |client| {
                // Known client
                handleRequest(msg, client);
            }
        },
        else => {},
    }
}
```

---

## Transport-Agnostic Code

Write code that works with any transport (TCP, UDS) by accepting `*Address` as parameter.

```zig
// Same function works for TCP and UDS
pub fn startListener(ampe: Ampe, chnls: ChannelGroup, addr: *Address) !u16 {
    var msg: ?*Message = try ampe.get(.always);
    defer ampe.put(&msg);

    try addr.format(msg.?);  // Works with any address type

    const bhdr = try chnls.post(&msg);
    const listener_ch = bhdr.channel_number;

    var resp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&resp);

    if (resp.?.bhdr.status != 0) {
        return error.ListenerFailed;
    }

    return listener_ch;
}

// Usage
var tcp_addr: Address = .{ .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", 8080) };
var uds_addr: Address = .{ .uds_server_addr = address.UDSServerAddress.init("/tmp/myapp.sock") };

const tcp_ch = try startListener(ampe, chnls, &tcp_addr);
const uds_ch = try startListener(ampe, chnls, &uds_addr);
```

??? tip "NAQ: Why pointer to Address?"
    Address is a tagged union. Passing `*Address` lets the function work with any variant.
    The `format()` method checks which variant it is and sets the correct header.

---

## Summary

| Pattern | Messages Used | Use Case |
|---------|---------------|----------|
| Request/Response | Request → Response | Single question/answer |
| Streaming (client) | Request (more=1) ... Request (more=0) → Response | Upload file in chunks |
| Streaming (server) | Request → Response (more=1) ... Response (more=0) | Download file in chunks |
| Streaming (bidi) | Both use `more` flag simultaneously | Real-time data exchange |
| Progress | Request → Signal ... Signal → Response | Long operation with updates |
| Heartbeat | Signal (periodic) | Keep-alive |
| Bidirectional | Request ↔ Request | Both sides initiate |

