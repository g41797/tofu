# Verdict: PinnedState Implementation Plan

**Author:** Gemini CLI
**Date:** 2026-02-16
**Subject:** Review of `claude-plan-pinned-state.md`

---

## Executive Summary

The proposed plan in `claude-plan-pinned-state.md` accurately identifies the root cause (pointer instability in `AutoArrayHashMap`) and correctly proposes heap-allocated `PinnedState` to provide stable memory for the Windows kernel. However, the plan contains a **critical vulnerability** in its choice of `ApcContext` and identifier-based lookup that could lead to memory corruption or event misrouting during rapid channel reuse.

---

## Critical Findings

### 1. Vulnerability: ChannelNumber Reuse Race
The plan proposes using `ChannelNumber` (u16) as the `ApcContext` for `NtDeviceIoControlFile`. 

#### The Technical Race Condition
While `ActiveChannels` (in `channels.zig`) maintains a "Recently Removed" buffer of 1024 IDs, this is a probabilistic defense, not a deterministic guarantee. In high-load scenarios (e.g., thousands of short-lived connections per second), it is possible to cycle through the entire ID space while a kernel `AFD_POLL` operation is still pending.

**Failure Step-by-Step:**
1. **Connection A** is assigned `ChannelNumber 42`.
2. **Reactor** arms `AFD_POLL` for `42`, passing `ApcContext = 42`.
3. **Connection A** is closed (e.g., peer disconnect). `closesocket` is called. The kernel begins canceling the pending `AFD_POLL`.
4. **Reactor** continues its loop. Because of high churn, `ChannelNumber 42` is reused for **Connection B**.
5. **Reactor** arms a *new* `AFD_POLL` for **Connection B** (using the new socket handle), also passing `ApcContext = 42`.
6. **Race Result:** The IOCP now potentially has TWO pending entries for `ApcContext 42` (the cancellation from A and the new poll from B).
7. **The Crash/Bug:** The completion for **Connection A** (likely `STATUS_CANCELLED`) arrives. The Poller receives `ApcContext 42`, looks up the *current* occupant of ID 42 (**Connection B**), and incorrectly applies the cancellation status or stale events to the new connection. This can lead to **Connection B** being closed prematurely or hanging because its actual "Ready" signal was masked by the stale completion.

#### Why the 1024-Number Gap is Not Enough

While a 1024-number gap (`rrchn`) sounds like a large buffer, it is insufficient for a deterministic high-performance reactor for several reasons:

1.  **High Connection Churn:** At 10,000 connections per second (common for microservices or stress tests), the 1,024-ID buffer is exhausted in **~100 milliseconds**. If a kernel `AFD_POLL` completion is delayed by just 0.1 seconds (due to scheduling, driver load, or network timeouts), the ID *will* be reused before the old completion is cleared.
2.  **Unpredictable Kernel Latency:** The Windows I/O Manager and the `AFD.sys` driver do not guarantee completion timing. A "stuck" I/O request (e.g., a socket in `FIN_WAIT_2` or a hardware-level delay) could keep an `AFD_POLL` pending for seconds, while the Reactor cycles through its entire 16-bit ID space (65,535) multiple times.
3.  **Scale vs. Buffer Size:** The buffer is fixed at 1024, but the load is variable. A safety mechanism that relies on "being fast enough to avoid a race" is a **probabilistic defense**, not a structural one. Tofu's architecture demands a **deterministic** guarantee that a completion *always* belongs to the socket that issued it.
4.  **The "Zombie" Problem:** When a socket is closed, its `AFD_POLL` is canceled, but the memory (`io_status`, `poll_info`) and the `ApcContext` must remain valid until the kernel actually posts the `STATUS_CANCELLED` completion to the IOCP. If we rely on the 1024-gap to "assume" the kernel is done, we risk a use-after-free if the kernel is slower than our reuse cycle.

#### Why Pointer Indirection is Safer
By using `*PinnedState` as the `ApcContext`:
- **Unique Memory:** Each connection attempt gets a unique heap-allocated `PinnedState`.
- **Deterministic Routing:** When a completion arrives, it points to the specific `PinnedState` created for that socket.
- **Validation:** By checking the `MessageID` inside the `PinnedState` against the `TriggeredChannel`, we can definitively detect if the completion belongs to the current "incarnation" of that ID.

#### The "Pointer" Confusion: Moving vs. Fixed Targets

It is important to distinguish between the **unstable pointer** used previously and the **stable pointer** proposed now:

1.  **Old Implementation (Broken):** Pointed to `TriggeredChannel` objects stored *inline* in `AutoArrayHashMap`. These objects **move** whenever the map resizes or performs a `swapRemove`. The pointer becomes dangling immediately upon any map mutation.
2.  **New Implementation (Proposed):** Points to a `PinnedState` object allocated via `allocator.create()`. This object is **pinned in memory** (on the heap) and its address is guaranteed never to change for its entire lifecycle, regardless of what happens to the HashMap.

By using the **stable heap pointer** as the `ApcContext` instead of an ID:
- We avoid the complexity and overhead of an ID-to-Pointer lookup in the completion loop.
- We achieve **Incarnation Safety**: Even if a `ChannelNumber` is reused, the pointer to the old `PinnedState` remains unique and valid until the kernel is finished with it.

#### The "Pointer Recycling" Risk (ABA Problem)

A valid criticism of using pointers is that memory addresses are recycled. If we `destroy` a `PinnedState` and then `create` a new one, the allocator may return the same address. If the kernel still had a pending I/O on that address, we would have a collision.

**The Tofu solution requires two layers of defense:**

1.  **Layer 1: The Zombie List (Physical Safety):** We must never call `allocator.destroy()` on a `PinnedState` while its `is_pending` flag is true. If a channel is removed, its `PinnedState` moves to a "Zombie" list. This keeps the memory address "reserved" so the allocator cannot give it to a new connection while the kernel still holds a reference. Only when the `STATUS_CANCELLED` completion arrives do we truly free the memory.
2.  **Layer 2: MessageID Verification (Logical Safety):** Even with Layer 1, a logic bug could lead to recycling. By storing the `mid: MessageID` (a unique 64-bit generation counter) in the `PinnedState`, we can verify every completion:
    ```zig
    if (state.mid != tc.acn.mid) {
        // This completion is for a previous connection that occupied this ChannelNumber.
        // It is a "stale" or "ghost" completion. Discard it.
        return;
    }
    ```

This combination makes the system **deterministic** and immune to the race conditions present in the original plan.

---

## 2. Suboptimal Indirection
Using `u16 -> usize -> PVOID` and then performing a `HashMap.get(chn)` lookup on completion is less efficient than using the pointer to the `PinnedState` itself. Since `PinnedState` is heap-allocated and stable, it is the ideal candidate for the `ApcContext`.

---

## Recommended Refinements (The "Safe Pointer" Approach)

### A. Use `*PinnedState` as `ApcContext`
Instead of casting the `ChannelNumber`, cast the `*PinnedState` to `PVOID`. This allows `processCompletions` to access the stable memory directly without a HashMap lookup.

### B. Implement Generation/Uniqueness Check
Add the `MessageID` (from `ActiveChannel.mid`) to the `PinnedState` struct.
```zig
pub const PinnedState = struct {
    io_status: windows.IO_STATUS_BLOCK = undefined,
    poll_info: ntdllx.AFD_POLL_INFO = undefined,
    is_pending: bool = false,
    expected_events: u32 = 0,
    chn: ChannelNumber, // Store for lookup
    mid: MessageID,     // Store for uniqueness check
};
```
In `processCompletions`, after retrieving the `tc` (TriggeredChannel) via `chn`, verify:
`if (tc.acn.mid != state.mid) continue; // Completion belongs to a previous occupant of this ID`

### C. Refined "Orphan" Management
When a channel is removed, the `PinnedState` should be decoupled from the "active" map but held in a "pending-cleanup" set if `is_pending` is true. This ensures that even if the ID is reused immediately, the *old* `PinnedState` remains alive until the kernel acknowledges cancellation, and the *new* connection gets a fresh `PinnedState` with a new `mid`.

---

## Verdict: Approved with Modifications

The plan is **Approved for Phase 0 (POC)** using the modified "Safe Pointer" approach. 
**Phase 1 (Production)** must incorporate the `MessageID` verification and the decoupled PinnedState lifecycle to be considered production-ready.

---

## Questions for Discussion
- See `os/windows/CONSOLIDATED_QUESTIONS.md` (Section 10) for specific technical queries arising from this review.
