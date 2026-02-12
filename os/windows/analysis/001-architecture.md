# Reactor-over-IOCP Analysis Report (001)

**Date:** 2026-02-12
**Subject:** Contradictions and Problem Analysis for tofu Windows Port
**Sources of Truth:** `/home/g41797/dev/root/github.com/g41797/tofu/` (src/ampe/*)
**Analyzed Documents:** `reactor-kb-001.md`, `reactor-over-iocp-prompt-005.md`, `reactor-questions-00*.md`

---

## 1. Executive Summary

This report identifies several key contradictions between the proposed Windows implementation plan and the existing `tofu` architecture. The most significant discrepancies relate to the assumed Linux notification mechanism (epoll vs. poll), the role of `updateReceiver`, and the alignment of the proposed callback-based API with tofu's internal queue-driven loop.

---

## 2. Identified Contradictions

### 2.1 Polling Mechanism: Poll vs. Epoll
- **Document Claim:** `reactor-kb-001.md` and `reactor-questions-002.md` state that tofu uses `epoll` on Linux.
- **Reality (Source Code):** `src/ampe/poller.zig` implements a `Poller` that uses `std.posix.poll`.
- **Impact:** The assumption that epoll-to-IOCP is the primary mapping is technically slightly off. Tofu currently uses the more portable `poll`, though the Reactor logic is structured to handle triggers similarly to epoll.
- **Fix:** Update documentation to acknowledge `poll` usage. The Windows implementation should still proceed with IOCP as it's the efficient choice for Windows, regardless of whether the Linux side uses `poll` or `epoll`.

### 2.2 Internal Signaling: Notifier vs. IOCP Posting
- **Document Claim:** `reactor-kb-001.md` suggests mapping `updateReceiver()` and cross-thread signals to `NtSetIoCompletion`.
- **Reality (Source Code):** `src/ampe/Notifier.zig` uses a loopback TCP/UDS socket pair. The Reactor thread polls the receiver end, and application threads write to the sender end via `submitMsg`.
- **Problem:** `NtSetIoCompletion` is an excellent replacement for a loopback socket on Windows, but `updateReceiver` in `MchnGroup.zig` currently only signals the *application* thread by pushing to its mailbox. It does not signal the Reactor.
- **Fix:** On Windows, the `Notifier` should be implemented using the Reactor's IOCP handle and `NtSetIoCompletion` for waking the Reactor loop. `updateReceiver` should remain focused on application-side signaling unless the intention is to also notify the Reactor of application-side state changes.

### 2.3 API Philosophy: Callback-based vs. Loop-driven
- **Document Claim:** `reactor-over-iocp-prompt-005.md` proposes a `ReadinessCallback` based API.
- **Reality (Source Code):** `Reactor.zig` implements an internal `loop` that iterates over `TriggeredChannel` objects, checking their `act` (actual triggers) and performing I/O.
- **Problem:** Introducing a new callback API at the Reactor level contradicts the existing architecture where the Reactor loop owns the logic for processing readiness.
- **Fix:** The Windows `Poller` implementation should populate the `Triggers` (notify, accept, connect, send, recv) within the existing `TriggeredChannel` structures, allowing the `Reactor.loop` to remain largely platform-agnostic.

---

## 3. Technical Problems & Risks

### 3.1 AF_UNIX Abstract Namespace
- **Reality:** `Notifier.zig`'s `initUDS` uses abstract namespaces (`socket_file[0] = 0`), which are Linux-specific.
- **Problem:** Windows 10 AF_UNIX support is limited and does not support abstract namespaces.
- **Fix:** Standardize on TCP loopback for the `Notifier` on Windows (as hinted in the `Notifier.zig` 2DO comments).

### 3.2 Command Injection Redundancy
- **Reality:** `Reactor.zig` already handles internal commands (create/destroy group) and messages using `SpecialMaxChannelNumber`.
- **Problem:** The proposed `Command` tagged union in the spec might introduce a redundant path for cross-thread communication.
- **Fix:** Integrate Windows "commands" into the existing `submitMsg` flow or use `NtSetIoCompletion` to smuggle `Message` pointers directly, matching the current `Notifier` behavior.

### 3.3 Re-arming Logic
- **Reality:** `poller.zig` (Poll) is level-triggered or re-calculated every loop iteration by `buildFds`.
- **Proposed:** AFD_POLL is explicitly one-shot.
- **Risk:** `Reactor.zig`'s loop might need adjustments to ensure re-arming happens at the correct time (after the non-blocking I/O is exhausted), rather than just relying on the next poll cycle's `buildFds`.

---

## 4. Proposed Fixes & Way Forward

### 4.1 Refactoring the Poller
- Introduce `src/ampe/poller/iocp.zig`.
- Update `poller.Poller` union in `src/ampe/poller.zig` to include an `.iocp` variant.
- Map `AFD_POLL` event flags to `triggeredSkts.Triggers`.

### 4.2 Windows-Native Notifier
- Implement a Windows-specific `Notifier` that does not use sockets but instead uses `NtSetIoCompletion` on the Reactor's IOCP.
- This fulfills the "Internal Socket" role without the overhead of the network stack.

### 4.3 Staged Integration
1.  **Refactor `poller.zig`**: Create the interface for different backend implementations.
2.  **Windows Notifier**: Create a version of Notifier that uses IOCP posting.
3.  **AFD_POLL Implementation**: Focus on getting readiness triggers into the `TriggeredChannel.act` field.
4.  **Parity Testing**: Use the existing `tests/ampe/` suite to verify that the `WindowsReactor` behaves identically to the Linux version.

---

## 5. Summary of Truth

| Feature | Current (Linux) | Proposed (Windows) | Action |
| :--- | :--- | :--- | :--- |
| **Backend** | `poll` (std.posix.poll) | IOCP + AFD_POLL | Implement IOCP in `Poller` union |
| **Wakeup** | Loopback Socket (Notifier) | `NtSetIoCompletion` | Native Notifier implementation |
| **Trigger Logic** | Readiness -> Loop -> I/O | Readiness -> IOCP -> Loop -> I/O | Align AFD_POLL with `Triggers` struct |
| **UDS** | Abstract Namespace | Regular Path / TCP | Use TCP loopback for Notifier |

*End of Report*
