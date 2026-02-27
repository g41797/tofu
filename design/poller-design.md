# Poller: Unified Cross-Platform Design

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
- `fn init(allocator: Allocator) AmpeError!Backend`
- `fn deinit(self: *Backend) void`
- `fn register(self: *Backend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void`
- `fn modify(self: *Backend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void`
- `fn unregister(self: *Backend, fd: FdType) void`
- `fn wait(self: *Backend, timeout: i32, seqn_trc_map: *SeqnTrcMap) AmpeError!Triggers`

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
- `triggers.epoll.toMask()` / `fromMask()` — epoll/wepoll
- `triggers.kqueue.toEvents()` / `fromEvent()` — kqueue
- `triggers.poll.toMask()` / `fromMask()` — legacy poll

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
