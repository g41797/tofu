# Reactor-over-IOCP Master Roadmap

**Project:** tofu Windows 10+ Port (IOCP/AFD_POLL)
**Date:** 2026-02-12
**Status:** Phase I Execution

---

## 1. Project Goal
Port the `tofu` messaging library from Linux (POSIX poll) to Windows 10+ by implementing a native **Windows Reactor** using I/O Completion Ports (IOCP) and `AFD_POLL` for readiness notification. This maintains `tofu`’s single-threaded, queue-based architecture while leveraging high-performance Windows kernel primitives.

---

## 2. Technical Documentation Index
This roadmap coordinates the authoritative specification and supporting records:

1.  **[Consolidated Specification (v6.1)](./spec-v6.1.md)**
    *   *The authoritative source of truth.* Resolves all prior architectural contradictions.
2.  **[Decision Log](./decision-log.md)**
    *   *Focus:* Consolidated constraints and architectural choices.
3.  **Superseded Analysis Documents (Historical Context Only):**
    *   [Architecture Analysis (001)](./analysis/001-architecture.md)
    *   [Refactoring Guide (002)](./analysis/002-refactoring.md)
    *   [Feasibility & POC Plan (003)](./analysis/003-feasibility.md) (Stage definitions remain valid).

---

## 3. Execution Strategy (The Phased Path)

### Phase I: Feasibility (POC)
**Location:** `/os/windows/poc/`
**Goal:** Prove `AFD_POLL` re-arming and `NtSetIoCompletion` wakeup logic works in Zig 0.15.2.
*Status:* Stage 0 (Wakeup) Complete. Stage 1 (Accept) Complete — both event-based and IOCP-integrated verified. Stage 2 (Echo) next.

### Phase II: Structural Refactoring
**Location:** `src/ampe/`
**Goal:** Prepare the codebase for multiple OS backends.
*   Extract `poller.zig` into a platform-agnostic facade.
*   Move Linux `poll` logic to `os/linux/`.
*   Implement `Notifier.zig` abstraction (Windows uses IOCP posting).

### Phase III: Windows Implementation
**Location:** `src/ampe/os/windows/`
**Goal:** Implement the production-grade `WindowsReactor`, `Poller`, and `Notifier`.
*   Apply the "Working Knowledge" gained from the Phase I POCs and Spec v6.1.

### Phase IV: Verification
**Goal:** Parity testing.
*   Run the existing `tests/ampe/` suite on Windows.

---

## 4. Architectural Verdict
The project is **feasible**. The Reactor pattern in `tofu` is well-isolated enough that a Windows-native backend can be swapped in without a total system rewrite, provided the `Poller` and `Notifier` abstractions are correctly refactored first, following the **v6.1 Specification**.

*End of Roadmap*
