

# Test Helpers

tofu provides helpers for writing tests.

---

## Free TCP Port

Find an available TCP port to avoid "address already in use" errors.

```zig
const port = try tofu.FindFreeTcpPort();

var addr: Address = .{
    .tcp_server_addr = address.TCPServerAddress.init("127.0.0.1", port)
};
```

Each call returns a different port.

---

## Temporary UDS Path

Generate a unique Unix socket path for testing.

```zig
var tup: tofu.TempUdsPath = .{};
const path = try tup.buildPath(allocator);

var addr: Address = .{
    .uds_server_addr = address.UDSServerAddress.init(path)
};
```

The path is in a temp directory and won't conflict with other tests.

---

## Why Use These

| Problem | Helper |
|---------|--------|
| Port already in use | `FindFreeTcpPort()` |
| Socket file exists | `TempUdsPath.buildPath()` |
| Tests run in parallel | Both helpers return unique values |

!!! tip "Use in all tests"
    Hard-coded ports and paths cause flaky tests.
    Always use these helpers.

---

## Example: Test Setup

```zig
const std = @import("std");
const tofu = @import("tofu");
const address = tofu.address;
const Address = address.Address;

test "client-server communication" {
    const allocator = std.testing.allocator;

    // Get unique port
    const port = try tofu.FindFreeTcpPort();

    // Server address
    var srvAddr: Address = .{
        .tcp_server_addr = address.TCPServerAddress.init("127.0.0.1", port)
    };

    // Client address (same port)
    var cltAddr: Address = .{
        .tcp_client_addr = address.TCPClientAddress.init("127.0.0.1", port)
    };

    // ... test code ...
}

test "uds communication" {
    const allocator = std.testing.allocator;

    // Get unique socket path
    var tup: tofu.TempUdsPath = .{};
    const path = try tup.buildPath(allocator);

    var srvAddr: Address = .{
        .uds_server_addr = address.UDSServerAddress.init(path)
    };

    var cltAddr: Address = .{
        .uds_client_addr = address.UDSClientAddress.init(path)
    };

    // ... test code ...
}
```

