# Skt Cross-Platform TCP Architecture Review  
**Target:** Windows + Linux  
**Focus:** connect(), accept(), non-blocking behavior, correctness  
**Role:** Zig TCP/IP + networking architectural audit  

---

# Executive Summary

The current implementation of `Skt.zig` is structurally solid and mostly POSIX-correct.  
However, there are **three critical cross-platform correctness issues** that must be fixed before this can be considered production-grade:

1. ❗ Non-blocking `connect()` completion is incomplete (Linux & Windows)
2. ❗ Windows `accept()` does NOT inherit non-blocking mode
3. ❗ `close()` is incorrect on Windows

Additionally, there are several architectural and consistency issues that should be improved.

---

# 1. CRITICAL: Non-Blocking `connect()` Is Architecturally Incomplete

## Current Behavior

Your `connect()`:

```zig
connectOs(...) catch |e| switch (e) {
    WouldBlock => connected = false,
    ConnectionPending => connected = true,
```

This is not sufficient for non-blocking TCP.

---

## Correct TCP Semantics

For **non-blocking connect** on both Linux and Windows:

1. `connect()` returns:
   - `EINPROGRESS` (Linux)
   - `WSAEWOULDBLOCK` (Windows)
2. The socket becomes writable later.
3. Writable does **NOT** mean the connection succeeded.
4. You MUST check:

```zig
getsockopt(SOL_SOCKET, SO_ERROR)
```

Result:
- `SO_ERROR == 0` → connected
- `SO_ERROR != 0` → connect failed

---

## Current Problem

Your implementation:

- Returns false on `WouldBlock`
- Never checks `SO_ERROR`
- Treats `ConnectionPending` as success
- Provides no completion mechanism

This breaks correctness under load and in real network failure scenarios.

---

## Required Fix: `finishConnect()`

You must implement:

```zig
pub fn finishConnect(skt: *Skt) !void {
    var err: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);

    try posix.getsockopt(
        skt.socket.?,
        posix.SOL.SOCKET,
        posix.SO.ERROR,
        &std.mem.toBytes(err),
        &len,
    );

    if (err != 0) {
        return map_errno(err);
    }
}
```

### Correct Reactor Flow (Client)

1. `socket()`
2. `setNonBlocking()`
3. `connect()`
4. If `EINPROGRESS`:
   - wait for writable
   - call `finishConnect()`
5. Only then mark as connected

Without this step, your non-blocking client is incorrect.

---

# 2. CRITICAL: Windows `accept()` Does NOT Inherit Non-Blocking

## Linux

```zig
accept4(sock, flags)
```

Correct — flags can include `SOCK_NONBLOCK`.

---

## Windows

```zig
windows.accept(...)
```

Problem:

On Windows, accepted sockets are **blocking by default**, even if the listening socket is non-blocking.

---

## Consequence

Your code results in:

| OS       | Accepted Socket |
|----------|-----------------|
| Linux    | Non-blocking    |
| Windows  | Blocking ❌     |

This creates silent cross-platform divergence.

---

## Required Fix

After Windows `accept()`:

```zig
if (native_os == .windows) {
    var nonblocking: u32 = 1;
    _ = windows.ws2_32.ioctlsocket(
        accepted_sock,
        windows.ws2_32.FIONBIO,
        &nonblocking
    );
}
```

Without this, your Windows server will block on I/O.

---

# 3. CRITICAL: `close()` Is Wrong on Windows

Current implementation:

```zig
posix.close(socket);
```

This is invalid for Windows sockets.

Windows requires:

```zig
windows.closesocket(socket)
```

Failure to do so causes:
- Resource leaks
- Undefined behavior

---

## Required Fix

```zig
pub fn close(skt: *Skt) void {
    if (skt.socket) |socket| {
        if (native_os == .windows)
            windows.closesocket(socket) catch {};
        else
            posix.close(socket);
        skt.socket = null;
    }
}
```

---

# 4. Error Mapping in `connectOs()` Is Inconsistent

You currently mix:

- `error.ConnectionRefused`
- `connectError.ConnectedAborted`
- `error.Unexpected`
- `posix.ConnectError`

This creates ambiguity in error domains.

---

## Recommended Approach

Create a single unified error mapping layer:

```zig
fn mapConnectErrno(err: c_int) ConnectError
```

And ensure all OS branches use the same abstraction.

Consistency is critical in networking layers.

---

# 5. `SO_REUSEADDR` Cross-Platform Differences

On Linux:
- `SO_REUSEADDR`
- `SO_REUSEPORT`

On Windows:
- `SO_REUSEADDR` behaves differently
- No `REUSEPORT`

Your implementation assumes POSIX semantics.

This is not fatal, but behavior will differ.

If cross-platform predictability matters, document it explicitly.

---

# 6. `knock()` Is Not Reliable

You use:

```zig
send(socket, zero_length_buffer)
```

Zero-length send does NOT reliably validate TCP state across OSes.

Correct approach:
- Use `getsockopt(SO_ERROR)`
- Or rely on reactor write readiness + SO_ERROR

---

# 7. What Is Architecturally Good

The following parts are well-designed:

- EINTR loops for accept
- accept4 fallback handling
- Proper LINGER abort implementation
- Disabling Nagle (TCP_NODELAY)
- UDS cleanup logic
- Error.WouldBlock propagation
- Reactor-friendly API surface

The structure is strong — the issues are completion and cross-platform correctness details.

---

# Cross-Platform Behavior Matrix

| Feature                        | Linux | Windows | Current Code |
|--------------------------------|--------|----------|--------------|
| Non-blocking connect complete  | SO_ERROR required | SO_ERROR required | ❌ Missing |
| accept inherits NONBLOCK       | Yes    | No       | ❌ Broken |
| close() correctness            | OK     | Wrong    | ❌ Broken |
| LINGER abort                   | OK     | OK       | ✅ |
| EINTR handling                 | OK     | N/A      | ✅ |

---

# Required Fix Summary

## Must Fix

1. Implement `finishConnect()` with SO_ERROR
2. Set accepted socket to non-blocking on Windows
3. Use `closesocket()` on Windows

## Should Fix

4. Unify error mapping
5. Clarify reuse semantics
6. Remove zero-length send check

---

# Architectural Conclusion

Your `Skt.zig`:

- ✅ Structurally clean
- ✅ Reactor-oriented
- ✅ Mostly POSIX-correct
- ❌ Incomplete for proper non-blocking connect
- ❌ Incorrect on Windows accept
- ❌ Incorrect Windows close

After fixing the three critical issues, this becomes production-ready and suitable for high-performance cross-platform networking.

---

# Final Recommendation

Before integrating into higher-level protocol layers (e.g. framed messaging, TLS, or reactor scheduling), fix the three critical issues first.

Once corrected, this socket abstraction will be:

- Cross-platform consistent
- Reactor-safe
- Correct under high concurrency
- Suitable for production TCP workloads

