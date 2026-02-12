# Reactor-over-IOCP Master Roadmap

**Project:** tofu Windows 10+ Port (IOCP/AFD_POLL)
**Date:** 2026-02-12
**Status:** Analysis Complete / Execution Pending

---

## 1. Project Goal
Port the `tofu` messaging library from Linux (POSIX poll) to Windows 10+ by implementing a native **Windows Reactor** using I/O Completion Ports (IOCP) and `AFD_POLL` for readiness notification. This maintains `tofu`'s single-threaded, queue-based architecture while leveraging high-performance Windows kernel primitives.

---

## 2. Technical Documentation Index
This roadmap coordinates the detailed analysis reports and decision records:

1.  **[Architecture Analysis (001)](./analysis/001-architecture.md)**
    *   *Focus:* Contradictions between project assumptions and source truth.
2.  **[Refactoring Guide (002)](./analysis/002-refactoring.md)**
    *   *Focus:* Hard-coded POSIX dependencies and recommended folder structure.
3.  **[Feasibility & POC Plan (003)](./analysis/003-feasibility.md)**
    *   *Focus:* Mandatory Proof-of-Concept (POC) gates.
4.  **[Decision Log](./decision-log.md)**
    *   *Focus:* Consolidated constraints and architectural choices.

---

## 3. Execution Strategy (The Phased Path)

### Phase I: Feasibility (POC)
**Location:** `/home/g41797/dev/root/github.com/g41797/tofu/os/windows/poc/`
**Goal:** Prove `AFD_POLL` re-arming and `NtSetIoCompletion` wakeup logic works in Zig 0.15.2.
*See [Analysis 003](./analysis/003-feasibility.md) for Stage 0-3 requirements.*

### Phase II: Structural Refactoring
**Location:** `src/ampe/`
**Goal:** Prepare the codebase for multiple OS backends.
*   Extract `poller.zig` into a platform-agnostic facade.
*   Move Linux `poll` logic to `os/linux/`.
*   Abstract `Notifier.zig` to allow a Windows implementation via IOCP packets.
*See [Analysis 002](./analysis/002-refactoring.md) for code snippets and advice.*

### Phase III: Windows Implementation
**Location:** `src/ampe/os/windows/`
**Goal:** Implement the production-grade `WindowsReactor`, `Poller`, and `Notifier`.
*   Apply the "Working Knowledge" gained from the Phase I POCs.
*   Adhere to `tofu`'s coding standards and memory safety rules.

### Phase IV: Verification
**Goal:** Parity testing.
*   Run the existing `tests/ampe/` suite on Windows.
*   Run the Echo Server demo.

---

## 4. Architectural Verdict
The project is **feasible**. The Reactor pattern in `tofu` is well-isolated enough that a Windows-native backend can be swapped in without a total system rewrite, provided the `Poller` and `Notifier` abstractions are correctly refactored first.

*End of Roadmap*
