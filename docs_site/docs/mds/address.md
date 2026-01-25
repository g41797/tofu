

# Address

tofu supports two transport types: TCP and Unix Domain Sockets (UDS).

Addresses tell tofu where to connect or listen.

---

## Address Types

| Type | Use Case | Format |
|------|----------|--------|
| TCP Client | Connect to a server | IP address + port |
| TCP Server | Listen for connections | IP address + port |
| UDS Client | Connect via Unix socket | File path |
| UDS Server | Listen via Unix socket | File path |

---

## TCP Addresses

### TCPClientAddress

For connecting to a TCP server.

```zig title="Connect to localhost:7099"
var addr: Address = .{
    .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", 7099)
};
try addr.format(msg.?);  // Adds ~connect_to header, sets HelloRequest
```

### TCPServerAddress

For listening on a TCP port.

```zig title="Listen on all interfaces, port 7099"
var addr: Address = .{
    .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", 7099)
};
try addr.format(msg.?);  // Adds ~listen_on header, sets WelcomeRequest
```

**Common IP values:**

| Address | Meaning |
|---------|---------|
| `0.0.0.0` | All IPv4 interfaces (listen on all) |
| `127.0.0.1` | Localhost only (loopback) |
| `192.168.x.x` | Specific network interface |

---

## UDS Addresses

Unix Domain Sockets use file paths instead of IP:port.

??? question "NAQ: When should I use UDS vs TCP?"
    Use UDS when both sides run on the same machine. No network overhead.
    Use TCP when sides run on different machines, or when you need standard ports.

### UDSClientAddress

```zig title="Connect via Unix socket"
var addr: Address = .{
    .uds_client_addr = address.UDSClientAddress.init("/tmp/my-app.sock")
};
try addr.format(msg.?);
```

### UDSServerAddress

```zig title="Listen via Unix socket"
var addr: Address = .{
    .uds_server_addr = address.UDSServerAddress.init("/tmp/my-app.sock")
};
try addr.format(msg.?);
```

!!! warning "UDS paths"
    The socket file is created when the server starts listening.
    If the file already exists, `listen` may fail.
    Clean up old socket files before starting.

---

## Wire Format

Address headers use pipe-separated format:

```
~connect_to: "tcp|127.0.0.1|7099"
~connect_to: "uds|/tmp/socket.sock"
~listen_on: "tcp|0.0.0.0|7099"
~listen_on: "uds|/tmp/socket.sock"
```

!!! tip "Use helpers, not strings"
    Always use the address helpers (`TCPClientAddress`, etc.) instead of building
    header strings manually. The helpers handle formatting correctly.

---

## Complete Examples

### TCP Client connecting to server

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

var addr: Address = .{
    .tcp_client_addr = address.TCPClientAddress.init("192.168.1.100", 8080)
};
try addr.format(msg.?);

const bhdr = try chnls.post(&msg);
const server_channel = bhdr.channel_number;
```

### TCP Server starting listener

```zig
var msg = try ampe.get(.always);
defer ampe.put(&msg);

var addr: Address = .{
    .tcp_server_addr = address.TCPServerAddress.init("0.0.0.0", 8080)
};
try addr.format(msg.?);

const bhdr = try chnls.post(&msg);
const listener_channel = bhdr.channel_number;

// Wait for confirmation
var resp = try chnls.waitReceive(timeout);
defer ampe.put(&resp);
// resp.bhdr.proto.opCode == .WelcomeResponse
```

### UDS for same-machine communication

```zig
// Server
var srvAddr: Address = .{
    .uds_server_addr = address.UDSServerAddress.init("/var/run/myapp.sock")
};

// Client (same machine)
var cltAddr: Address = .{
    .uds_client_addr = address.UDSClientAddress.init("/var/run/myapp.sock")
};
```

---

## Testing Helpers

tofu provides helpers for testing without port conflicts.

### Find free TCP port

```zig
const port = try tofu.FindFreeTcpPort();
// Returns an available port number
```

### Temporary UDS path

```zig
var tup: tofu.TempUdsPath = .{};
const path = try tup.buildPath(allocator);
// Returns a unique temporary socket path
```

!!! tip "Avoid port conflicts"
    Use these helpers in tests. They prevent "address already in use" errors.

---

## Quick Reference

| What you want | Address type | Header created |
|---------------|--------------|----------------|
| Connect to TCP server | `TCPClientAddress` | `~connect_to: tcp\|...\|...` |
| Listen on TCP port | `TCPServerAddress` | `~listen_on: tcp\|...\|...` |
| Connect via UDS | `UDSClientAddress` | `~connect_to: uds\|...` |
| Listen via UDS | `UDSServerAddress` | `~listen_on: uds\|...` |

