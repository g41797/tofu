
# Windows AFD_POLL Reactor Design Specification

## 0. Scope and Objectives

This document specifies a deterministic, single-threaded Reactor lifecycle for Windows built on the undocumented `AFD_POLL` mechanism exposed via `ntdll.dll`. [file:1] It focuses on solving **incarnation safety** for recycled handles, safe management of kernel-owned IRP buffers, synthetic wakeups via I/O completion ports, level-triggered readiness emulation, initial state handling, and safe teardown. [file:1]

The design assumes:

- Single-threaded Reactor core, sleeping in `NtRemoveIoCompletionEx`.
- Cross-thread interaction only via completion port (no direct mutation of Reactor state from other threads).
- Each tracked socket is represented by a **PinnedState** structure whose address is stable for the lifetime of any in-flight IRP that references it. [file:1]

---

## 1. Core Data Structures and Invariants

### 1.1 PinnedState

Each logical connection or resource has an associated **PinnedState** allocated from a heap that never moves objects (no compaction, no relocation). [file:1] This structure is passed to the kernel as a stable context pointer (via `ApcContext` field, or equivalent) and carries a monotonically increasing 64‑bit **Generation ID**. [file:1]

Essential fields:

- `HANDLE socket_handle`
- `uint64_t generation_id`
- `uint64_t current_message_id` (optional sequence within generation)
- `AFD_POLL_INFO poll_info`
- `IO_STATUS_BLOCK iosb`
- `enum State { Uninitialized, Active, Zombie, Destroyed } state`
- Desired interest bits (read, write, error, hup, connect, accept, etc.)
- Reference counters:
  - `int irp_refcount` – number of in-flight IRPs referencing this PinnedState.
  - `int logical_refcount` – user-level ownership (Reactor map, user sessions, etc.).

**Invariants:**

- A PinnedState pointer that is currently referenced by an in-flight IRP must not be freed or recycled. [file:1]
- `generation_id` is incremented on each new **incarnation** of a logical resource that reuses the same PinnedState (e.g., re-binding, reconnecting, or handle recycling). [file:1]
- Any completion event must be validated against both the PinnedState pointer and its `generation_id` to ensure **incarnation safety**. [file:1]

### 1.2 Global Reactor State

The Reactor maintains:

- IOCP handle (completion port).
- Map: `HANDLE -> PinnedState*` (active resources).
- Global synthetic message sequence (optional).
- Shutdown flags and counters for pending Zombies.

All mutations of these structures occur only on the Reactor thread, except that other threads may call `NtSetIoCompletion` to post synthetic completions. [file:1]

---

## 2. Incarnation Safety

### 2.1 Problem Statement

On Windows, socket handles are non-unique over time and can be quickly recycled. [file:1] A typical race:

1. Connection A uses handle `0x400` and posts `AFD_POLL`.
2. A is closed, `NtCancelIoFileEx` is issued, but the IRP has not yet completed.
3. Connection B is created and receives the same handle `0x400`.
4. B posts a new `AFD_POLL` on the same numeric handle.
5. A delayed completion for A arrives on the IOCP with handle `0x400`.

Without additional information, the Reactor cannot distinguish which logical connection the completion belongs to. [file:1]

### 2.2 Stable Heap Pointer + Generation ID

To guarantee **incarnation safety**, we pair:

- **Stable pointer** to `PinnedState` (passed as completion context).
- **64‑bit `generation_id`** included in the IRP payload or bound to the IRP lifecycle.

Two practical approaches:

1. **Context-only encoding**:
   - Use the IOCP completion key or the overlapped/context pointer to carry the PinnedState pointer.
   - Compare `PinnedState.generation_id` (in-memory) against the generation implicitly associated with the posted operation (e.g., stored in `PinnedState` at post time and revalidated on completion).
2. **Explicit Message ID**:
   - At arm time, write `PinnedState.generation_id` into a field that is logically tied to the IRP, such as a `MessageID` field in a custom per-IRP context structure.
   - On completion, read context pointer → dereference PinnedState → compare the stored `MessageID` to current `generation_id`. [file:1]

### 2.3 Completion Validation Algorithm

For every completion:

1. Extract `PinnedState* ps` from completion key or `OVERLAPPED` / `ApcContext`.
2. If `ps == nullptr` → treat as **synthetic** (see Section 4) or error.
3. Load `ps->state`.
   - If `ps->state == Destroyed`, ignore completion (already fully torn down).
4. Compare the IRP’s associated `generation_id` (or message id) to `ps->generation_id`.
   - If mismatch → **stale completion** belonging to a prior incarnation:
     - Decrement `ps->irp_refcount`.
     - If `ps->state == Zombie` and `irp_refcount == 0` and `logical_refcount == 0`, free `ps`.
     - Do not dispatch to user logic.
   - If match → valid completion; process normally.

This guarantees that no completion is applied to the wrong logical connection, even when numeric handles are recycled. [file:1]

---

## 3. Zombie Lifecycle Logic

### 3.1 Definition

A **Zombie** is a PinnedState whose resource has been removed from the active Reactor map and logically closed, but which still has one or more pending IRPs referencing its memory. [file:1] The Reactor must guarantee:

- The PinnedState memory address remains valid until all IRPs complete or are canceled and their completions drained.
- The PinnedState is not visible in the active map for new lookups or reuse.

### 3.2 State Machine

States:

- `Uninitialized`: Allocated PinnedState, not associated with a valid socket handle.
- `Active`: Registered in Reactor map with a live handle; may have in-flight IRPs.
- `Zombie`: Removed from Reactor map; handle closed or treated as logically dead; may still have IRPs in flight.
- `Destroyed`: No IRPs in flight, no logical references; memory can be freed.

Transition rules:

1. **Uninitialized → Active**
   - Socket handle created, PinnedState bound, `generation_id` set.
   - Insert into Reactor map `handle -> ps`.
   - `state = Active`.

2. **Active → Zombie**
   - Triggered when user closes the socket, cancels interest, or unregisters from Reactor.
   - **Steps**:
     - Remove `handle -> ps` from Reactor map.
     - Close the underlying handle (optional order; see cancellation rules below).
     - Issue `NtCancelIoFileEx` (or equivalent) for any outstanding `AFD_POLL` on that handle; this may cause future `STATUS_CANCELLED` completions. [file:1]
     - Mark `ps->state = Zombie`.
   - `irp_refcount` remains tracking IRPs in flight.

3. **Zombie → Destroyed**
   - Condition: `irp_refcount == 0` and `logical_refcount == 0`.
   - On satisfaction, free PinnedState memory and mark `state = Destroyed` (or just free and avoid touching further).

4. **Active → Destroyed**
   - Only possible when no IRPs are in flight and the user logically drops the last reference without entering Zombie (e.g., cleaned up gracefully before unregister).
   - Typically still goes through Zombie for uniformity, but this is an optimization.

### 3.3 Reference Counting Rules

To ensure safe lifetime:

- Each posted IRP increments `irp_refcount` on `ps` before issuing the kernel call.
- On every completion (including `STATUS_CANCELLED`, `STATUS_END_OF_FILE`, errors), decrement `irp_refcount`.
- `logical_refcount` is incremented when Reactor or user code holds an external reference (e.g., session map, application-level object) and decremented when released.

Destruction rule:

- After decrementing either `irp_refcount` or `logical_refcount`, if `ps->state == Zombie` and both counters reach zero, free `ps`.

### 3.4 Preventing Memory Reuse

To ensure the allocator does not recycle the PinnedState address prematurely:

- Use an allocator that does not reassign the same address until explicitly freed.
- Only free `ps` in the Zombie → Destroyed transition when **all** IRPs have completed and their completions have been processed on the Reactor thread.

---

## 4. Synthetic Interrupt via NtSetIoCompletion

### 4.1 Rationale

The Reactor is single-threaded and sleeps in `NtRemoveIoCompletionEx`. [file:1] Other threads must wake it up for tasks such as:

- Submitting new registration/change requests.
- Initiating shutdown.
- Updating timers or backpressure state.

Using a socket-pair (self-pipe) is a common technique but adds kernel socket operations and pipeline complexity. [file:1] `NtSetIoCompletion` provides a direct, lock-free method to inject a completion packet into the IOCP. [file:1]

### 4.2 Synthetic Completion Packet Design

Define a **synthetic completion** structure:

- Completion key: a constant sentinel, e.g., `SYNTHETIC_KEY = 1`.
- `OVERLAPPED` / `ApcContext`: optionally null or a dedicated synthetic context pointer.
- `Status`: a status code indicating synthetic reason (e.g., `STATUS_USER_APC`, application-defined code, or `STATUS_SUCCESS` with encoded info in `Information` field).

Other threads post:

```c
NtSetIoCompletion(
    iocp_handle,
    (ULONG_PTR)SYNTHETIC_KEY,
    (ULONG_PTR)synthetic_context,  // optional
    STATUS_SUCCESS,
    0
);
```

On the Reactor thread, each completion is classified by completion key. [file:1]

### 4.3 Distinguishing Kernel vs Synthetic Without Branch Penalty

You can minimize branching in the hot path by structuring the completion dispatch as:

1. Read completion key.
2. Use a small, predictable dispatch table or mask to categorize:
   - `if (key == SYNTHETIC_KEY)` → synthetic handler.
   - Else → treat as real kernel I/O with a PinnedState pointer.

Given that most completions are expected to be real I/O events, ensure that synthetic key is a rare path and branch is highly predictable. Techniques:

- Choose a synthetic key distinct from any valid `PinnedState*` (e.g., low integer aligned differently).
- Use type tagging: for example, set low bits in completion key for synthetic messages and keep PinnedState pointers naturally aligned, so a single bit-test can classify. This allows:

```c
if (key & SYNTHETIC_TAG_BIT) {
    handle_synthetic(key);
} else {
    PinnedState* ps = (PinnedState*)key;
    handle_kernel(ps, ...);
}
```

This keeps the hot loop overhead minimal while preserving clear separation.

### 4.4 Performance Comparison vs Socket-Pair

- **Socket-pair signaling**:
  - Requires kernel-level read/write operations on a socket.
  - Competes with normal I/O, may incur additional buffering and socket state transitions.
- **NtSetIoCompletion**:
  - Directly posts to IOCP, avoiding extra socket machinery.
  - Fully lock-free at the user level, with the kernel managing queueing.
  - Naturally integrates with existing event loop without separate file descriptor.

Thus, NtSetIoCompletion-based synthetic completions are typically lower overhead and conceptually simpler for cross-thread wakeups in a single-threaded Reactor. [file:1]

---

## 5. Level-Triggered Emulation & Partial Drains

### 5.1 Desired Interest Model

The library recalculates a **Desired Interest** bitmask for each socket in every loop iteration, effectively emulating level-triggered behavior with `AFD_POLL`. [file:1] Instead of always re-arming, the Reactor may temporarily drop interest when backpressure occurs.

### 5.2 Scenario: Pausing Reads

Scenario:

- Data arrives on socket S, `AFD_POLL` completes with receive readiness.
- Reactor reads some, but not all, data and then stops reading due to memory backpressure.
- Reactor chooses not to re-arm `AFD_POLL_RECEIVE` until memory becomes available.

Question: When reads resume and `AFD_POLL_RECEIVE` is re-armed, will the AFD driver immediately report readiness if data remained in the socket buffer, or only on new arrivals? [file:1]

### 5.3 AFD Driver Readiness Semantics

Empirically and conceptually, `AFD_POLL` behaves as an edge-triggered notification mechanism layered over underlying level-triggered semantics: the driver determines readiness based on current buffer state and events. [file:1] When an application requests `AFD_POLL_RECEIVE`, if data is already buffered in the kernel at that time, the AFD driver will typically complete the IRP immediately to report readiness. [file:1]

Therefore, the Reactor can rely on:

- When `AFD_POLL_RECEIVE` is re-armed and data is already available, the completion should fire promptly without requiring new data arrival.
- This behavior allows level-triggered emulation: the application only re-arms when it is again interested, and the driver reports readiness based on current state.

### 5.4 Partial Drain Logic

To correctly emulate level-triggered behavior:

1. On receive readiness completion:
   - Attempt to **drain** available data until:
     - Kernel indicates `WSAEWOULDBLOCK` / no more data, or
     - Application-level backpressure threshold is reached.
2. Recalculate Desired Interest:
   - If application still wants more data and no backpressure, re-arm `AFD_POLL_RECEIVE`.
   - If backpressure is active, **do not** re-arm receive until buffer space is available.
3. When backpressure clears:
   - Re-arm `AFD_POLL_RECEIVE`.
   - Rely on AFD semantics to immediately complete if data is already queued.

This design maintains deterministic behavior without missing events: any data present when interest is re-established will cause a completion. [file:1]

---

## 6. Initial State Logic

### 6.1 Uninitialized Sockets

A socket handle may exist in an “undefined” or uninitialized state before its first registration with the Reactor. [file:1] Examples:

- The application creates a socket but never registers it.
- The socket is created and then closed before any `arm` call.

The Reactor must handle these consistently and safely.

### 6.2 PinnedState Allocation and Binding

Recommended approach:

- Allocate a PinnedState lazily on the first `arm` or `register` call.
- Before first arm:
  - `state = Uninitialized`.
  - `socket_handle` may be invalid.
  - Not present in Reactor map.
- On first arm:
  - Validate that the socket handle is still open and usable.
  - Set `generation_id` to a new value (e.g., random 64-bit or incrementing counter).
  - Insert into Reactor map as `Active`.
  - Post initial `AFD_POLL` according to Desired Interest.

### 6.3 Resources Created but Never Armed

For sockets created but never registered:

- The Reactor is not aware of them; no PinnedState is allocated.
- The application is responsible for closing them; no special handling is required.

### 6.4 Closed Before First Registration

If the application attempts to register a socket that is already closed:

- The Reactor should detect failure during initial `AFD_POLL` posting.
- Either fail the registration call or create a PinnedState that immediately transitions to Zombie and then Destroyed without ever entering the active map.

This avoids partially initialized entries and maintains a clean state machine.

---

## 7. Teardown Synchronization & Global Shutdown

### 7.1 Teardown Goals

When destroying the Reactor, there may still be multiple Zombies with pending kernel IRPs. [file:1] The design must ensure:

- No PinnedState memory is freed while any IRP may still reference it.
- No handle or completion port is closed prematurely while the kernel may still post completions referencing them.
- Optionally, allow bounded blocking for a clean shutdown.

### 7.2 Safe Teardown Sequence

Recommended sequence for `Reactor::destroy()` (executed on Reactor thread):

1. **Stop accepting new work**
   - Set a global `shutting_down` flag.
   - Reject new registrations/arms from user code.

2. **Cancel Active I/O**
   - For each `PinnedState* ps` in the Active map:
     - Remove `handle -> ps` from the map.
     - Mark `ps->state = Zombie`.
     - Issue `NtCancelIoFileEx` (or equivalent) for outstanding `AFD_POLL` / I/O on `ps->socket_handle`.
     - Optionally close `ps->socket_handle` after canceling I/O.

3. **Drain Completion Port**
   - While there exist any PinnedStates with `irp_refcount > 0`:
     - Call `NtRemoveIoCompletionEx` with a timeout (e.g., bounded wait).
     - For each completion:
       - Classify synthetic vs kernel.
       - For kernel completions, process as in Section 2.3, decrementing `irp_refcount` and transitioning Zombies to Destroyed as appropriate.
       - For synthetic completions, either ignore or handle outstanding user signals.

4. **Destroy Completion Port**
   - Once `irp_refcount == 0` for all PinnedStates and all PinnedStates with `logical_refcount == 0` are Destroyed, close the IOCP handle.

5. **Finalize**
   - Free any remaining non-Zombie resources (e.g., timers, heap pools).

This fully synchronous teardown ensures that all kernel references to user memory are gone before the allocator can reuse addresses.

### 7.3 Blocking vs Abandoning Requests

Blocking until all `STATUS_CANCELLED` completions are drained is the most conservative and safe option. [file:1] However, in some scenarios, you may want to bound shutdown time.

Possible strategy for **bounded blocking with safe abandonment**:

1. Perform steps 1–3 with a timeout budget (e.g., `X` milliseconds).
2. If, after this budget, some Zombies still have `irp_refcount > 0`:
   - Mark their PinnedStates as “abandoned” and keep them in a global list.
   - Keep the IOCP and relevant heap arenas alive in a small “reaper” thread that continues draining completions after Reactor destruction.
   - The main Reactor object returns from `destroy()` while the reaper ensures eventual free of abandoned PinnedStates.

This pattern decouples application lifecycle from OS cleanup latency while still preventing memory reuse until completions arrive.

Note: The completion port and backing memory must remain valid as long as the reaper is active.

---

## 8. Summary Table of PinnedState States

| State         | In Reactor Map | Handle Valid | IRPs In Flight | Allowed Transitions              |
|---------------|----------------|--------------|----------------|----------------------------------|
| Uninitialized | No             | Maybe        | 0              | Uninitialized → Active, Destroyed |
| Active        | Yes            | Yes          | ≥ 0            | Active → Zombie, Active → Destroyed (no IRPs) |
| Zombie        | No             | Maybe/No     | ≥ 0            | Zombie → Destroyed               |
| Destroyed     | No             | No           | 0              | None                             |

[file:1]

---

## 9. Example Reactor Loop Outline

A simplified outline of the main loop with all concepts applied:

```c
for (;;) {
    IO_COMPLETION_PACKET pkt;
    NTSTATUS status = NtRemoveIoCompletionEx(
        iocp_handle,
        &pkt,
        1,
        &num_removed,
        timeout,
        FALSE
    );

    if (status == STATUS_TIMEOUT) {
        if (shutting_down) break;
        continue;
    }

    ULONG_PTR key = pkt.CompletionKey;

    // Synthetic vs kernel
    if (key & SYNTHETIC_TAG_BIT) {
        handle_synthetic(key, pkt);
        continue;
    }

    PinnedState* ps = (PinnedState*)key;
    if (!ps) {
        // Unexpected; log and continue
        continue;
    }

    // Check generation / message ID
    uint64_t msg_generation = extract_generation_from_overlapped(pkt.Overlapped);
    if (msg_generation != ps->generation_id) {
        // Stale completion
        if (--ps->irp_refcount == 0 &&
            ps->state == Zombie &&
            ps->logical_refcount == 0) {
            free(ps);
        }
        continue;
    }

    // Valid completion
    process_afd_poll_completion(ps, &pkt);

    if (--ps->irp_refcount == 0 &&
        ps->state == Zombie &&
        ps->logical_refcount == 0) {
        free(ps);
    }
}
```

This loop integrates:

- Incarnation safety (generation check).
- Zombie lifecycle (refcounts and state transitions).
- Synthetic wakeups (tagged completion keys).
- Safe destruction rules.

[file:1]
```

[END OF FILE: all content shown]