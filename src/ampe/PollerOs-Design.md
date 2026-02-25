# PollerOs: Unified Cross-Platform Design

The `PollerOs` design is a high-performance synchronization engine that bridges the gap between stateless application logic and the stateful event-notification systems of modern operating systems (`epoll` on Linux, `wepoll` on Windows, `kqueue` on BSD/macOS).

---

## 1. Architectural Core: The Dual-Map Indirection

Standard `std.AutoArrayHashMap` usage in Zig is efficient but volatile; `swapRemove` operations relocate data in memory to maintain contiguity. This presents a conflict for stateful kernels which expect a stable token to identify a file descriptor.

**The Solution: Stable Sequence Indirection**

* **The Identity Map:** Maps a `ChannelNumber` to a `SeqN` (Sequence Number).
* **The Object Map:** Maps the `SeqN` to the `TriggeredChannel` object.
* **The Token:** The `SeqN` is a monotonic `u64`. It serves as the "User Data" passed to the OS kernel. Even if the `TriggeredChannel` moves in memory due to deletions, the `SeqN` remains constant for that channel's lifecycle, allowing a safe $O(1)$ reverse-lookup when the OS reports an event.

---

## 2. Platform Abstraction Layer

To support both pointer-sized handles (Windows `HANDLE`) and integer descriptors (Linux `fd_t`), `PollerOs` uses a unified abstraction layer.

### A. The Handle Type
The `handle` member is stored as `*anyopaque` for all stateful backends. This ensures sufficient space for 64-bit pointers on Windows while remaining compatible with integer casts on Linux.

### B. The `toFd` Helper
Because Windows `SOCKET` is a pointer and Linux `socket_t` is an integer, the `toFd` helper provides a type-safe conversion:
- **Windows:** Returns `usize` (@intFromPtr).
- **Linux:** Returns `i32` (@intCast).

### C. The `wepoll` Bridge
On Windows, `PollerOs` uses the `wepoll` C library (located in `src/ampe/os/windows/wepoll`) to provide an `epoll`-compatible API over Windows' native `AFD_POLL` mechanism.

---

## 3. The Reconciliation waitTriggers Loop

`waitTriggers` acts as a state synchronizer, ensuring interest is checked **only** during the loop.

### Phase A: State Reconciliation ($O(N)$)

1. **Iterate:** Visit every `TriggeredChannel`.
2. **Logic Probe:** Call `tc.tskt.triggers()` for logical intent.
3. **Internal Sync:** Initialize `tc.act` with internal triggers (e.g., `pool` readiness).
4. **Delta Check:** Compare interest against `tc.exp`.
5. **Kernel Sync:** 
   - **Stateful:** Issue `MOD` syscall if interests differ.
   - **Stateless (`poll`):** Populate `pollfd` vector.

### Phase B: The OS Wait

If internal triggers are already pending, the OS wait is performed with a **0 timeout** (non-blocking) to avoid delaying application logic.

### Phase C: Event Harvesting ($O(\text{triggered})$)

1. **Token Lookup:** Use `SeqN` to jump to `TriggeredChannel`.
2. **Bitmask Translation:** Translate raw OS flags into application-level `Triggers`.
3. **Accumulation:** OS triggers are `OR`-ed with existing internal triggers.

---

## 4. Lifecycle & Resource Management

- **Attach:** Generate `SeqN` -> `CTL_ADD` to kernel -> Insert into dual-map.
- **Delete:** `CTL_DEL` from kernel -> `tc.tskt.deinit()` -> Map cleanup.
- **Cleanup:** On Windows, uses `epoll_close` for the port handle; on Linux, uses `std.posix.close`.

---

## 5. Backend Comparison Matrix

| Feature | `.poll` | `.epoll` | `.wepoll` (Windows) |
| --- | --- | --- | --- |
| **Wait Efficiency** | $O(N)$ | $O(1)$ | $O(1)$ |
| **Handle Type** | `void` | `i32` (as pointer) | `HANDLE` (pointer) |
| **Socket Type** | `i32` | `i32` | `SOCKET` (pointer) |
| **Token Type** | Vector Index | `u64` | `u64` |

---

## 6. Design Guarantees

* **Incarnation Safety:** 64-bit monotonic `SeqN` prevents ABA issues if FDs are reused.
* **Backpressure Support:** Read interest is dropped if the message pool is full.
* **Zero Special Functions:** The loop is the sole authority on hardware state.
