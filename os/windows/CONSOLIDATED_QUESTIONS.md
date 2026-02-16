# Windows Port: Consolidated Questions

This document tracks all unanswered technical and architectural questions for the tofu Windows port.

---

## 1. Phase I: Feasibility & POC (Current)

### Q1.1: Stage 3 Stress Parameters
For the Stage 3 Stress POC, how many concurrent connections should be tested to satisfy the feasibility requirement? Is the current target of 20 enough, or should we aim for a higher number (e.g., 100+)?

### Q1.2: NtCancelIoFile Reliability
During the Stage 3 POC, `NtCancelIoFileEx` returned `.NOT_FOUND`, while the base `NtCancelIoFile` worked but often returned `SUCCESS` immediately (meaning the operation completed before cancellation). 
- Should we continue investigating the `Ex` version's failure, or is the base `NtCancelIoFile` sufficient for our Reactor's needs?

### Q1.3: LSP Compatibility Examples
Can you provide examples of specific Layered Service Providers (LSPs) or environment configurations where `SIO_BASE_HANDLE` is known to fail? This will help in documenting unsupported environments.

---

## 2. Phase II: Structural Refactoring (Upcoming)

### Q2.1: Memory Management for Channels
In the production Reactor, should we use a pre-allocated pool of `Channel` structures (similar to the message pool) to avoid runtime allocations during the I/O loop?

### Q2.2: AF_UNIX Path Handling
Since Windows AF_UNIX requires a valid filesystem path (no abstract namespace), do you have a preferred directory for temporary socket files on Windows (e.g., `%TEMP%`)?

### Q2.3: Integration with `std.net`
To what extent should the Windows backend rely on `std.net` versus raw `ws2_32` calls? Our current strategy is "Standard Library First," but many Reactor-specific optimizations (like `SIO_BASE_HANDLE`) require raw WinSock.

---

## 3. General Project Coordination

### Q3.1: Minimum Functionality for MVP
What constitutes the absolute minimum "Working on Windows" milestone? 
- [ ] Reactor starts/stops
- [ ] Single TCP echo
- [ ] Multiple concurrent connections
- [+] Full parity with Linux test suite

---

## 4. Phase III: Production Integration

### Q4.1: WSAStartup/WSACleanup Ownership (RESOLVED)
In production tofu on Windows, who owns WSAStartup/WSACleanup?

**Verdict:** The `Reactor` owns it. `Reactor.create` initializes Winsock, and `Reactor.destroy` cleans it up. Tests using the Reactor MUST NOT initialize it manually.

---

## 5. Architectural Review Clarifications (External AI Review Brief)

### Q5.1: AFD_POLL Trigger Semantics (Level vs Edge)
**Question:** Has the "immediate firing on existing data" behavior been empirically verified?
**Answer:** **Yes (Architectural Confirmation).** `AFD_POLL` is inherently Level-Triggered (Condition Met). If `AFD_POLL_RECEIVE` is issued on a socket with buffered data, the I/O Manager completes the IRP immediately.
**Impact:** The "Backpressure/Re-arm" logic is **SAFE**. We will not lose wakeups if we disable read interest while data remains buffered.

### Q5.2: The "Partial Drain" Scenario
**Question:** If memory is full, does the Reactor **disable read interest** completely?
**Answer:** **Yes.** Code analysis of `src/ampe/triggeredSkts.zig` (`IoSkt.triggers`) confirms that when `recvIsPossible()` returns false (due to empty pool), `ret.recv` is NOT set. Consequently, the Linux backend removes `POLLIN`.
**Implication:** The Windows backend must mimic this by **NOT issuing** `AFD_POLL_RECEIVE` in this state.

### Q5.3: Concurrency Model Details
**Question:** Is the state change strictly serial?
**Answer:** **Yes.** All I/O and state logic runs on a single dedicated thread. There are no cross-thread race conditions regarding interest management.

### Q5.4: Epoll Motivation
**Question:** Migrate to epoll now?
**Answer:** **No.** Postpone. `poll()` (stateless) maps more cleanly to the "Declarative Interest" model than `epoll` (stateful). Migrating to `epoll` now would add unnecessary state-diffing complexity.

---

## 6. Notifier Refactoring (Socket vs. Native Signal)

### Q6.1: The "Notification" Payload in IOCP
On Windows, when using `NtSetIoCompletion` to signal the Reactor, should we pack the 8-bit `Notification` struct into the `CompletionKey` or `ApcContext`?
- **Option A:** Pack in CompletionKey. The Reactor gets the data immediately upon `NtRemoveIoCompletionEx` return.
- **Option B:** Emulate a socket. The Reactor sees a "Signal" and then must call a dummy `recv` to get the byte. (Less efficient, more similar to Linux).

### Q6.2: "Ready to Send" Semantic
Is the `isReadyToSend()` check strictly required for business logic (e.g., to throttle senders), or is it an artifact of socket buffer management? If it's a socket-only concern, the Windows (IOCP) backend will always return `true`.

### Q6.3: Interface Alignment
Should the `Notifier` interface be split into `Sender` and `Receiver` components? On Windows, the "Receiver" is just a registration on the IOCP, while on Linux it is a physical socket.

---

## 7. Notifier Refactoring (Socket-Pair & Poller Integration)

### Q7.1: Creation Refinement via `Skt` Facade
Should `Notifier.initTCP` be refactored to use the `Skt` abstraction (e.g., `listSkt.accept()`) instead of raw `std.posix` calls? 
- **Reason:** Ensures the `receiver_fd` is correctly configured for Windows (non-blocking, handle inheritance) without duplicating logic.

### Q7.2: Notifier as a `TriggeredChannel`
Should the Notifier's receiver socket be encapsulated in a `NotificationSkt` within the `TriggeredSkt` union?
- **Reason:** Allows the `Poller.waitTriggers` loop to process the Notifier handle generically alongside network sockets.

### Q7.3: Windows Re-arming for Notifier
Since `AFD_POLL` is one-shot, the Notifier's receiver must be re-armed. Should the Notifier have "Permanent Interest" (always armed for `RECEIVE`) to avoid deadlocks? 
- **Contrast:** Network sockets may have interest disabled for backpressure; the Notifier never should.

### Q7.4: Sender-side `poll` on Windows
The sender uses `poll` to check readiness. On Windows, this means `ws2_32.WSAPoll`. Is this acceptable for local-loopback signaling, or should we wrap the readiness check?

---

## 8. Future Tasks (Phase II Continuation)

### Q4.2: Windows Poller `waitTriggers` Implementation (DONE)
Implemented in `src/ampe/os/windows/poller.zig` using `AfdPoller` and `NtRemoveIoCompletionEx`. Verified via unit tests in `tests/windows_poller_tests.zig`. Handles ALL sockets including notification receiver.

### Q4.3: Refactor Skt/Poller Shared Types to Facade Pattern
Refactor Skt and poller shared types to use the facade pattern (like Notifier). Currently `internal.zig` handles Skt with a manual switch; this should follow the same `backend` + re-export pattern established by `Notifier.zig` and `poller.zig`.

---

## 9. Phase III: PinnedState Implementation

### Q9.1: SocketContext.arm() io_status Stack-Local Bug (IDENTIFIED)
`afd.zig` line 85: `var io_status: windows.IO_STATUS_BLOCK = undefined;` is a stack local passed to
`NtDeviceIoControlFile`. The kernel holds `&io_status` for async operations, but it goes out of scope
when `arm()` returns. Works in POC by luck (synchronous completion or stack not overwritten yet).
**Fix:** Move `io_status` to a struct field in `SocketContext`. Scheduled as Step 0a.

### Q9.2: PinnedState Memory Strategy (DECIDED)
**Phase 1:** Simple `allocator.create(PinnedState)` / `allocator.destroy(state)`. One heap allocation
per channel.
**Phase 2 (required for "ready"):** Block-based pool allocator. Allocate PinnedState objects in blocks
of ~128. Track per-block usage count. Free empty blocks.
**Decision:** Start simple, optimize later. Project not "ready" until block-based pool is implemented.

### Q9.3: base_handle Location (DECIDED)
`base_handle` stays in `Skt`. PinnedState does NOT store a reference to Skt. During `armSkt()`, the
`*Skt` pointer is obtained from TriggeredChannel in the same `armFds()` iteration (no map mutations
happen during this pass). PinnedState reads `skt.base_handle` once to populate `poll_info` and pass
to `NtDeviceIoControlFile`.

### Q9.4: PinnedState Deferred Cleanup (DECIDED)
When a channel is removed, `closesocket()` triggers kernel cancellation. Rather than freeing
PinnedState immediately (risk of kernel still writing to io_status), wait for STATUS_CANCELLED
completion in next `poll()` cycle, then free. Non-pending orphans cleaned up at start of `armFds()`.

### Q9.5: docs_site/docs/mds/ as Source of Truth (ADDED)
`docs_site/docs/mds/` added as source of truth for tofu channel semantics, message format, and
architectural overview. Key files: `channel-group.md`, `message.md`, `key-ingredients.md`,
`advanced-topics.md`.

---

## 10. Phase III: PinnedState Refinements (Gemini Review)

### Q10.1: ApcContext Collision Safety
Given that `ChannelNumber` can be reused, shouldn't we use the heap-allocated `*PinnedState` address as the `ApcContext` instead of the `ChannelNumber` itself? 
- **Benefit:** Direct access to context memory without HashMap lookup.
- **Verification:** Can we reliably use `MessageID` (mid) to detect completions belonging to a previous connection on the same ID?

### Q10.2: Decoupled PinnedState Lifecycle
If a channel is removed and its ID is immediately reused, how do we ensure the `PinnedState` for the *new* connection doesn't conflict with the pending `STATUS_CANCELLED` completion of the *old* one?
- **Proposed Solution:** Decouple `PinnedState` from the `ChannelNumber` map upon removal, but keep it alive in a "Zombie" list until the kernel posts the completion.

### Q10.3: SocketContext vs PinnedState in afd.zig
The current `afd.zig` uses a `SocketContext` struct. Should this struct be merged with the `PinnedState` used by the Poller to avoid duplicate definitions of kernel-facing memory (io_status, poll_info)?

---
*Last Updated: 2026-02-16*
