# Plan: New sockets_tests.zig — Skt and SocketCreator coverage

## Context

`linux/Skt.zig` and `linux/SocketCreator.zig` currently use `std.posix` internally.
They will be rewritten for Zig 0.16+ (posix removal). These tests establish the contract:
what `Skt` and `SocketCreator` must do regardless of internal implementation.

Tests use only the public `tofu.*` API — zero `std.posix` in test code. That way the
same test file runs unchanged after posix is removed from the implementation.

Non-blocking sockets are handled via bounded retry loops (no poller needed in tests).

---

## Files Changed

| File | Action |
| :--- | :----- |
| `tests/ampe/sockets_tests.zig` | Full replacement |
| `tests/tofu_tests.zig` | Add `_ = @import("ampe/sockets_tests.zig");` guarded by `if (builtin.os.tag == .linux)` |
| `src/ampe/linux/Skt.zig`, `mac/`, `windows/`, `usockets/` | Added `isSet()` method |

---

## Tests

### Group 1 — SocketCreator (no connection, single thread)

| Test | What it checks |
| :--- | :------------- |
| `wrong address returns InvalidAddress` | `fromAddress(.wrong)` → `AmpeError.InvalidAddress` |
| `parse empty message returns InvalidAddress` | fresh `Message` → parse → `.wrong` → `InvalidAddress` |
| `TCP server socket is set and server-flagged` | `fromAddress(tcp_server)` → `isSet()`, `server == true` |
| `UDS server socket is set and server-flagged` | `fromAddress(uds_server)` → `isSet()`, `server == true` |
| `TCP client socket is created` | server first, then `fromAddress(tcp_client)` → `isSet()`, `server == false` |
| `UDS client to nonexistent path fails` | bogus path → `InvalidAddress` |
| `findFreeTcpPort returns bindable port` | `FindFreeTcpPort()` → create TCP server → succeeds |
| `createUdsListener with empty path auto-creates` | `SocketCreator.createUdsListener(gpa, "")` → `isSet()` |

### Group 2 — Skt state (single thread)

| Test | What it checks |
| :--- | :------------- |
| `zero-initialized Skt deinit is safe` | `var skt: Skt = .{}; skt.deinit()` → no crash |
| `accept on listener before client returns null` | TCP listener, immediate `accept()` → `null` |
| `connect returns false initially` | TCP server + client socket, first `connect()` → `false` |

### Group 3 — TCP integration

| Test | Threads | What it checks |
| :--- | :------ | :------------- |
| `TCP connect and accept` | 1 (poll loop) | interleaved `connect()`/`accept()` retries; both sides set |
| `TCP sendBuf recvToBuf round-trip` | 2 | 1000-byte payload sent and received intact |
| `recvToBuf returns null when no data` | 2 | immediately after accept, before send → `null` |

`TCP connect and accept` uses a single-threaded poll loop — non-blocking `connect()` and `accept()` are retried in the same loop. This avoids threading races inherent in retrying `connect()` across threads (RST from server can interrupt the client's retry before EISCONN is seen).

### Group 4 — UDS integration (two threads)

| Test | What it checks |
| :--- | :------------- |
| `UDS connect and accept` | both sides connected |
| `UDS sendBuf recvToBuf round-trip` | 1000-byte payload round-trip |
| `UDS server socket file removed after deinit` | `deinit()` → UDS file gone |
