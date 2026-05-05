# Plan: Poller Backend Contract Tests + FdType Correction

## Context

Two coupled tasks completed in the same session.

**Task 1 — FdType correction in usockets stub.**
`usockets_backend.zig` declared `register`/`modify`/`unregister` with `std.posix.fd_t`.
The usockets backend compiles on all platforms including Windows, where `std.posix.fd_t = i32`
but the correct type is `usize` (matching `LIBUS_SOCKET_DESCRIPTOR = uintptr_t`).
`common.FdType` handles this: `i32` on POSIX, `usize` on Windows.
`core.zig` already passes `common.toFd()` → `FdType` to all backend calls; stub must match.

`internal.zig` had `std.posix.fd_t // placeholder` for the usockets `Socket` type.
Updated to inline `if (builtin.os.tag == .windows) usize else std.posix.fd_t` — avoids
circular import (`internal.zig` ↔ `common.zig`).

**Task 2 — Platform-independent poller backend contract tests.**
All four backends (epoll/kqueue/wepoll/usockets) implement the same interface
(documented in `core.zig` lines 9-14). No contract tests existed for this interface.

---

## Files Changed

| File | Action |
| :--- | :----- |
| `src/ampe/usockets/usockets_backend.zig` | Fixed fd type: `std.posix.fd_t` → `common.FdType` in 3 signatures |
| `src/ampe/internal.zig` | Inlined usockets Socket type (avoids circular import) |
| `design/transition-2-usockets.md` | Added §15.6 FdType Alignment note |
| `tests/ampe/poller_tests.zig` | New file — 8 backend contract tests |
| `tests/tofu_tests.zig` | Added `poller_tests.zig` import guarded by `os.tag == .linux` |
| `design/poller-tests-plan.md` | This file |
| `design/AGENT_STATE.md` | Session entry, version bump |

---

## Key Design Decisions

### Test the backend directly

Tests use `poller_instance.backend.*` — not `PollerCore.waitTriggers()`.
`waitTriggers()` requires a fully populated `TriggeredChannel` (with `tskt`, `engine`).
The backend's `wait()` only reads `.exp` and writes `.act` on `TriggeredChannel` entries.
Using `var tc: TriggeredChannel = undefined; tc.exp = ...; tc.act = ...;` is safe.

### Single-threaded throughout

For readable tests: write data to socket BEFORE `wait()` — kernel buffers it.
For writable tests: freshly connected non-blocking socket is immediately writable
under level-triggered epoll. `wait(0)` fires `send` without any writes.
No threads needed anywhere.

### `makeTC` helper

```zig
fn makeTC(exp: Triggers) TriggeredChannel {
    var tc: TriggeredChannel = undefined;
    tc.exp = exp;
    tc.act = Triggers{};
    return tc;
}
```

`std.mem.zeroes(TriggeredChannel)` rejected by compiler — `TriggeredChannel` has
non-nullable pointer fields (`engine: *Reactor`) and `TriggeredSkt` which cannot be zeroed.
Using `undefined` + explicit field init is the correct approach.

### Imports

```zig
const internal_mod = tofu.@"internal usage";
const Poller = internal_mod.Poller;
const poller_mod = internal_mod.poller;
const core = poller_mod.core;
const common = poller_mod.common;
const SeqnTrcMap = core.SeqnTrcMap;
const SeqN = common.SeqN;
const toFd = common.toFd;
const Triggers = internal_mod.triggeredSkts.Triggers;
const TriggeredChannel = tofu.Reactor.TriggeredChannel;
```

---

## Test Matrix (8 tests)

| # | Test | Setup | Action | Assert |
| :- | :--- | :--- | :--- | :--- |
| 1 | `backend init and deinit` | — | init, deleteAll | no crash |
| 2 | `timeout when no data` | TCP pair; register recv | wait(50ms), no write | `result.timeout == .on` |
| 3 | `readable after write` | TCP pair; register recv | write 1 byte; wait(100ms) | `tc.act.recv == .on` |
| 4 | `writable immediately` | TCP pair; register send | wait(0) | `tc.act.send == .on` |
| 5 | `unregister prevents event` | TCP pair; register recv; unregister | write; wait(50ms) | `result.timeout == .on` |
| 6 | `modify recv to send` | TCP pair; register recv; modify to send | wait(0) | `tc.act.send == .on`, recv not set |
| 7 | `two fds both readable` | Two TCP pairs; register both recv | write to both; wait | both `tc.act.recv == .on` |
| 8 | `seqN isolation` | seqN=1 in backend+map; seqN=2 in map only | write; wait | only tc1.act.recv set |

---

## Verification (full sandwich)

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (62/62) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (62/62) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |

---

## Task 3 — PollerCore Integration Tests + initPlatform/deinitPlatform

### Context

Three coupled tasks.

**PollerCore tests:** `tests/windows_poller_tests.zig` contained two PollerCore-level integration
tests guarded by `if (os.tag != .windows) return error.SkipZigTest`.
Converted to `tests/pollercore_tests.zig` — platform-independent, runs on all backends.

**`initPlatform`/`deinitPlatform` in tofu source:** Platform environment lifecycle extracted from
`Reactor.zig` (where it was private as `initPlatform`/`deinitPlatform`) and promoted to
`src/ampe/internal.zig` as public `initPlatform`/`deinitPlatform`. `Reactor.zig` calls `internal.initPlatform`/
`internal.deinitPlatform`. Exported via `tofu.zig` as `tofu.initPlatform`/`tofu.deinitPlatform`.
This is the canonical single place for WSA lifecycle — no per-test local helpers needed.

**`poller_tests.zig` made platform-independent:** Linux guard removed from `tofu_tests.zig`.
All 8 backend tests call `tofu.initPlatform()`/`tofu.deinitPlatform()` — no-ops on Linux/macOS,
WSA lifecycle on Windows.

### Files Changed

| File | Action |
| :--- | :----- |
| `src/ampe/internal.zig` | Added `pub fn initPlatform() AmpeError!void` and `pub fn deinitPlatform() void` |
| `src/ampe/Reactor.zig` | Replaced private `initPlatform`/`deinitPlatform` with `internal.initPlatform`/`internal.deinitPlatform` |
| `src/tofu.zig` | Exported `initPlatform` and `deinitPlatform` |
| `tests/ampe/poller_tests.zig` | `tofu.initPlatform`/`deinitPlatform` added to all 8 tests; linux guard removed from `tofu_tests.zig` |
| `tests/pollercore_tests.zig` | New file — 2 PollerCore integration tests; uses `tofu.initPlatform`/`deinitPlatform` |
| `tests/tofu_tests.zig` | linux guard removed from `poller_tests`; windows guard replaced by unconditional `pollercore_tests` import |
| `design/poller-tests-plan.md` | This section |
| `design/transition-2-usockets.md` | §17 updated |
| `design/AGENT_STATE.md` | Session entry, version bump |

### Key Design Decisions

**`initPlatform`/`deinitPlatform` in production code, not test helpers:**

```zig
// src/ampe/internal.zig
pub fn initPlatform() AmpeError!void {
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        var wsa_data: ws2_32.WSADATA = undefined;
        if (ws2_32.WSAStartup(0x0202, &wsa_data) != 0) return AmpeError.CommunicationFailed;
    }
}

pub fn deinitPlatform() void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.WSACleanup();
    }
}
```

On Linux/macOS the comptime-false branch is pruned — `std.os.windows` is never analyzed.
On Windows WSAStartup/WSACleanup fire normally.
`Reactor.zig` previously had private `initPlatform`/`deinitPlatform` with the same logic —
replaced with calls to `internal.initPlatform`/`internal.deinitPlatform` (single canonical implementation).
Exported as `tofu.initPlatform`/`tofu.deinitPlatform` for use in tests and any future code.

**Port 0 instead of FindFreeTcpPort:**

```zig
const list_skt = try sc.fromAddress(.{ .tcp_server_addr = TCPServerAddress.init("127.0.0.1", 0) });
const port: u16 = list_skt.getPort().?;
```

Kernel assigns port; no posix call needed. Same pattern as `makeTCPPair` in `poller_tests.zig`.

**`sendBuf` instead of `send`:**

`Skt` exposes `sendBuf(buf: []const u8)` — `send` does not exist in the current interface.
All two send calls in the TCP test updated accordingly.

**connectWithRetry:**

Non-blocking connect may return false (EINPROGRESS). `connectWithRetry` polls with 1ms sleep
to avoid timing issues across platforms. The original Windows test called `connect()` once
and relied on `waitTriggers(1000ms)` — safe on Windows loopback but fragile cross-platform.

### Test Matrix (2 tests)

| # | Test | What it exercises |
| :- | :--- | :--- |
| 1 | `Notifier wakeup` | attachChannel (NotificationSkt), waitTriggers notify, trgChannel, tryRecvNotification |
| 2 | `TCP accept recv send via PollerCore` | attachChannel (AcceptSkt, IoSkt), waitTriggers accept/recv/send, tryAccept, tryRecv, addToSend |

### Verification (full sandwich)

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (64/64) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (64/64) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |
