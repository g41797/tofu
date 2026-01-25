
# Thinking in Messages

Read this first. The rest of the docs assume you understand this.

---

## The Mental Shift

Traditional socket programming looks like this:

```
1. Create socket
2. Connect to server
3. Send data
4. Receive response
5. Close socket
```

**tofu thinking is different:**

```
1. Send HelloRequest (tofu connects for you)
2. Send Request (tofu sends for you)
3. Receive Response (tofu receives for you)
4. Send ByeRequest (tofu closes for you)
```

You don't manage sockets. You send messages. tofu does the socket work.

---

## Messages Are Actions

This is the core insight.

??? tip "NAQ: Why is this so important?"
    Because if you think "I need to connect, THEN send a message", you'll fight tofu.
    If you think "I send a message that means 'connect'", you'll work WITH tofu.
    Same result. Different mindset. The second one is easier.

**Traditional thinking (wrong for tofu):**
```
socket = connect(address);
send(socket, data);
```

**tofu thinking (correct):**
```zig
// HelloRequest means "connect to this address"
// You don't connect first. The message IS the connection request.
const bhdr = try chnls.post(&helloRequest);
```

The HelloRequest doesn't just carry data. It IS the action. tofu sees it and thinks: "User wants to connect. Let me handle that."

---

## Intent vs Implementation

tofu separates what you want from how it happens.

| You decide | tofu handles |
|------------|--------------|
| "I want to listen for connections" | Socket creation, binding, accepting |
| "I want to connect to server X" | Socket creation, DNS lookup, TCP handshake |
| "I want to send this data" | Serialization, write operations, retries |
| "I want to close this connection" | Graceful shutdown, socket cleanup |

You express **intent** through messages. tofu handles **implementation**.

---

## The Four Message Actions

Every tofu operation maps to a message:

| Intent | Message |
|--------|---------|
| Start listening | WelcomeRequest |
| Connect to peer | HelloRequest |
| Send data | Request / Response / Signal |
| Close connection | ByeRequest or ByeSignal |

!!! note "There's no `connect()` function"
    tofu doesn't have a connect function. You send a HelloRequest that contains
    the server address. tofu sees it, connects, and sends the message.
    One action, not two.

---

## The Basic Pattern

Almost everything follows this flow:

```zig
// 1. Get a message
var msg = try ampe.get(.always);
defer ampe.put(&msg);

// 2. Fill it in (set opCode, channel, data)
msg.?.bhdr.proto.opCode = .Request;
msg.?.bhdr.channel_number = peer_channel;
try msg.?.body.appendSlice(my_data);

// 3. Submit it
const bhdr = try chnls.post(&msg);

// 4. Wait for result
var response = try chnls.waitReceive(timeout);
defer ampe.put(&response);
```

Four APIs. That's all you need:

- `ampe.get()` — get a message to work with
- `ampe.put()` — return a message when done
- `chnls.post()` — submit a message for processing
- `chnls.waitReceive()` — receive incoming messages

---

## Peer Symmetry

Here's something that surprises people coming from traditional client/server.

**Before connection:**
```
Server: Waiting for clients (has WelcomeRequest)
Client: Wants to connect (sends HelloRequest)
```

**After connection:**
```
Peer A and Peer B
Both can send Request, Response, Signal
Both can initiate close
No more "client" or "server"
```

Once HelloRequest/HelloResponse completes, both sides are equal. Either can send any message type. Either can close the connection.

??? question "NAQ: But my server needs to send jobs to workers..."
    That's fine. Your protocol decides who sends what.
    tofu just gives you symmetric capabilities.

    The "server" can send Requests asking the "client" to do work.
    The "client" can send Signals with progress updates.
    Roles are your design choice, not a tofu constraint.

---

## Channels = Virtual Connections

A channel is tofu's abstraction for a connection.

**Two types:**

- **Listener channel** — like a server socket, accepts incoming connections
- **IO channel** — like a connected socket, sends and receives messages

**Channel numbers:**

- `0` = not assigned yet (you use this for HelloRequest, WelcomeRequest)
- `1-65534` = valid channels (assigned by tofu)
- `65535` = reserved (don't use)

!!! warning "Only tofu assigns channel numbers"
    You create messages with channel 0. tofu assigns a real number during `post()`.
    Save it. You need it for all future messages to this peer.

```zig
// You send HelloRequest with channel 0
msg.?.bhdr.channel_number = 0;  // Not assigned yet

// tofu assigns a channel and returns it
const bhdr = try chnls.post(&msg);
const my_channel = bhdr.channel_number;  // Now assigned (e.g., 7)

// Use this channel for all future messages to this peer
```

---

## Async by Default

!!! info "post() ≠ sent"
    `post()` means "submitted for processing". The actual send happens later on tofu's internal thread.

```zig
const bhdr = try chnls.post(&msg);
// Message is queued. Not sent yet.
// tofu will send it on its internal thread.
// Success or failure comes via waitReceive.
```

Everything happens asynchronously:

- You post a message
- tofu processes it (connect, send, whatever)
- Results come back via `waitReceive()`

This is why the pattern is always: **post → waitReceive**.

---

## Example: Server Setup

Here's how "start listening" works in tofu thinking:

```zig title="Server becomes available"
// Get message
var welcomeReq = try ampe.get(.always);
defer ampe.put(&welcomeReq);

// Set up WelcomeRequest with listen address
var addr: Address = .{ .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", 7099) };
try addr.format(welcomeReq.?);

// Submit it — tofu creates the listener
const bhdr = try chnls.post(&welcomeReq);
const listener_channel = bhdr.channel_number;

// Wait for confirmation
var welcomeResp = try chnls.waitReceive(timeout);
defer ampe.put(&welcomeResp);

// Now listening on listener_channel
```

You didn't call `bind()` or `listen()`. You sent a WelcomeRequest that means "please start listening". tofu did the rest.

---

## Example: Client Connection

Here's how "connect to server" works:

```zig title="Client connects"
// Get message
var helloReq = try ampe.get(.always);
defer ampe.put(&helloReq);

// Set up HelloRequest with server address
var addr: Address = .{ .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", 7099) };
try addr.format(helloReq.?);

// Submit it — tofu connects and sends
const bhdr = try chnls.post(&helloReq);
const server_channel = bhdr.channel_number;  // Save this!

// Wait for server response
var helloResp = try chnls.waitReceive(timeout);
defer ampe.put(&helloResp);

// Now connected. Use server_channel for all communication.
```

You didn't call `connect()`. You sent a HelloRequest that contains the server address. tofu connected and sent it.

---

## The Mindset Summary

| Old thinking | tofu thinking |
|--------------|---------------|
| Connect, then send | Send (it connects) |
| Manage sockets | Manage messages |
| Client vs Server | Peer vs Peer |
| Synchronous steps | Async post → waitReceive |
| Multiple APIs for different things | Four APIs for everything |

---

## What's Next

Now that you understand the mindset, you're ready to learn the details:

- **[Message](message.md)** — The structure of a tofu message
- **[Address](address.md)** — How to specify connection addresses
- **[ChannelGroup](channel-group.md)** — Managing multiple channels

The mental model: **Messages are actions. tofu does the network work.**

