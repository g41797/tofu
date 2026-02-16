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
    - Windows: `zig build -Dtarget=x86_64-windows`
    - Linux: `zig build -Dtarget=x86_64-linux`
- **Sandwich Verification (MANDATORY):** If changes are made to fix one platform, the other platform MUST be re-verified immediately. Sequence: `Success(A) -> Fix(B) -> Re-verify(A)`.
- **Log File Analysis (MANDATORY):** Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout.
- **Artifact Location (MANDATORY):** All temporary logs, build outputs, and session artifacts MUST be placed in `zig-out/`. Never pollute the project root.
- **Maximize Tofu/POSIX Abstraction (MANDATORY):** Use `tofu`'s existing abstractions (e.g., `Skt` methods) and follow the error handling patterns of the POSIX layer. Avoid direct `ws2_32` calls.
- **Architecture:** All OS-dependent functionality must be refactored using a "comptime redirection" pattern.
- **Redirection Pattern:** Files like `Skt.zig` and `poller.zig` in `src/ampe/` act as facades that `@import` their respective implementations from `src/ampe/os/linux/` or `src/ampe/os/windows/`. `Notifier.zig` uses comptime branches instead (only 2 trivial platform differences).
- **File Location:** All implementation and POC code must reside under `src/ampe/os/`. Specifically, Windows POCs and implementation now reside in `src/ampe/os/windows/`. The root `os/windows/` directory is strictly for documentation (`.md`).
- **Standard:** `ntdllx.zig` is located at `src/ampe/os/windows/ntdllx.zig`.
- **Workflow:** The next steps will likely be performed on Linux to establish the `os/linux/` backend and the facade structure.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.

---

**Current Version:** 019
**Last Updated:** 2026-02-15
**Current Focus:** Phase II — Structural Refactoring (Notifier complete, Poller next)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using IOCP + AFD_POLL.
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven).
- **Coordination:** Use `CHECKPOINT.md` for atomic state and `CONSOLIDATED_QUESTIONS.md` for unresolved queries.

---

## 2. Technical State of Play
- **Phase I (Feasibility) Complete:** Full parity between TCP and UDS verified on Windows.
- **Architectural Shift (Phase II) - STAGE 2 COMPLETE:**
    - **Backends:** `Skt`, `Poller`, and `Notifier` moved to `src/ampe/os/linux/` and `src/ampe/os/windows/`.
    - **Facades:** `src/ampe/poller.zig` uses `builtin.os.tag` switch pattern. `src/ampe/internal.zig` acts as the primary redirection point for `Skt`.
    - **Encapsulation:** `Skt` on Windows now holds the pinned `IO_STATUS_BLOCK` and `base_handle`.
    - **Notifier:** Single unified file (`src/ampe/Notifier.zig`) with comptime branches for 2 platform differences (abstract sockets, connect ordering). Stores `Skt` objects (not raw `socket_t`). UDS on both platforms. `NotificationSkt` in `triggeredSkts.zig` takes `*Skt`. `Socket` type fixed to `internal.Socket`.
- **Build & Verification Status:**
    - **Linux:** Compiles (cross-compile) — Sandwich Verification active.
    - **Windows:** ALL tests pass (POC Stages 0-3 + Notifier) in both **Debug** and **ReleaseFast** modes (11 tests total).
- **Log Management:** All outputs go to `zig-out/` log files.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-15, Gemini CLI — Windows Poller Implementation):
- **Implemented `Poller.waitTriggers` for Windows:**
  - Full production-grade implementation in `src/ampe/os/windows/poller.zig`.
  - Uses `AfdPoller` (IOCP + `AFD_POLL`) with "Declarative Interest" logic.
  - Sockets are armed/re-armed based on real-time business interest calculated in the loop.
  - Successfully handles `ApcContext` mapping completions back to `TriggeredChannel` objects.
- **Refactored Windows `Skt` State:**
  - Added pinned `poll_info` and tracking fields (`is_pending`, `expected_events`) to `src/ampe/os/windows/Skt.zig`.
- **Verified via New Unit Tests:**
  - Created `tests/windows_poller_tests.zig` with 2 tests:
    1. Basic wakeup via `Notifier`.
    2. Full TCP Echo flow (Connect -> Accept -> Recv -> Send).
  - All tests follow "Author's Directives" for coding style.
- **Verification Sequence (PASS):**
  - `Windows Debug build+test (12/12)` -> `Windows ReleaseFast build+test (12/12)` -> `Linux cross-compile (Build)`.

### Previous Session (2026-02-15, Claude Code Agent — Notifier Refactoring + Collapse):
- **Notifier Refactoring (unified single file):**
  - Rewrote `src/ampe/Notifier.zig` as single unified file with `@This()` pattern and Skt fields.
  - Two comptime branches handle platform differences (abstract sockets, connect ordering).

### Current State:
- **Phase II (Structural Refactoring) is now officially COMPLETE.**
- **Windows Poller `waitTriggers` is DONE and VERIFIED.**
- All 12 tests (POCs + Notifier + Poller) pass on Windows native.
- Next: Phase III — Implementation of `WindowsReactor` or integration into generic `Reactor.zig`.

---

## 4. Next Steps for AI Agent
1. **Phase III: Windows Implementation:** Start building the `WindowsReactor` or integrate the new `Poller.waitTriggers` into the main `Reactor.zig` loop logic.
2. **Skt Facade Refactoring (Q4.3):** Refactor `Skt` to use the same facade pattern as `Poller` (currently handled via a switch in `internal.zig`).
3. **Phase IV Verification:** Run the full `tests/ampe/` suite on Windows to ensure complete parity.

---

## 5. Conceptual Dictionary
*Key terms used in coordination docs and source comments. See full definitions in [spec-v6.1.md](./spec-v6.1.md#8-glossary-of-architectural-terms).*

- **Declarative Interest:** Re-calculating "what we want" from business state every loop.
- **One-Shot / Re-arm:** Mandatory cycle for `AFD_POLL` to emulate persistent polling.
- **Level-Triggered (LT):** Safety net that ensures `AFD_POLL` completes if data is left in buffers.
- **Backpressure:** Stopping `AFD_POLL_RECEIVE` requests when memory is full.
- **Readiness-over-Completion:** Using IOCP to build a Reactor, not a Proactor.

---
