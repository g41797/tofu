

# Your First Client

A client does three things:

1. Connect to server (HelloRequest)
2. Exchange messages
3. Close connection (ByeRequest)

---

## Step 1: Create the Engine

Same as server - create engine and interfaces.

```zig
const std = @import("std");
const tofu = @import("tofu");

const Reactor = tofu.Reactor;
const Ampe = tofu.Ampe;
const ChannelGroup = tofu.ChannelGroup;
const Message = tofu.Message;
const Address = tofu.address.Address;
const address = tofu.address;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rtr: *Reactor = try Reactor.create(allocator, tofu.DefaultOptions);
    defer rtr.destroy();

    const ampe: Ampe = try rtr.ampe();
    const chnls: ChannelGroup = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);
}
```

---

## Step 2: Connect to Server

Send HelloRequest. tofu connects and sends it. Wait for HelloResponse.

```zig
// Get message
var helloReq: ?*Message = try ampe.get(.always);
defer ampe.put(&helloReq);

// Set up server address
var addr: Address = .{
    .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", 7099)
};
try addr.format(helloReq.?);

// Submit - tofu connects and sends
const bhdr = try chnls.post(&helloReq);
const server_ch = bhdr.channel_number;  // Save this!

// Wait for response
var helloResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
defer ampe.put(&helloResp);

// Check what we got
if (helloResp.?.isFromEngine()) {
    // Connection failed
    const sts = tofu.status.raw_to_status(helloResp.?.bhdr.status);
    std.debug.print("Connect failed: {}\n", .{sts});
    return error.ConnectFailed;
}

if (helloResp.?.bhdr.proto.opCode == .HelloResponse) {
    // Connected! server_ch is ready for use
}
```

!!! warning "Save the server channel"
    `server_ch` returned from `post()` is your handle to the server.
    Use it for all future messages to this server.

---

## Step 3: Send Requests

After connection, send requests and receive responses.

```zig
// Get message
var req: ?*Message = try ampe.get(.always);
defer ampe.put(&req);

// Set up request
req.?.bhdr.proto.opCode = .Request;
req.?.bhdr.channel_number = server_ch;  // The channel from step 2
req.?.bhdr.message_id = 1;  // Your job ID

// Add data
try req.?.body.append("Hello, server!");

// Send
_ = try chnls.post(&req);

// Wait for response
var resp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
defer ampe.put(&resp);

// Check response
if (resp.?.bhdr.proto.opCode == .Response) {
    if (resp.?.bhdr.message_id == 1) {
        // This is the response to our request
        const data = resp.?.body.body().?;
        // ... process response ...
    }
}
```

??? question "NAQ: What if the response takes too long?"
    Use a timeout instead of infinite wait:
    ```zig
    var resp = try chnls.waitReceive(5 * tofu.waitReceive_SEC_TIMEOUT);
    if (resp == null) {
        // Timeout - no response within 5 seconds
    }
    ```

---

## Step 4: Close Connection

Graceful close with ByeRequest/ByeResponse.

```zig
// Get message
var bye: ?*Message = try ampe.get(.always);
defer ampe.put(&bye);

// Set up ByeRequest
bye.?.bhdr.proto.opCode = .ByeRequest;
bye.?.bhdr.channel_number = server_ch;

// Send
_ = try chnls.post(&bye);

// Wait for ByeResponse
var byeResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
defer ampe.put(&byeResp);

// Channel is now closed
```

---

## Handling Connection Failures

Connections can fail. Check the status.

```zig
var resp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
defer ampe.put(&resp);

if (resp.?.isFromEngine()) {
    const sts = tofu.status.raw_to_status(resp.?.bhdr.status);
    switch (sts) {
        .connect_failed => {
            // Server not reachable
        },
        .channel_closed => {
            // Server closed the connection
        },
        .send_failed => {
            // Message could not be sent
        },
        else => {},
    }
}
```

!!! note "Reconnection is manual"
    tofu does not auto-reconnect. If connection fails, send a new HelloRequest.

---

## Complete Example

```zig
const std = @import("std");
const tofu = @import("tofu");

const Reactor = tofu.Reactor;
const Ampe = tofu.Ampe;
const ChannelGroup = tofu.ChannelGroup;
const Message = tofu.Message;
const Address = tofu.address.Address;
const address = tofu.address;
const status = tofu.status;

pub fn runClient(gpa: std.mem.Allocator, host: []const u8, port: u16) !void {
    // Create engine
    var rtr: *Reactor = try Reactor.create(gpa, tofu.DefaultOptions);
    defer rtr.destroy();

    const ampe: Ampe = try rtr.ampe();
    const chnls: ChannelGroup = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    // Connect
    var helloReq: ?*Message = try ampe.get(.always);
    defer ampe.put(&helloReq);

    var addr: Address = .{
        .tcp_client_addr = address.TCPClientAddress.init(host, port)
    };
    try addr.format(helloReq.?);

    const bhdr = try chnls.post(&helloReq);
    const server_ch = bhdr.channel_number;

    var helloResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&helloResp);

    if (helloResp.?.isFromEngine()) {
        return error.ConnectFailed;
    }

    std.debug.print("Connected to server\n", .{});

    // Send request
    var req: ?*Message = try ampe.get(.always);
    defer ampe.put(&req);

    req.?.bhdr.proto.opCode = .Request;
    req.?.bhdr.channel_number = server_ch;
    try req.?.body.append("ping");

    _ = try chnls.post(&req);

    // Receive response
    var resp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&resp);

    std.debug.print("Got response: {s}\n", .{resp.?.body.body().?});

    // Close
    var bye: ?*Message = try ampe.get(.always);
    defer ampe.put(&bye);

    bye.?.bhdr.proto.opCode = .ByeRequest;
    bye.?.bhdr.channel_number = server_ch;

    _ = try chnls.post(&bye);

    var byeResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&byeResp);

    std.debug.print("Disconnected\n", .{});
}
```

---

## Key Points

| Step | Message | What happens |
|------|---------|--------------|
| Connect | HelloRequest → HelloResponse | tofu creates socket, connects, sends |
| Send data | Request → Response | Your application logic |
| Close | ByeRequest → ByeResponse | Graceful channel close |

---

## Common Patterns

### Retry on failure

```zig
var connected = false;
var attempts: u8 = 0;

while (!connected and attempts < 5) {
    var helloReq: ?*Message = try ampe.get(.always);
    defer ampe.put(&helloReq);

    try addr.format(helloReq.?);
    const bhdr = try chnls.post(&helloReq);

    var resp: ?*Message = try chnls.waitReceive(3 * tofu.waitReceive_SEC_TIMEOUT);
    defer ampe.put(&resp);

    if (resp != null and resp.?.bhdr.proto.opCode == .HelloResponse) {
        connected = true;
        server_ch = bhdr.channel_number;
    } else {
        attempts += 1;
        std.Thread.sleep(std.time.ns_per_s);
    }
}
```

---

## Next

See [Message Flows](message-flows.md) for async completion details.

