# Reactor, Poller, and Triggered Sockets Negotiation

This document details the interaction model between the generic `Reactor`, the OS-specific `Poller`, and `TriggeredChannel` objects, highlighting the critical differences between Linux and Windows implementations and the architectural mismatch found in the Windows backend.

## 1. Reactor - Poller Negotiation: Linux (Reference)

The Linux implementation follows a **stateless, iterator-based pattern** that perfectly aligns with the `poll()` system call and the `Reactor`'s data structures.

### Data Flow
1.  **Storage:** `Reactor` stores `TriggeredChannel` objects in `trgrd_map` (`std.AutoArrayHashMap`).
2.  **Iteration:** `Reactor` passes an `Iterator` to `Poller.waitTriggers()`.
3.  **Build Set:**
    *   `Poller` iterates through *all* channels.
    *   It calls `tc.tskt.triggers()` to get the expected interest (`exp`).
    *   It rebuilds a fresh `std.ArrayList(pollfd)` (`pollfdVtor`) on every call.
    *   **Crucial:** No state is stored in the `TriggeredChannel` or `Skt` regarding the polling mechanism itself.
4.  **Wait:** `poll()` is called with the vector. This is a blocking call (or timeout).
5.  **Result Mapping:**
    *   `poll()` returns. The kernel has updated `revents` in the `pollfd` vector.
    *   `Poller` iterates the map *again* (implicitly assuming the map hasn't changed order, which guarantees hold on a single thread).
    *   It maps `revents` directly to `tc.act` (actual triggers).

### Key Characteristics
*   **Stateless Kernel Interface:** The kernel does not hold references to `Reactor` memory between `waitTriggers` calls.
*   **Pointer Stability Irrelevant:** Since the kernel interaction is synchronous and scoped to the function call, it doesn't matter if `TriggeredChannel` objects move in memory *between* loop iterations (e.g., due to map growth or `swapRemove`).

## 2. Reactor - Poller Negotiation: Windows (Current Issue)

The Windows implementation attempts to map this synchronous/stateless flow onto the **asynchronous/stateful `AFD_POLL` (IOCP)** model, revealing a fundamental conflict with the `Reactor`'s memory management.

### Data Flow
1.  **Storage:** Same as Linux (`std.AutoArrayHashMap`).
2.  **Iteration:** `Reactor` passes an `Iterator` to `Poller.waitTriggers()`.
3.  **Arming (Async State):**
    *   `Poller` iterates through channels.
    *   It calls `NtDeviceIoControlFile` (`IOCTL_AFD_POLL`) for interest.
    *   **State Storage:** It stores `poll_info` and `io_status` *inside* the `Skt` (which is inside `TriggeredChannel`).
    *   **Kernel Reference:** It passes the address of `skt.io_status` and the pointer to `tc` (`TriggeredChannel`) as `ApcContext` to the kernel.
4.  **Wait:** `NtRemoveIoCompletionEx` waits for completions.
5.  **Result Mapping:**
    *   IOCP returns a completion containing the `ApcContext` (the `tc` pointer) and writes status to `io_status`.
    *   `Poller` casts `ApcContext` back to `*TriggeredChannel` to update `tc.act`.

### The Fatal Flaw: Pointer Instability
The `Reactor` uses `std.AutoArrayHashMap` to store `TriggeredChannel` objects **by value**.

*   **Growth:** If the map grows, it reallocates, moving all `TriggeredChannel` objects to new memory addresses.
*   **Removal (`swapRemove`):** When a channel is removed, the map moves the *last* element into the vacant slot to keep the array packed.

**The Mismatch:**
The Windows kernel (`AFD.sys` / IOCP) holds **long-lived pointers** to these objects (`ApcContext` = `*TriggeredChannel`, `IoStatusBlock` = `&tc.tskt.io.skt.io_status`) across reactor loop iterations.

**Scenario:**
1.  Channel A (Index 0) is armed. Kernel has pointer `PtrA`.
2.  Channel B (Index 1) is removed (`swapRemove`).
3.  Channel C (Index 100) is moved to Index 1 (Address `PtrB`).
4.  **Corruption:**
    *   If Channel A completed, it's fine (if A didn't move).
    *   If Channel C (now at `PtrB`) was waiting, its pending IO request in the kernel still points to `PtrC`. When it completes, the kernel writes to `PtrC` (now garbage/freed/overwritten).
    *   If Channel A was moved (due to a resize), the kernel writes to the old `PtrA`.
    *   If we receive a completion for a channel that was moved, the `ApcContext` points to the old address. Accessing it causes a Use-After-Free or Invalid Memory Access (Panic).

## 3. Stateless vs. Stateful Memory Models

### Linux: The Stateless Model (`poll`)
On Linux, the `waitTriggers` operation is effectively "Fire and Forget" for the kernel.
1. **Rebuild:** The poller builds a fresh array of `pollfd` structs every loop.
2. **Call:** The `poll()` syscall is made.
3. **Finish:** The kernel fills the results and returns control.
4. **Cleanup:** The poller maps results back to `TriggeredChannel` and discards the array.
The kernel **never** holds a pointer to tofu memory after the syscall returns. If `TriggeredChannel` moves in memory between loop iterations, it doesn't matter because the next `poll()` will just use the new address or simply the constant File Descriptor (int).

### Windows: The Stateful Model (`AFD_POLL` via IOCP)
On Windows, `AFD_POLL` is an asynchronous completion-based mechanism.
1. **Arm:** We call `NtDeviceIoControlFile`.
2. **Registration:** We pass pointers to `IO_STATUS_BLOCK` and `AFD_POLL_INFO`.
3. **Persistent Pointers:** The Windows Kernel (`AFD.sys`) stores these physical memory addresses in its internal request queue.
4. **Pending State:** The request remains active while the Reactor continues to other tasks.
5. **Completion:** When an event occurs, the kernel **dereferences** the stored pointers to write the result.

**The "Pinned State" Requirement:**
Because the kernel can write to these addresses at any time, that memory must be **Pinned**—its address must remain constant until the completion is handled. 

## 4. The Conflict: AutoArrayHashMap

The `Reactor` stores `TriggeredChannel` objects **by value** in a `std.AutoArrayHashMap`. This structure is designed for cache-efficient iteration but is **inherently unstable** for pointers:
*   **Map Growth:** When the map hits capacity, it reallocates. *Every* address changes.
*   **swapRemove:** When a channel is closed, the map moves the *last* element into the vacancy. *That element's address changes.*

If an `AFD_POLL` is pending for a channel that moves, the Kernel is now pointing at:
1.  **Garbage:** If the map reallocated.
2.  **Wrong Object:** If a `swapRemove` moved a different channel into that memory slot.

This leads to the "union field access" panics: the poller receives a completion, follows the `ApcContext` pointer to what it *thinks* is a valid `TriggeredChannel`, but finds a deinitialized (`.dumb`) variant or total garbage.

## 5. Intent and Possible Directions

### Initial Intent (REJECTED)
My initial thought was to add an `allocator` to the `Skt` struct. This would allow each socket to heap-allocate its own `PinnedState` (the `IO_STATUS_BLOCK` and `AFD_POLL_INFO`) during `init`. Since the `Skt` would only hold a pointer to this heap memory, the `Skt` itself could move (inside the map) while the addresses held by the Kernel remained stable.
**Status:** Rejected by Author. `Skt` should remain a simple, allocator-free struct to preserve the existing abstraction.

### Possible Approved Directions (For Discussion)
Any solution must provide **Address Stability** for the data the Kernel touches without breaking the `tofu` architectural boundaries.

1.  **Stable Storage Pool in Poller:**
    The `Poller` struct (which already has an allocator) could maintain a private pool of `PinnedState` objects. When a socket is registered, the poller assigns it a slot in this stable pool. The `ApcContext` would point to the pool slot, not the `TriggeredChannel`.
    *   *Pros:* `Skt` and `TriggeredChannel` remain OS-independent and value-typed.
    *   *Cons:* Requires mapping between Sockets and Pool slots.

2.  **Indirection via Channel Numbers:**
    Instead of passing pointers as `ApcContext`, we pass the `ChannelNumber` (as an integer cast to a pointer). Upon completion, we look up the *current* address of the `TriggeredChannel` in the `Reactor.trgrd_map`.
    *   *Pros:* Completely immune to memory moves.
    *   *Cons:* `IO_STATUS_BLOCK` still needs a stable home. The kernel *must* write to a pointer. We still need a stable place to store the status block for every pending request.

3.  **Segmented Map/Stable Pointers in Reactor:**
    Change how the Reactor stores channels (e.g., store `*TriggeredChannel` or use a structure that doesn't move elements).
    *   *Pros:* Solves the problem at the root.
    *   *Cons:* Major architectural change to core `tofu` logic (Author approval mandatory).

## 6. Conclusion
The Windows port cannot proceed reliably until we have a stable home for the asynchronous state that the kernel requires. We must decide on a mechanism that provides this stability while respecting the author's constraint on allocators in core structures.
