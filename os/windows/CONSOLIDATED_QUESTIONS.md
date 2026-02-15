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

### Q4.1: WSAStartup/WSACleanup Ownership
In production tofu on Windows, who owns WSAStartup/WSACleanup?

Recommended pattern (from Microsoft docs):
- Main thread start: call WSAStartup once
- Worker threads: use sockets freely, no extra init
- Main thread exit: after all threads finished, call WSACleanup once
- WARNING: Never call from DllMain (deadlock risk from loader lock)

Options:
1. **Application responsibility** — caller must init before creating Reactor
2. **Reactor.create() / Reactor.destroy()** — Reactor owns platform init
3. **Dedicated tofu.init() / tofu.deinit()** — separate platform init API

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
*Last Updated: 2026-02-15*
