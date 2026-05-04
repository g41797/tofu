# Plan: Platform-Independent Notifier

## Context

All three `Notifier.zig` files (`linux/`, `mac/`, `windows/`) were byte-for-byte identical.
Their only posix dependencies were in helper functions replaceable by `Skt` methods.
Goal: single shared `src/ampe/Notifier.zig` with zero `std.posix` imports.

---

## Files Changed

| File | Action |
| :--- | :----- |
| `src/ampe/linux/Skt.zig` | Added `getPort() ?u16` |
| `src/ampe/mac/Skt.zig` | Added `getPort() ?u16` |
| `src/ampe/windows/Skt.zig` | Added `getPort() ?u16` |
| `src/ampe/usockets/Skt.zig` | Added `getPort() ?u16` stub → `null` |
| `src/ampe/Notifier.zig` | New shared file (replaces 3 identical copies) |
| `src/ampe/internal.zig` | Notifier selection → single `@import("Notifier.zig")` |
| `src/ampe/triggeredSkts.zig` | `recv_notification(nskt.skt.socket.?)` → `recv_notification(nskt.skt)` |
| `tests/ampe/Notifier_tests.zig` | Rewritten — no posix, no isReady*, clean round-trip |
| `tests/os_windows_tests.zig` | Windows Notifier test rewritten — same clean round-trip |
| `src/ampe/linux/Notifier.zig` | Deleted |
| `src/ampe/mac/Notifier.zig` | Deleted |
| `src/ampe/windows/Notifier.zig` | Deleted |

---

## Key Design Decisions

### `getPort() ?u16`
Returns `null` for UDS sockets, TCP port otherwise. Eliminates need for `FindFreeTcpPort()` in `initTCP`.

```zig
pub fn getPort(skt: *const Skt) ?u16 {
    return switch (skt.address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => skt.address.getPort(),
        else => null,
    };
}
```

### `initPair` — single poll loop
Replaces `waitConnect` (posix.poll) + accept-retry. Same pattern as `TCP connect and accept` test.

```zig
fn initPair(listener: *Skt, sender: *Skt) !Notifier {
    var receiver: ?Skt = null;
    errdefer if (receiver) |*r| r.deinit();
    var connected = false;
    for (0..MAX_RETRIES) |_| {
        if (!connected) connected = try sender.connect();
        if (receiver == null) receiver = try listener.accept();
        if (connected and receiver != null) break;
        std.Thread.sleep(SLEEP_NS);
    } else return AmpeError.CommunicationFailed;
    return .{ .sender = sender.*, .receiver = receiver.? };
}
```

### `initTCP` — port 0
OS assigns port; retrieved from listener via `listener.getPort().?` after bind+listen.

### Functions removed
`create`, `destroy`, `isReadyToSend`, `_isReadyToSend`, `isReadyToRecv`, `_isReadyToRecv`,
`waitConnect`, `sendByte`, `recvByte`, `send_notification`.

### `recv_notification` signature change
`socket_t` → `*Skt` — uses `Skt.recvToBuf` instead of raw `std.posix.recv`.

---

## Verification

```
zig build test -Doptimize=Debug --summary all    # 53/53
zig build test -Doptimize=ReleaseSafe --summary all  # 53/53
zig build -Dtarget=x86_64-windows-gnu            # compiles
zig build -Dtarget=x86_64-macos                  # compiles
zig build -Dtarget=aarch64-macos                 # compiles
```
