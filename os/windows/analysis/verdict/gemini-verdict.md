Here is the complete architectural specification document, formatted as a single cohesive block for immediate use.

---

# Architecture Specification: Windows High-Concurrency Reactor (AFD_POLL/NTDLL)

**Version:** 1.0
**Target Subsystem:** Windows NT Kernel (6.x+)
**Driver Interface:** `AFD.sys` (Ancillary Function Driver) via `ntdll.dll`
**Concurrency Model:** Single-Threaded Reactor / Shared-Nothing

---

## 1. Incarnation Safety (Solving the Handle Recycling Race)

**The Problem:**
Windows `HANDLE` values are non-unique, temporal indices into a process handle table. If Socket A (Handle `0x400`) is closed, the OS may immediately assign Handle `0x400` to a new Socket B.

If the Reactor relies on the `HANDLE` value within a completion packet to identify a connection, a race condition exists:

1. Reactor cancels I/O for Socket A.
2. Socket A is closed; Handle `0x400` is freed.
3. Socket B is created; gets Handle `0x400`.
4. A delayed completion packet for Socket A arrives.
5. Reactor mistakenly applies the event to Socket B.

**The Solution: Stable Pinned Memory + Generation ID**
We must decouple the *identity* of the connection from the *OS Handle*.

1. **PinnedState Control Block:**
Every connection is assigned a heap-allocated struct (`PinnedState`) that is **pinned in memory** (never moved, never freed while I/O is pending).
2. **The APC Context Bridge:**
When invoking `NtDeviceIoControlFile` for `AFD_POLL`, we pass the **memory address** of `PinnedState` as the `ApcContext` (or `Key`). The OS ensures this exact pointer is returned in the `OVERLAPPED` entry upon completion.
3. **Validation Logic:**
When a completion arrives:
* We cast `entry->lpCompletionKey` (or `ApcContext`) back to `PinnedState*`.
* **Crucial:** We do *not* look up the `HANDLE`. We operate directly on the `PinnedState`.
* If the Handle was recycled, the `PinnedState` for the *old* connection is distinct from the `PinnedState` of the *new* connection. They are different memory addresses.


4. **64-bit Generation Guard:**
As a secondary defense against Allocator ABA problems (where the heap recycles the `PinnedState` address itself), the `PinnedState` contains a strictly monotonic `uint64_t GenerationID`. The central Reactor Map stores `Handle -> { PinnedState*, GenerationID }`. If the IDs do not match, the event is discarded as a ghost.

---

## 2. The "Zombie" Lifecycle (Memory Ownership & Safety)

In asynchronous NT I/O, the Kernel acts as a co-owner of the user-space memory buffers (`IO_STATUS_BLOCK`, `AFD_POLL_INFO`). Freeing memory while the Kernel holds a reference results in **Heap Corruption** (User Mode) or **BSOD** (Kernel Mode).

**The State Machine:**

* **State 1: Active (RefCount >= 2)**
* Socket is Open.
* 1 Reference held by the Reactor Map.
* 1 Reference held by the Pending IRP (Kernel).


* **State 2: Draining / "Zombie" (RefCount = 1)**
* **Trigger:** User calls `Close()`.
* **Action:**
1. Socket is removed from Reactor Map (User reference dropped).
2. `NtCancelIoFileEx` is issued to force IRP termination.
3. The `PinnedState` is flagged as `ZOMBIE`.


* **Invariant:** The memory is **NOT** freed yet. It exists solely to catch the completion packet.


* **State 3: Dead (RefCount = 0)**
* **Trigger:** Completion Packet arrives (usually `STATUS_CANCELLED` or `STATUS_SUCCESS`).
* **Action:**
1. Reactor decrements RefCount (Kernel reference dropped).
2. If RefCount == 0, `PinnedState` is passed to the allocator (`free`).





---

## 3. The Synthetic Interrupt (Cross-Thread Wakeup)

To wake the Reactor thread from a sleep state (`NtRemoveIoCompletion`), we require a thread-safe, high-performance interrupt.

**Mechanism: `NtSetIoCompletion**`
We avoid socket-pair signaling (which incurs TCP/IP stack overhead and context switches). instead, we inject a synthetic packet directly into the KQUEUE.

**The "Hot Loop" Optimization:**
To avoid branch misprediction penalties inside the critical loop, we distinguish "Wakeup" from "I/O" using the `CompletionKey`.

* **Socket I/O:** `Key` = `(uintptr_t)PinnedState` (Always > 0).
* **Wakeup/Signal:** `Key` = `0` (`NULL`).

**Poll Loop Logic:**

```cpp
// 1. Wait for event (Kernel Sleep)
status = NtRemoveIoCompletion(hIOCP, &key, &apc, &iosb, timeout);

// 2. Branchless-biased dispatch
if (LIKELY(key != 0)) {
    // Standard Path: Network I/O
    ((PinnedState*)key)->HandleCompletion(iosb);
} else {
    // Cold Path: Synthetic Wakeup
    // Process the specific signal (e.g., Shutdown, TaskQueue)
    ProcessCommandQueue(apc);
}

```

---

## 4. Level-Triggered Emulation & Partial Drains

The `AFD` driver supports behavior similar to Level-Triggering naturally, provided the correct logic is applied to the `AFD_POLL_INFO` structure.

**The Logic of "Existing Readiness":**

1. **Immediate Completion:** If `AFD_POLL_RECEIVE` is requested and the socket's internal kernel buffer is non-empty, `NtDeviceIoControlFile` will complete the IRP **immediately** (synchronously or instantly via IOCP). It does not wait for a "new" packet arrival.
2. **Backpressure Handling:**
* If the application stops reading (due to memory limits), the Reactor simply stops issuing `AFD_POLL_RECEIVE`.
* Data piles up in the Kernel Buffer (adjust `SO_RCVBUF` as needed).
* **Resume:** When the application resumes and issues a new `AFD_POLL_RECEIVE`, the driver detects the existing data and fires the completion immediately.


3. **Result:** No data is lost. We do not need to drain the socket to `EWOULDBLOCK` (Edge-Triggered style) to ensure safety.

---

## 5. Initialization State Logic

A resource transitions from "Cold" (Uninitialized) to "Hot" (Armed).

**The "Undefined" Gap:**
A socket may be created but never registered, or closed before registration.

* **Solution:** All `PinnedState` blocks are tracked in a `Global_Allocated_List` (Double Linked List) upon creation, distinct from the `Active_Poller_Map`.
* **Transition:**
1. `Socket Create`: Add to `Global_Allocated_List`. State = `IDLE`.
2. `Add Interest`: Issue `AFD_POLL`. State = `ARMED`.
3. `Close`: If `IDLE`, remove from Global List and free immediately. If `ARMED`, transition to `ZOMBIE`.



---

## 6. Teardown Synchronization (Global Shutdown)

Destroying the Reactor while I/O is pending is the most common cause of "Use-After-Free" crashes.

**Safe Teardown Sequence:**

1. **Phase 1: Barrier Up**
* Set atomic `ShutdownFlag = true`.
* Reject all new incoming connections or poll requests.


2. **Phase 2: Cancellation Storm**
* Iterate the `Active_Poller_Map`.
* For every active socket, issue `NtCancelIoFileEx`.
* **Do not close handles yet.** (Closing handles can race with the cancel logic; let the user own the handle lifecycle, the Reactor owns the I/O lifecycle).


3. **Phase 3: The Drain Loop (Mandatory)**
* The Reactor thread **must not exit**. It must continue looping `NtRemoveIoCompletion`.
* It will receive a flood of `STATUS_CANCELLED` packets.
* It processes these as standard `ZOMBIE` deaths (decrement RefCount -> free memory).


4. **Phase 4: Exit Condition**
* Maintain a global atomic `Pending_IRP_Count`.
* The loop terminates **only** when `Pending_IRP_Count == 0`.
* *Note:* If you exit before this, the OS will write to freed stack/heap memory when those IRPs eventually abort.



---

### Next Step

Would you like me to generate the **C++ struct definition** for the `PinnedState` and the specific `AFD_POLL_INFO` bitmask setup required to implement this?