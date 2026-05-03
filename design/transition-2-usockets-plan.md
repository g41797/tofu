# Structural Split Plan: Independent / Posix Network / usockets Network

**Status:** COMPLETE
**Date:** 2026-05-03
**Reference:** `design/transition-2-usockets.md` — read this first for full background

---

## Coordination Instructions (For Any Implementing Agent)

### Before Starting

1. Read `design/AGENT_STATE.md` — single source of truth for project state and mandatory rules.
2. Read `design/RULES.md` — mandatory coding and process rules.
3. Read `design/transition-2-usockets.md` — full migration context and inventory.
4. Read this file top to bottom before touching any code.
5. Do NOT run git commands. Author manages version control.
6. Build outputs go to `zig-out/`. Never commit build artifacts.

### Status Tracking

Update the **Status** field at the top of this file after each phase:
- `READY FOR IMPLEMENTATION` — not started
- `PHASE 1 IN PROGRESS` — step 1 of 6
- `PHASE 1 COMPLETE` — awaiting verification
- `COMPLETE` — all phases done and verified

After completing all phases, add a session entry to `design/AGENT_STATE.md` under Session History.

### After Every Phase

Each phase ends with:
1. A build verification (see Verification section at the end).
2. An update to the **Status** field in this file.
3. A note below the phase heading: `Completed: <date> by <agent>`.

---

## Context

tofu uses `std.posix` APIs for all network I/O. Zig 0.16+ removes `std.posix`, requiring
migration to bun-usockets (already vendored at `vendor/bun-usockets/`).

Before any migration code is written, this plan establishes a clean structural boundary:
- One build flag selects which network implementation to compile and test.
- The existing posix implementation is untouched and remains the default.
- An empty usockets skeleton is created so the selection mechanism compiles end-to-end.

---

## Phase 2 Note (Future — NOT Part of This Plan)

After the structural split is in place, Phase 2 will introduce usockets-style wrapper APIs:
- The posix network part implements them via posix.
- The usockets network part implements them as direct usockets calls.
- The independent layer calls only these wrappers — never posix directly.
- This makes the final cutover mechanical: swap the network part, keep everything else.

Do not implement any of Phase 2 here.

---

## Three Logical Parts After This Change

| Part | Files | Status after this plan |
| :--- | :---- | :--------------------- |
| **Independent** | `channels.zig`, `IntrusiveQueue.zig`, `vtables.zig`, `Pool.zig`, `MchnGroup.zig`, `poller/core.zig`, `poller/common.zig` | Unchanged |
| **posix network** | `os/linux/Skt.zig`, `os/windows/Skt.zig`, `poller/epoll_backend.zig`, `poller/kqueue_backend.zig`, `poller/wepoll_backend.zig`, `poller/poll_backend.zig`, `SocketCreator.zig`, `triggeredSkts.zig`, `Notifier.zig`, `testHelpers.zig` | Unchanged, default build |
| **usockets network** | `os/usockets/Skt.zig` (new), `poller/usockets_backend.zig` (new) | New stubs, compile-only |

---

## Implementation

### Step 1 — Add `network` build option to `build.zig`

**File:** `build.zig`

Add near the top, after target/optimize options:

```zig
const NetworkBackend = enum { posix, usockets };
const network = b.option(
    NetworkBackend,
    "network",
    "Network backend: posix (default) or usockets",
) orelse .posix;
const build_options = b.addOptions();
build_options.addOption(NetworkBackend, "network", network);
```

Add the `build_options` module to the lib module and the test step:

```zig
lib_mod.addOptions("build_options", build_options);
// and for tests:
tests.addOptions("build_options", build_options);
```

Find the existing `lib_mod` and test setup in `build.zig` and wire in accordingly.
Do not change any C source or platform-specific linking.

**Complete when:** `zig build` succeeds unchanged.

---

### Step 2 — Create usockets Skt stub

**New file:** `src/ampe/os/usockets/Skt.zig`

Must export the same public interface as `src/ampe/os/linux/Skt.zig`.
Read `src/ampe/os/linux/Skt.zig` to get the exact function signatures.

Requirements:
- Export `pub const Skt` struct with the same field names and types.
- All public functions present with correct signatures.
- Bodies: `return error.NotImplemented`.
- The `Socket` type for this stub: use `std.posix.fd_t` as a placeholder.
- No actual socket calls — this is a compile-only stub.

**Complete when:** file compiles as part of the build.

---

### Step 3 — Create usockets Poller stub

**New file:** `src/ampe/poller/usockets_backend.zig`

Must export `pub const Poller` with the same interface as `src/ampe/poller/epoll_backend.zig`.
Read `src/ampe/poller/epoll_backend.zig` to get the exact function signatures.

Requirements:
- Export `pub const Poller` struct.
- Functions: `init`, `deinit`, `register`, `modify`, `unregister`, `wait` — all present.
- Bodies: `return error.NotImplemented`.
- No actual usockets C calls — this is a compile-only stub.

**Complete when:** file compiles as part of the build.

---

### Step 4 — Update `internal.zig`

**File:** `src/ampe/internal.zig`

Add at top of imports:

```zig
const build_options = @import("build_options");
```

Replace the current `skt_backend` switch with:

```zig
const skt_backend = if (build_options.network == .usockets)
    @import("os/usockets/Skt.zig")
else switch (builtin.os.tag) {
    .windows => @import("os/windows/Skt.zig"),
    else     => @import("os/linux/Skt.zig"),
};
```

Replace the `Socket` type switch with:

```zig
pub const Socket = if (build_options.network == .usockets)
    std.posix.fd_t   // placeholder; will be replaced in Phase 2
else switch (builtin.os.tag) {
    .windows => @import("std").os.windows.ws2_32.SOCKET,
    else     => @import("std").posix.socket_t,
};
```

**Complete when:** `zig build` succeeds with default (posix) and tests still pass.

---

### Step 5 — Update `poller.zig`

**File:** `src/ampe/poller.zig`

Add at top of imports:

```zig
const build_options = @import("build_options");
```

Replace the current `Poller` switch with:

```zig
pub const Poller = if (build_options.network == .usockets)
    @import("poller/usockets_backend.zig").Poller
else switch (builtin.os.tag) {
    .windows                            => @import("poller/wepoll_backend.zig").Poller,
    .linux                              => @import("poller/epoll_backend.zig").Poller,
    .macos, .freebsd, .openbsd, .netbsd => @import("poller/kqueue_backend.zig").Poller,
    else                                => @import("poller/poll_backend.zig").Poller,
};
```

**Complete when:** `zig build` and `zig build test` both succeed with posix default.

---

### Step 6 — Update `transition-2-usockets.md` inventory

**File:** `design/transition-2-usockets.md`, Section 3 (Inventory table)

Add the missing row:

| `src/ampe/testHelpers.zig` | `posix.socket`, `posix.bind`, `posix.getsockname`, `posix.close`, `posix.setsockopt` | `FindFreeTcpPort` test utility |

**Complete when:** row added.

---

## Files Changed Summary

| File | Type | Change |
| :--- | :--- | :----- |
| `build.zig` | Modified | Add `network` option, `build_options` module |
| `src/ampe/internal.zig` | Modified | Use `build_options.network` for Skt/Socket selection |
| `src/ampe/poller.zig` | Modified | Use `build_options.network` for Poller selection |
| `src/ampe/os/usockets/Skt.zig` | New | usockets Skt stub |
| `src/ampe/poller/usockets_backend.zig` | New | usockets Poller stub |
| `design/transition-2-usockets.md` | Modified | Add testHelpers.zig to inventory |

---

## What Does NOT Change

- All posix backend files — untouched
- `SocketCreator.zig`, `triggeredSkts.zig`, `Notifier.zig`, `testHelpers.zig` — unchanged
- Public API (`Ampe`, `ChannelGroup`, vtables, `Message`, `Address`) — untouched
- `Reactor.zig` loop logic — untouched
- All existing tests continue to pass on posix default

---

## Verification

Run in this order after all steps are complete:

1. `zig build` — must succeed (posix default)
2. `zig build test` — all 35 tests must pass (posix default)
3. `zig build -Dnetwork=posix` — equivalent to step 1, must succeed
4. `zig build -Dnetwork=usockets` — must compile clean (stubs, no test run required)
5. `zig build -Dtarget=x86_64-windows -Dnetwork=posix` — cross-compile must succeed

All 5 checks must pass before marking status COMPLETE.

---

## After Completion

Update in this order:

1. Set **Status** at top of this file to `COMPLETE`.
2. Add `testHelpers.zig` row to `design/transition-2-usockets.md` Section 3.
3. Add a session entry to `design/AGENT_STATE.md` under Session History:
   - Date, agent name
   - Summary: "Structural split — added `network` build option, usockets stubs for Skt and Poller, updated internal.zig and poller.zig"
   - Verification results table
4. Update `design/AGENT_STATE.md` Immediate Tasks: mark this task done, add Phase 2 (wrapper APIs) as next task.

---

## Phase 2 — Network-Independent triggeredSkts.zig

**Status:** COMPLETE
**Date:** 2026-05-03

### Context

`triggeredSkts.zig` still contains direct `std.posix` and `ws2_32` dependencies after Phase 1:
- `iov: [3]std.posix.iovec_const` / `[3]std.posix.iovec` — used only as `{base, len}` pairs, never passed to scatter-gather syscalls
- `sendBuf`, `sendBufTo`, `recvToBuf` — inline `if (builtin.os.tag == .windows)` branches

This phase removes both. After Phase 2, `triggeredSkts.zig` has zero `std.posix` and zero `ws2_32` references.

### Change A — Replace iovec types with internal structs

Define in `triggeredSkts.zig`:
```zig
pub const IoBufConst = struct { base: [*]const u8, len: usize };
pub const IoBuf      = struct { base: [*]u8,       len: usize };
```

- `MsgSender.iov: [3]std.posix.iovec_const` → `[3]IoBufConst`
- `MsgReceiver.iov: [3]std.posix.iovec`     → `[3]IoBuf`

No call sites change — `.base` and `.len` field names are identical.

### Change B — Move sendBuf / sendBufTo / recvToBuf to Skt.zig

**Step B1** — `src/ampe/os/linux/Skt.zig`: add three functions using `posix.send`, `posix.sendto`, `posix.recv`

**Step B2** — `src/ampe/os/windows/Skt.zig`: add three functions using `ws2_32.send`, `ws2_32.sendto`, `ws2_32.recv`

**Step B3** — `src/ampe/os/usockets/Skt.zig`: add three stub functions returning `AmpeError.NotImplementedYet`

**Step B4** — `triggeredSkts.zig`: replace `sendBuf(...)` → `Skt.sendBuf(...)`, remove the three function bodies. `Skt` is already imported via `internal.Skt`.

### Files changed

| File | Change |
| :--- | :----- |
| `src/ampe/triggeredSkts.zig` | Replace iovec types; remove function bodies; call via Skt |
| `src/ampe/os/linux/Skt.zig` | Add sendBuf, sendBufTo, recvToBuf (posix) |
| `src/ampe/os/windows/Skt.zig` | Add sendBuf, sendBufTo, recvToBuf (ws2_32) |
| `src/ampe/os/usockets/Skt.zig` | Add sendBuf, sendBufTo, recvToBuf (stubs) |

### Verification

1. `zig build` — posix default
2. `zig build test` — all tests pass
3. `zig build -Dnetwork=usockets` — compiles clean
4. `zig build -Dtarget=x86_64-windows -Dnetwork=posix` — cross-compile
5. `grep -n "std\.posix\|ws2_32" src/ampe/triggeredSkts.zig` — zero results

### After completion

1. Set Phase 2 **Status** → `COMPLETE`
2. Add session entry to `design/AGENT_STATE.md`
3. Update Immediate Tasks: mark Phase 2 done, note Phase 3 targets (`Notifier.zig`, `SocketCreator.zig`, `testHelpers.zig`)

---

*End of plan.*
