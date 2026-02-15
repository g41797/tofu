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

### Completed This Session (2026-02-15, Claude Code Agent — Notifier Refactoring + Collapse):
- **Notifier Refactoring (unified single file):**
  - Rewrote `src/ampe/Notifier.zig` as single unified file with `@This()` pattern and Skt fields.
  - Two comptime branches handle platform differences: (1) abstract sockets on Linux only, (2) connect ordering (Windows: `Skt.connect()` before `waitConnect()`; Linux: `waitConnect()` before `posix.connect()`).
  - Removed `initTCP`, unused `nats` import.
  - Initially split into facade+backends (`os/linux/Notifier.zig`, `os/windows/Notifier.zig`), then collapsed back after discovering only 2 trivial differences.
- **Consumer Updates:**
  - `triggeredSkts.zig`: `NotificationSkt` now takes `*Skt` instead of raw `Socket`. Fixed `Socket` type alias to `internal.Socket`.
  - `Reactor.zig`: `createNotificationChannel` passes `&rtr.ntfr.receiver` (Skt pointer). Assertion in `vchns` updated.
  - `tests/ampe/Notifier_tests.zig`: Uses `Notifier` directly (no `NtfrModule` indirection).
- **Windows Notifier Test Added** (`tests/os_windows_tests.zig`):
  - Includes `WSAStartup`/`WSACleanup` (required before any Winsock calls).
  - Tests init, send, recv via UDS socket pair.
- **Deleted Files:** `src/ampe/os/linux/Notifier.zig`, `src/ampe/os/windows/Notifier.zig` (collapsed into single file).
- **Future Tasks Recorded** in `CONSOLIDATED_QUESTIONS.md`:
  - Q4.2: Windows Poller `waitTriggers` implementation (AfdPoller-based).
  - Q4.3: Refactor Skt/poller shared types to facade pattern.
- **Verification Sequence (PASS):**
  - `Windows Debug build+test (10/10)` -> `Windows ReleaseFast build+test (10/10)` -> `Linux cross-compile`.

### Previous Session (2026-02-15, Gemini CLI - Architectural Review):
- **Analyzed External AI Review:**
  - Resolved concerns about "lost wakeups" and "backpressure deadlock" via architectural analysis.
  - Confirmed `AFD_POLL` Level-Triggered semantics make current design safe.
  - Produced `os/windows/analysis/ARCHITECTURAL_VERDICT.md` (Verdict: APPROVED).

### Current State:
- **Architecture VERIFIED & APPROVED.**
- Feasibility phase is officially CLOSED.
- **Notifier refactoring COMPLETE** — single unified file with comptime branches (not facade).
- Next: Production implementation of `Poller.waitTriggers` using AfdPoller (Q4.2).

---

## 4. Next Steps for AI Agent
1. **Production Windows Poller:** Implement `waitTriggers` in `src/ampe/os/windows/poller.zig` using `AfdPoller`. Handles ALL sockets including notification receiver. Reference: `os/linux/poller.zig` lines 107-111, 141-147.
2. ~~**Notifier Refactoring:**~~ **DONE** — Facade pattern established.
3. **Skt/Poller Facade Refactoring:** Refactor `Skt` and poller shared types to facade pattern (like Notifier). Currently `internal.zig` handles `Skt` with a manual switch.
4. **Phase III Transition:** Start building `WindowsReactor`.

---

## 5. Conceptual Dictionary
*Key terms used in coordination docs and source comments. See full definitions in [spec-v6.1.md](./spec-v6.1.md#8-glossary-of-architectural-terms).*

- **Declarative Interest:** Re-calculating "what we want" from business state every loop.
- **One-Shot / Re-arm:** Mandatory cycle for `AFD_POLL` to emulate persistent polling.
- **Level-Triggered (LT):** Safety net that ensures `AFD_POLL` completes if data is left in buffers.
- **Backpressure:** Stopping `AFD_POLL_RECEIVE` requests when memory is full.
- **Readiness-over-Completion:** Using IOCP to build a Reactor, not a Proactor.

---
