# Poller: Unified Cross-Platform Design

---

## The Logical Trigger Abstraction

At the heart of tofu's portability is `Triggers` — a packed `u8` struct with named fields:

```zig
pub const Triggers = packed struct(u8) {
    notify:  bool = false,
    accept:  bool = false,
    connect: bool = false,
    send:    bool = false,
    recv:    bool = false,
    pool:    bool = false,
    err:     bool = false,
    timeout: bool = false,
};
```

This abstraction **predates the cross-platform work entirely**. It was designed as part of the original Linux implementation, motivated by a single insight:

> The Reactor should express *intent* (what it wants to happen), not *mechanism* (how the OS signals it).

The `triggers.zig` module translates between these worlds:
- triggers.epoll.toMask()/fromMask() — converts `Triggers` ↔ epoll event flags (used by both Linux epoll and Windows wepoll)
- triggers.kqueue.toEvents()/fromEvent() — converts `Triggers` ↔ kevent structures
- triggers.poll.toMask()/fromMask() — legacy poll fallback for non-mainstream platforms

Because all Reactor logic speaks only `Triggers`, **the event loop code is identical across all platforms** — there are zero OS-specific branches inside `Reactor.zig` itself. Adding a new OS backend requires implementing one module (`*_backend.zig`) and one translation pair in `triggers.zig`. Nothing else changes.

---

## Development History — Linux First, Then Partitioned

The cross-platform architecture was not designed upfront. The sequence was:

1. **Full Linux implementation** — tofu was written and production-ready on Linux, using the `poll` syscall initially, then migrated to `epoll`.

2. **Windows port investigation** — the need to support Windows led to a detailed investigation of IOCP vs wepoll. After extensive POC work proving the IOCP path worked at a low level, **wepoll** was chosen for production: it exposes an epoll-like API, making it a drop-in backend with minimal code change.

3. **macOS support** — kqueue was added alongside wepoll. The kqueue backend exposes the same interface as epoll/wepoll backends, requiring only the `triggers.zig` translation layer.

4. **Phase IV refactoring** — with three backends proven to work, the code was restructured into the clean `poller/` directory with the `PollerCore` generic, comptime selection, and unified `triggers.zig` translations.

**The key lesson:** the `Triggers` abstraction was correct from the start. The Linux-only Reactor never needed modification — cross-platform support was added by implementing new *backends*, not by changing application logic.

---

## Acknowledgements

This architecture was developed collaboratively:

- **Author (g41797):** Overall project architecture, the `Triggers` abstraction, the Reactor design, the wepoll strategy decision, and final verification on all platforms.

- **Claude Code (Anthropic):** macOS/BSD kqueue backend implementation, cross-platform build fixes (fcntl constants, O_NONBLOCK bitcast, abstract socket restriction, UDS path sizes, LLD linker exclusion), `setLingerAbort()` raw syscall fix, repo cleanup and documentation for Zig forum showcase.

- **Gemini CLI (Google):** Robust kqueue `modify()` with `EV_RECEIPT` error handling, `wait()` timeout conversion fix, `triggers.zig` `fromEvent()` refinement for `EV_EOF`/`EV_ERROR`, `Notifier.zig` connect/accept ordering fix.

The AI agents worked iteratively with the author across multiple sessions, each picking up from `design/AGENT_STATE.md` (the handover document) and updating it on completion.

---

## Architecture

The Poller design is a high-performance synchronization engine that bridges the gap between stateless application logic and the stateful event-notification systems of modern operating systems (`epoll` on Linux, `wepoll` on Windows, `kqueue` on BSD/macOS).

---

## 1. Architecture Overview

### File Structure
```
src/ampe/
├── poller.zig                    # Facade: comptime selects backend
├── poller/
│   ├── common.zig                # Shared: TcIterator, isSocketSet, toFd, constants
│   ├── triggers.zig              # Trigger mapping: epoll/kqueue conversions
│   ├── core.zig                  # Shared struct fields + PollerCore generic
│   ├── poll_backend.zig          # ISOLATED: Legacy poll (will be obsolete)
│   ├── epoll_backend.zig         # Linux epoll implementation
│   ├── wepoll_backend.zig        # Windows wepoll implementation (includes FFI)
│   └── kqueue_backend.zig        # macOS/BSD kqueue implementation
```

### Comptime Backend Selection
```zig
// poller.zig facade
pub const Poller = switch (builtin.os.tag) {
    .windows => @import("poller/wepoll_backend.zig").Poller,
    .linux => @import("poller/epoll_backend.zig").Poller,
    .macos, .freebsd, .openbsd, .netbsd => @import("poller/kqueue_backend.zig").Poller,
    else => @import("poller/poll_backend.zig").Poller,
};
```

---

## 2. Architectural Core: The Dual-Map Indirection

Standard `std.AutoArrayHashMap` usage in Zig is efficient but volatile; `swapRemove` operations relocate data in memory to maintain contiguity. This presents a conflict for stateful kernels which expect a stable token to identify a file descriptor.

**The Solution: Stable Sequence Indirection**

* **The Identity Map:** Maps a `ChannelNumber` to a `SeqN` (Sequence Number).
* **The Object Map:** Maps the `SeqN` to the `*TriggeredChannel` (heap pointer).
* **The Token:** The `SeqN` is a monotonic `u64`. It serves as the "User Data" passed to the OS kernel. Even if map entries move due to deletions, the `SeqN` remains constant for that channel's lifecycle, allowing a safe $O(1)$ reverse-lookup when the OS reports an event.

---

## 3. PollerCore: Shared Logic via Composition

The `PollerCore` generic provides shared logic that all backends use:

```zig
pub fn PollerCore(comptime Backend: type) type {
    return struct {
        chn_seqn_map: ChnSeqnMap,
        seqn_trc_map: SeqnTrcMap,
        crseqN: SeqN = 0,
        allocator: Allocator,
        backend: Backend,

        pub fn attachChannel(self: *@This(), tchn: *TriggeredChannel) AmpeError!bool { ... }
        pub fn trgChannel(self: *@This(), chn: ChannelNumber) ?*TriggeredChannel { ... }
        pub fn deleteGroup(self: *@This(), chnls: ArrayList) AmpeError!bool { ... }
        pub fn deleteMarked(self: *@This()) !bool { ... }
        pub fn deleteAll(self: *@This()) void { ... }
        pub fn waitTriggers(self: *@This(), timeout: i32) AmpeError!Triggers { ... }
        pub fn iterator(self: *@This()) TcIterator { ... }
    };
}
```

Each backend must implement:
- fn init(allocator: Allocator) AmpeError!Backend
- fn deinit(self: *Backend) void
- fn register(self: *Backend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void
- fn modify(self: *Backend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void
- fn unregister(self: *Backend, fd: FdType) void
- fn wait(self: *Backend, timeout: i32, seqn_trc_map: *SeqnTrcMap) AmpeError!Triggers

---

## 4. Platform Abstraction Layer

### A. The Handle Type
- **Linux (epoll):** `std.posix.fd_t` (i32)
- **Windows (wepoll):** `*anyopaque` (HANDLE pointer)
- **BSD/macOS (kqueue):** `std.posix.fd_t` (i32)

### B. The `toFd` Helper
Because Windows `SOCKET` is a pointer and Linux `socket_t` is an integer:
- **Windows:** Returns `usize` (@intFromPtr)
- **POSIX:** Returns `i32` (@intCast)

### C. The Trigger Mappings
The `triggers.zig` module provides platform-specific conversions:
- triggers.epoll.toMask()/fromMask() — epoll/wepoll
- triggers.kqueue.toEvents()/fromEvent() — kqueue
- triggers.poll.toMask()/fromMask() — legacy poll

---

## 5. The Reconciliation waitTriggers Loop

`waitTriggers` acts as a state synchronizer, ensuring interest is checked **only** during the loop.

### Phase A: State Reconciliation ($O(N)$)

1. **Iterate:** Visit every `TriggeredChannel`.
2. **Logic Probe:** Call `tc.tskt.triggers()` for logical intent.
3. **Internal Sync:** Initialize `tc.act` with internal triggers (e.g., `pool` readiness).
4. **Delta Check:** Compare interest against `tc.exp`.
5. **Kernel Sync:** Issue backend `modify()` if interests differ.

### Phase B: The OS Wait

If internal triggers are already pending, the OS wait is performed with a **0 timeout** (non-blocking) to avoid delaying application logic.

### Phase C: Event Harvesting ($O(\text{triggered})$)

1. **Token Lookup:** Use `SeqN` to jump to `TriggeredChannel`.
2. **Bitmask Translation:** Translate raw OS flags into application-level `Triggers`.
3. **Accumulation:** OS triggers are `OR`-ed with existing internal triggers.

---

## 6. Heap-Allocated TriggeredChannel (Mutation Safety)

The `seqn_trc_map` stores `*TriggeredChannel` (heap pointers) rather than `TriggeredChannel` values. This is **mandatory** due to map mutations during iteration.

### The Problem

The Reactor's `processTriggeredChannels` loop iterates over channels and may trigger `accept`:

```
processTriggeredChannels() {
    for each tc in iterator {
        if (tc.accept triggered) {
            createIoServerChannel(tc)  // tc is *TriggeredChannel
                -> attachChannel()
                -> seqn_trc_map.put()  // MAP MUTATION!
        }
    }
}
```

If the map stored values by-value, `put()` could trigger reallocation, which would:
1. Invalidate the iterator's internal slice
2. Invalidate the `tc` pointer passed to `createIoServerChannel`

### The Solution

By storing heap pointers (`*TriggeredChannel`):
- Map only stores/moves 8-byte pointers
- Actual `TriggeredChannel` objects have stable heap addresses
- Pointers remain valid across map reallocations

---

## 7. Backend Comparison Matrix

| Feature | `poll` | `epoll` | `wepoll` | `kqueue` |
| --- | --- | --- | --- | --- |
| **Wait Efficiency** | $O(N)$ | $O(1)$ | $O(1)$ | $O(1)$ |
| **Handle Type** | N/A | `fd_t` | `HANDLE` | `fd_t` |
| **Socket Type** | `fd_t` | `fd_t` | `SOCKET` | `fd_t` |
| **Token Type** | Index | `u64` | `u64` | `udata` |
| **File Location** | `poll_backend.zig` | `epoll_backend.zig` | `wepoll_backend.zig` | `kqueue_backend.zig` |

---

## 8. Design Guarantees

* **Incarnation Safety:** 64-bit monotonic `SeqN` prevents ABA issues if FDs are reused. *(ABA Problem: A file descriptor is closed, the OS recycles the same integer for a new socket, and stale events from the old socket are misattributed to the new one. The monotonic `SeqN` ensures each channel has a unique identity regardless of FD reuse.)*
* **Backpressure Support:** Read interest is dropped if the message pool is full.
* **Zero Special Functions:** The loop is the sole authority on hardware state.
* **Mutation Safety:** Heap-allocated channels allow safe map mutations during iteration.
* **Zero-Cost Comptime Selection:** Only the relevant backend code is compiled per target.
