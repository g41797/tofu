

??? question "Why “101”?"
    It’s 100% built by AI — and 1% by the project’s author.

Because tofu uses sockets under the hood, you still need to understand:

- the addressing scheme
- the correct order of creating sockets
- the difference between client and server sides
- socket tuning

## What is a Socket?

A socket is a software endpoint.
It lets two programs communicate.
This can be on the same computer or across a network.

### Stream-Oriented Sockets

These use a reliable, ordered, connection-based protocol.
TCP (Transmission Control Protocol) is the main example.
Data is sent as a continuous stream of bytes.
It guarantees all data arrives correctly.

## Socket Families (Protocols)

Sockets use different communication protocol families.

### 1. TCP/IP Sockets
For network communication.
Uses IP addresses to identify machines.
TCP/IP is the foundation of the internet.

### 2. Unix Domain Sockets (UDS)
For local communication only.
Works on the same computer.
No network hardware needed.
Often faster than TCP/IP for local processes.

## Socket Operations

Sockets follow this lifecycle.

### 1. Create
First step: create the socket.
This reserves system resources.
Gives you a handle (file descriptor) for later use.

### 2. Client: Connect
Client uses connect().
Links its socket to the server's address.
If successful, communication stream opens.

### 3. Server: Listen and Accept
Server waits for client connections.

- Bind: Attach socket to specific local address.
- Listen: Wait for incoming connection requests.
- Accept: When client connects, accept() returns.
    - Creates a **second**, **new socket**.
    - Original socket stays as listener.
    - New socket handles data with that client.

### 4. Disconnect (Close)
Communication ends when socket closes.

- Graceful close: Clean shutdown, data sent completely.
- Non-graceful close: Sudden close, data may be lost.

## Addresses - TCP/IP

TCP/IP addresses combine IP address + port number.

### Server Address (Bind)
Server binds to local IP address.
Uses fixed port number (22, 80, 443).

**Specific Adapter:** 192.168.1.10:80
- Only accepts connections to that IP.

**All Adapters (Wildcard):** 0.0.0.0:8080
- Listens on all network cards on port 8080.

### Client Address (Connect)
Client uses server's IP or hostname + port.
Client gets temporary ephemeral port automatically.

Example: Client connects to 192.168.1.10:80
Client local: 10.0.0.5:54321 (ephemeral port)

## Addresses - Unix Domain Sockets (UDS)

No IP addresses or ports.

Uses file system path instead.
Example: /tmp/service.sock

Server binds to path.
Client connects to same path.

## How Linux Tracks Sockets

### File Descriptor (FD) = Socket Handle
Every socket gets a small number (FD).
Like an ID for your program.
Example: socket_fd = 5

Use it to read/write/close: send(5, ...), close(5)

### FD is unique only inside one process
Process A: FD=3
Process B: FD=3 (different socket)
OS uses (PID + FD) to identify real socket.

## Socket tuning with options

### Reuse Port Quickly - SO_REUSEADDR option

When TCP connection closes, socket enters TIME_WAIT state.
Lasts 1-4 minutes.

During TIME_WAIT:
- System blocks new program from using same port.

Problems:
- Cannot restart server fast.
- Testing slow (start/stop many times).

SO_REUSEADDR fixes this.

tofu sets SO_REUSEADDR on all listening sockets.

Result: Every new tofu TCP server uses same port immediately.

### Socket closing modes - SO_LINGER option

Normal socket close:

- close() returns right away
- System sends remaining data in background (graceful close)

SO_LINGER changes this.

tofu uses only non-graceful (hard) close:

- close() returns immediately
- Connection closes instantly (reset)
- All unsent data discarded

To shut down gracefully, use these tofu features instead:

- ByeRequest from peer A to peer B
- ByeResponse from peer B back to peer A
- After that, peer B’s engine closes the socket immediately (not gracefully)
- Finally, both peers get a channel_closed status from their own engine.

