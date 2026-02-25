The `PollerOs` design is a high-performance synchronization engine that bridges the gap between stateless application logic and the stateful event-notification systems of modern operating systems. It ensures that interest registration is deferred until the last possible moment within the execution loop.

---

## 1. Architectural Core: The Dual-Map Indirection

Standard `std.AutoArrayHashMap` usage in Zig is efficient but volatile; `swapRemove` operations relocate data in memory to maintain contiguity. This presents a conflict for stateful kernels (`epoll`, `kqueue`) which expect a stable pointer or token to identify a file descriptor.

**The Solution: Stable Sequence Indirection**

* **The Identity Map:** Maps a `ChannelNumber` to a `SeqN` (Sequence Number).
* **The Object Map:** Maps the `SeqN` to the `TriggeredChannel` object.
* **The Token:** The `SeqN` is a monotonic `u64`. It serves as the "User Data" passed to the OS kernel. Even if the `TriggeredChannel` moves in memory due to deletions, the `SeqN` remains constant for that channel's lifecycle, allowing a safe $O(1)$ reverse-lookup when the OS reports an event.

---

## 2. The Reconciliation waitTriggers Loop

To strictly satisfy the requirement that interest is checked **only** during the loop, `waitTriggers` acts as a state synchronizer.

### Phase A: State Reconciliation ($O(N)$)

1. **Iterate:** The loop visits every `TriggeredChannel`.
2. **Logic Probe:** It calls `tc.tskt.triggers()` to determine the current logical intent (e.g., does this socket want to `recv` or `send` right now?).
3. **Delta Check:** It compares this fresh interest against `tc.exp` (the last known state registered with the OS).
4. **Kernel Sync:** * **Stateful (`epoll`/`kqueue`):** If interests differ, it issues a `MOD` syscall. If they match, it does nothing.
* **Stateless (`poll`):** It populates the next entry in the `pollfd` vector.



### Phase B: The OS Wait

The thread blocks on the OS-specific wait function. For stateful backends, this is highly efficient as the kernel already knows the interest set.

### Phase C: Event Harvesting ($O(\text{triggered})$)

The OS returns a list of events.

1. **Token Lookup:** For each event, the `SeqN` token is used to jump directly to the `TriggeredChannel` in the Object Map.
2. **Bitmask Translation:** Raw OS flags (like `EPOLLIN` or `EVFILT_READ`) are translated back into the application-level `Triggers` packed struct.

---

## 3. Lifecycle & Resource Management

The design ensures that logical deletions and physical socket closures are always synchronized with the kernel's interest list.

### Attach Logic

1. Generate a new `SeqN`.
2. Perform a `CTL_ADD` to the kernel interest set using the `SeqN` as user-data.
3. Insert into the dual-map structure.

### Deletion Logic (`deleteMarked` and `deleteGroup`)

* **Kernel-First Removal:** For stateful backends, a `CTL_DEL` is issued to the kernel *before* any memory is freed or maps are shifted. This prevents "ghost events" from reaching the poller for a socket that is being closed.
* **Map Cleanup:** Uses `swapRemove` for $O(1)$ deletion. The stable `SeqN` prevents memory reordering from breaking the relationship with the kernel.

---

## 4. Backend Comparison Matrix

| Feature | `.poll` | `.epoll` / `.wepoll` | `.kqueue` |
| --- | --- | --- | --- |
| **Wait Efficiency** | $O(N)$ | $O(1)$ | $O(1)$ |
| **Sync Overhead** | Low (Vector Build) | Medium (Syscall on Change) | Medium (Syscall on Change) |
| **Token Type** | Vector Index | `u64` (data.u64) | `uintptr_t` (udata) |
| **Primary Advantage** | Portability | Linux High-Concurrency | BSD/macOS Scalability |

---

## 5. Design Guarantees

* **Zero "Special" Functions:** There are no `updateInterest()` calls scattered throughout the codebase. The `waitTriggers` loop is the sole authority on what the hardware is doing.
* **ABA Protection:** By using a 64-bit monotonic sequence (`crseqN`), the design ensures that if a file descriptor is closed and immediately reused by the OS, the poller will not confuse the new socket with the old one.
* **Memory Safety:** The indirection layer explicitly accounts for the movement of objects within Zig's `ArrayHashMap` structures.
