# Windows Port: Active Knowledge Base (Living Document)

---

## ⚠️ Maintenance & Synchronization Protocol
**Every AI agent interacting with this repository MUST adhere to these rules:**
1. **Read First:** On session start, read this file, `CHECKPOINT.md`, `spec-v6.1.md`, and the **Author's Directive** (Section 0) entirely.
2. **Update on Milestone:** Update the "Technical State" and "Next Steps" sections immediately upon completing a Phase or major refactor.
3. **Final Hand-off:** Before ending a session, update `CHECKPOINT.md` and this file's "Session Context & Hand-off" section.
4. **User Command:** If the user says "Sync KB", perform a full audit of these files against the current codebase state.

---

## 0. Author's Directive (MANDATORY READING)
*This section contains notes, requirements, and advice directly from the project author. AI agents must follow these instructions over any conflicting defaults.*

**Current Notes:**
- **Verification Rule (MANDATORY):** You MUST run all tests in BOTH `Debug` and `ReleaseFast` modes. Successful completion of a task requires:
    1. `zig build test` (Debug)
    2. `zig build test -O ReleaseFast` (ReleaseFast)
- **Cross-Platform Compilation (MANDATORY):** You MUST verify that the codebase compiles for both Windows and Linux before finishing a task. 
- **Architectural Approval (MANDATORY):** Any change to important architecture parts (e.g., changing the memory model, adding allocators to core structures like `Skt`, or shifting from IOCP to Sync Poll) MUST be explicitly approved by the author. Provide an explanation and intent for discussion before applying such changes.
- **Log File Analysis (MANDATORY):** Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.

---

**Current Version:** 021
**Last Updated:** 2026-02-16
**Current Focus:** Phase III — Windows Implementation (Stability Fixes)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using IOCP + AFD_POLL.
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven).
- **Core Challenge:** Resolving memory instability in the async Windows backend.

---

## 2. Technical State of Play
- **Windows Poller Implementation:** `waitTriggers` currently uses asynchronous `AFD_POLL` via IOCP.
- **CRITICAL BUG IDENTIFIED:** `std.AutoArrayHashMap` in `Reactor.zig` moves `TriggeredChannel` objects during growth/shrinkage. The Windows kernel holds pointers to these moving objects (`ApcContext` and `IoStatusBlock`), leading to memory corruption and panics.
- **APPROVED FIX:** "Indirection via Channel Numbers + Stable Poller Pool".
    - `io_status` and `poll_info` move from `Skt` to a stable pool inside `Poller`.
    - `ApcContext` will pass the `ChannelNumber` (ID) instead of a pointer.
    - completions will look up the `TriggeredChannel` by ID.
- **Build Status:** Compiles for Windows and Linux. Reconnect tests fail on Windows due to the identified instability.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-16, Gemini CLI):
- **Diagnosed Instability:** Traced random "union access" panics to `AutoArrayHashMap` memory moves.
- **Verified Sequential Logic:** Confirmed that while the reactor is single-threaded, memory moves are triggered by its own map operations.
- **Proposed & Approved Architecture:** Decoupled `TriggeredChannel` (moves) from Kernel State (must be pinned).
- **Updated Documentation:** `os/windows/analysis/doc-reactor-poller-negotiation.md` contains the full technical breakdown and examples.

### Current State:
- **Baseline Restored:** Reverted experimental synchronous polling. The code is ready for the stable pool implementation.
- **Tests Config:** `reactor_tests` are currently disabled on Windows to allow other tests to pass. Stability must be proven with `reactor_tests.test.handle reconnect single threaded` (1000 retries).

---

## 4. Next Steps for AI Agent
1.  **Refactor `Skt` Struct:** Remove `io_status`, `poll_info`, `is_pending`, and `expected_events`. Restore the "Thin Skt" abstraction.
2.  **Implement `PinnedState` Pool:** In `src/ampe/os/windows/poller.zig`, add a mechanism to store and retrieve pinned state (IO status blocks) by `ChannelNumber`.
3.  **Update `waitTriggers`:**
    - Pass `ChannelNumber` as `ApcContext`.
    - Use stable memory from the pool for `io_status` and `poll_info`.
4.  **Update `processCompletions`:**
    - Use the returned `ApcContext` (ID) to find the current `TriggeredChannel` in the Reactor's map.
5.  **Verification:** Re-enable reactor tests and run the reconnect stress test.

---

## 5. Conceptual Dictionary
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move while a kernel request is pending.
- **Indirection via ID:** Using `ChannelNumber` to find a moving object instead of using a direct pointer.
- **Thin Skt:** An abstraction where `Skt` is just a handle, not a container for polling implementation details.

---
