# Architectural Verdict: Windows Reactor Implementation

**Date:** 2026-02-15
**Status:** **APPROVED**
**Reference:** `os/windows/analysis/External-AI-Review-Brief.md`

---

## 1. Executive Summary
The proposed architecture for the `tofu` Windows port (IOCP + `AFD_POLL`) is **sound and feasible**. 
The concerns raised regarding "lost wakeups" and "backpressure deadlock" have been addressed through rigorous analysis of `AFD` semantics and the existing `tofu` codebase. No blocking issues remain.


The project should proceed with the current `poll()`-based Linux backend and the "One-Shot Level Triggered" Windows backend. Migration to `epoll` on Linux is **not recommended** at this stage.

---

## 2. Key Decisions & Rationale

### Decision 1: Affirm "Declarative Interest" Model
**Verdict:** The Reactor core will continue to compute desired interest from scratch on every loop iteration (Stateless).
**Rationale:**
-   **Linux:** Maps directly to `poll()`.
-   **Windows:** Maps cleanly to `AFD_POLL` (One-Shot).
    -   If interest is ON -> Issue `AFD_POLL`.
    -   If interest is OFF -> Do nothing.
    -   This avoids complex state synchronization required by stateful APIs like `epoll` or persistent IOCP associations.

### Decision 2: Confirm Safety of Backpressure Logic
**Verdict:** Disabling read interest while data remains buffered is **SAFE**.
**Rationale:**
-   `AFD_POLL` behaves as a **Level-Triggered** mechanism delivered via completion.
-   If we stop polling (backpressure) and later resume (re-arm), `AFD` checks the *current* buffer state.
-   Since data > 0, the `AFD_POLL_RECEIVE` request completes immediately.
-   **No lost wakeups.**

### Decision 3: Postpone Linux Epoll Migration
**Verdict:** Do not migrate to `epoll` until the Windows port is stable and optimized.
**Rationale:**
-   `poll()` is stateless, which aligns better with the current "recalculate every loop" architecture.
-   `epoll` is stateful. Adopting it would require implementing a "diffing" layer to translate declarative interest into `EPOLL_CTL_MOD` calls.
-   This adds unnecessary complexity during the critical Windows porting phase.

### Decision 4: Single-Threaded Constraint
**Verdict:** Strictly enforce the "Single Dedicated I/O Thread" rule.
**Rationale:**
-   This eliminates physical race conditions between `AFD_POLL` completion and interest changes.
-   The only "race" is logical (state machine), which is deterministic.

---

## 3. Implementation Guidelines for Phase III

1.  **Windows Poller (`src/ampe/os/windows/poller.zig`):**
    -   Must implement `waitTriggers` to:
        1.  Reap completions (`NtRemoveIoCompletionEx`).
        2.  Translate `AFD_POLL` flags to `tofu` Triggers.
        3.  **Critical:** If a socket has `recv` interest but no pending `AFD_POLL`, issue one immediately.
    -   **Optimization:** Batch `AFD_POLL` reissue to minimize syscalls? No, keep it simple first. One syscall per arm.

2.  **Notifier Refactoring:**
    -   Proceed with extracting `Notifier` to `os/windows/Notifier.zig` using IOCP `PostQueuedCompletionStatus` for signaling (instead of a self-connected socket).

3.  **Testing:**
    -   The "Partial Drain" scenario (Q5.2) should be added to `stage3_stress.zig` eventually to empirically prove the Level-Trigger logic, even though architecturally confirmed.

---

## 4. Final Answer to Review Questions

| ID | Question | Verdict |
| :--- | :--- | :--- |
| **Q1** | Backpressure/Re-arm Safe? | **YES** (Due to Level-Triggered nature of AFD) |
| **Q2** | Interest Derivation Model? | **YES** (Declarative is correct for this stack) |
| **Q3** | Linux Migration Timing? | **POSTPONE** (Stick with `poll` for now) |
| **Q4** | Readiness Emulation? | **CORRECT** (AFD_POLL + Re-arm = Level Triggered) |
| **Q5** | Lost Wakeup Risk? | **NONE** (Verified via semantics) |
| **Q6** | Cross-Platform Contract? | **SUFFICIENT** |

*End of Verdict*
