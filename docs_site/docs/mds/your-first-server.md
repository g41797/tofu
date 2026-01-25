

# Your First Server

A server does three things:

1. Start a listener (WelcomeRequest)
2. Accept connections (receive HelloRequest, send HelloResponse)
3. Exchange messages with clients

---

## Step 1: Create the Engine

Before anything, create the tofu engine and get interfaces.

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

    // Create the engine
    var rtr: *Reactor = try Reactor.create(allocator, tofu.DefaultOptions);
    defer rtr.destroy();

    // Get the ampe interface (message pool + channel factory)
    const ampe: Ampe = try rtr.ampe();

    // Create a channel group (handles multiple channels)
    const chnls: ChannelGroup = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    // Now ready to use tofu
}
```

---

## Step 2: Start the Listener

Send a WelcomeRequest to start listening.

```zig
// Get a message from pool
var welcomeReq: ?*Message = try ampe.get(.always);
defer ampe.put(&welcomeReq);

// Set up the listen address
var addr: Address = .{
    .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", 7099)
};
try addr.format(welcomeReq.?);

// Submit - tofu creates the listener socket
const bhdr = try chnls.post(&welcomeReq);
const listener_ch = bhdr.channel_number;

// Wait for confirmation
var welcomeResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
defer ampe.put(&welcomeResp);

// Check status
if (welcomeResp.?.bhdr.status != 0) {
    // Failed to start listener
    return error.ListenerFailed;
}

// Listener is ready on listener_ch
```

!!! warning "Save the listener channel"
    You need `listener_ch` to identify messages related to the listener.
    New client connections arrive on different channels.

---

## Step 3: Accept Connections

Wait for HelloRequest from clients, send HelloResponse to accept.

```zig
while (true) {
    var msg: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&msg);

    // Check origin first
    if (msg.?.isFromEngine()) {
        // Status notification from tofu
        continue;
    }

    switch (msg.?.bhdr.proto.opCode) {
        .HelloRequest => {
            // New client connected
            const client_ch = msg.?.bhdr.channel_number;

            // Accept by sending HelloResponse
            msg.?.bhdr.proto.opCode = .HelloResponse;
            _ = try chnls.post(&msg);

            // Now client_ch is ready for data exchange
        },
        .Request => {
            // Client sent a request - handle it
            const ch = msg.?.bhdr.channel_number;
            // ... process request ...
        },
        .ByeRequest => {
            // Client wants to close
            msg.?.bhdr.proto.opCode = .ByeResponse;
            _ = try chnls.post(&msg);
        },
        else => {},
    }
}
```

??? question "NAQ: How do I reject a connection?"
    Send ByeSignal instead of HelloResponse:
    ```zig
    msg.?.bhdr.proto.opCode = .ByeSignal;
    _ = try chnls.post(&msg);
    ```
    This closes the channel immediately.

---

## Step 4: Handle Requests

Process incoming requests and send responses.

```zig
.Request => {
    const client_ch = msg.?.bhdr.channel_number;
    const job_id = msg.?.bhdr.message_id;

    // Read request body
    const request_data = msg.?.body.body().?;

    // Process (your logic here)
    const result = processRequest(request_data);

    // Reuse message for response
    msg.?.bhdr.proto.opCode = .Response;
    // channel_number and message_id stay the same
    msg.?.body.clear();
    try msg.?.body.append(result);

    _ = try chnls.post(&msg);
},
```

!!! tip "Reuse messages"
    You can reuse the received message for the response.
    Just change the opCode and body. Channel and message_id stay the same.

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

pub fn runServer(gpa: std.mem.Allocator, port: u16) !void {
    // Create engine
    var rtr: *Reactor = try Reactor.create(gpa, tofu.DefaultOptions);
    defer rtr.destroy();

    const ampe: Ampe = try rtr.ampe();
    const chnls: ChannelGroup = try ampe.create();
    defer tofu.DestroyChannels(ampe, chnls);

    // Start listener
    var welcomeReq: ?*Message = try ampe.get(.always);
    defer ampe.put(&welcomeReq);

    var addr: Address = .{
        .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", port)
    };
    try addr.format(welcomeReq.?);

    _ = try chnls.post(&welcomeReq);

    var welcomeResp: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
    defer ampe.put(&welcomeResp);

    if (welcomeResp.?.bhdr.status != 0) {
        return error.ListenerFailed;
    }

    std.debug.print("Server listening on port {d}\n", .{port});

    // Main loop
    while (true) {
        var msg: ?*Message = try chnls.waitReceive(tofu.waitReceive_INFINITE_TIMEOUT);
        defer ampe.put(&msg);

        if (msg.?.isFromEngine()) {
            continue;
        }

        switch (msg.?.bhdr.proto.opCode) {
            .HelloRequest => {
                // Accept connection
                msg.?.bhdr.proto.opCode = .HelloResponse;
                _ = try chnls.post(&msg);
            },
            .Request => {
                // Echo back
                msg.?.bhdr.proto.opCode = .Response;
                _ = try chnls.post(&msg);
            },
            .ByeRequest => {
                msg.?.bhdr.proto.opCode = .ByeResponse;
                _ = try chnls.post(&msg);
            },
            else => {},
        }
    }
}
```

---

## Key Points

| Step | Message | What happens |
|------|---------|--------------|
| Start listener | WelcomeRequest → WelcomeResponse | tofu creates socket, binds, listens |
| Accept client | HelloRequest → HelloResponse | New channel for this client |
| Handle request | Request → Response | Your application logic |
| Close | ByeRequest → ByeResponse | Graceful channel close |

---

## Next

See [Your First Client](your-first-client.md) for the client side.

