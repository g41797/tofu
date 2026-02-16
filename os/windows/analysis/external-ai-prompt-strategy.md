# External AI Prompt Strategy: Windows PinnedState Design

**Date:** 2026-02-16
**Status:** FINALIZED

---

## 1. Q&A Record (User Directives)

**Q1: Scope of Response?**
*   **User Answer:** Full strategy. Design a complete, cohesive architecture.

**Q2: Synthetic Wakeup Validation?**
*   **User Answer:** YES. Explicitly ask the AI to validate if `NtSetIoCompletion` is the best mechanism for cross-thread notifications.

**Q3: Handling Non-Socket Handles?**
*   **User Answer:** Ignore. "Dumb" states do not exist. All handles are valid `\Device\Afd` sockets.

**Q4: OS Abstraction?**
*   **User Answer:** Strictly hidden. The Reactor loop remains OS-independent.

**Q5: The Non-Unique Value Problem (Recycling)?**
*   **User Answer:** This is the core issue. Sockets/Handles are reused by the OS. The AI must solve for "Handle Reuse" where a recycled handle's old completion interferes with a new connection.

---

## 2. Technical Context for External AI

### The "Incarnation" Race Condition
In a high-churn environment, Windows socket handles are recycled. 
1. **Handle 0x400 (Incarnation 1)** issues an `AFD_POLL`.
2. **Handle 0x400** is closed. `NtCancelIoFileEx` is called.
3. The kernel begins cancellation but has not yet posted to IOCP.
4. **Handle 0x400 (Incarnation 2)** is created for a new connection.
5. **Incarnation 2** issues a new `AFD_POLL`.
6. **Race:** The completion for **Incarnation 1** arrives. It points to `Handle 0x400`. Without a generation ID (MessageID), the Reactor cannot distinguish which connection this completion belongs to.

### Logic Constraints
* **Pinned Memory:** `IO_STATUS_BLOCK` and `AFD_POLL_INFO` must be heap-allocated and stable.
* **ApcContext Usage:** Use the stable heap pointer, not the numeric handle/ID.
* **Zombie Lifecycle:** Pinned memory must not be freed until the kernel confirms release via `STATUS_CANCELLED`.
* **Single-Threaded Invariant:** The Reactor thread owns all I/O. Foreign threads only interact via the Notifier.

---

## 3. Notifier Integration
The `Notifier` is the only cross-thread component.
* **Current Approach:** `NtSetIoCompletion` to inject a manual completion packet.
* **Question for AI:** Validate safety and efficiency of this "Synthetic Wakeup" vs. traditional socket-pair signaling.

---

## 4. Finalized External AI Prompt

**Role:** Expert Systems Architect (Windows Kernel/NT Internals), specializing in **Socket Internals and High-Concurrency Multithreading**.

**Objective:** Design a deterministic, single-threaded Reactor lifecycle for Windows using the undocumented `AFD_POLL` mechanism (`ntdll.dll`), specifically solving for "Incarnation Safety" in an environment where resource identifiers (Handles/IDs) are non-unique and frequently recycled.

**1. The "Incarnation Safety" Problem (The Core Challenge)**
On Windows, socket handles are non-unique over time; once closed, a handle (e.g., `0x400`) is immediately eligible for recycling by the OS for a new connection.
*   **The Race Scenario:** Connection A (Handle `0x400`) is closed, and `NtCancelIoFileEx` is invoked. Before the kernel posts the `STATUS_CANCELLED` completion, Connection B is created and assigned the same Handle `0x400`. Connection B then issues a new `AFD_POLL`.
*   **The Logic Question:** How do we guarantee that a completion packet arriving for "Handle 0x400" is never applied to the wrong connection? Validate the logic of using a **Stable Heap Pointer** (PinnedState) as the `ApcContext` combined with a **64-bit Generation ID** (MessageID) to uniquely identify the "incarnation" of the handle.

**2. The "Zombie" Lifecycle Logic**
In NT I/O, the kernel owns the memory buffers (`IO_STATUS_BLOCK`, `AFD_POLL_INFO`) until the IRP completes. 
*   **The Logic Question:** Define the formal state transition rules for a `PinnedState`. If a socket is removed from the active Reactor map while an I/O is pending, it must become a "Zombie." 
    *   What are the precise conditions for its final destruction? 
    *   How do we manage these "Zombies" to ensure the memory address is not recycled by the allocator until the kernel confirms it has released the IRP?

**3. The Synthetic Interrupt (Cross-Thread Notifier)**
The Reactor is single-threaded and sleeps in `NtRemoveIoCompletionEx`. We require a thread-safe way to wake it from other threads (e.g., for signaling).
*   **The Logic Question:** Validate the use of `NtSetIoCompletion` to inject a "Synthetic Completion Packet" into the port as a wakeup signal.
    *   Compare this to socket-pair signaling in terms of performance and lock-free characteristics. 
    *   How should the Reactor distinguish a "Kernel I/O Completion" from a "User-Space Synthetic Wakeup" without introducing branching overhead in the hot loop?

**4. Level-Triggered Emulation & Partial Drains**
The library operates on a "Desired Interest" model where interest is recalculated every loop.
*   **The Logic Question:** If we stop reading from a socket (due to memory backpressure) and thus do *not* re-arm `AFD_POLL_RECEIVE`, what happens when we eventually re-arm? 
    *   Does the `AFD` driver guarantee an immediate completion if data remained in the buffer from a previous cycle? 
    *   Describe the internal logic of the `AFD` driver regarding "existing readiness" vs. "new arrival" notifications.

**5. Initial State Logic**
A socket handle may exist in an "undefined" or uninitialized state before its first registration.
*   **The Logic Question:** How should the Reactor logic handle the transition from an uninitialized resource to its first `arm` call? Account for resources that are created but never armed, or closed before their first registration.

**6. Teardown Synchronization & Global Shutdown**
When the Reactor is destroyed, there may still be multiple "Zombies" with pending kernel IRPs.
*   **The Logic Question:** Design a "Safe Teardown" sequence for the Reactor.
    *   How do we ensure that no kernel-owned memory (`PinnedState`) is freed while the OS still has an active pointer, even during Reactor destruction?
    *   Should the teardown block until all `STATUS_CANCELLED` completions are drained, or is there a way to safely "abandon" these requests to the OS?

**OUTPUT FORMAT REQUIREMENT:**
Provide your entire response as a **single, comprehensive Markdown document** inside a single code block. Use standard Markdown artifacts (headers, tables, lists) for clarity. Do not provide a chain of multiple answers or mixed media; the output should be a professional technical specification ready for immediate copying and archiving.
