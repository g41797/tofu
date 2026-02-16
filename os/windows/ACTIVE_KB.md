# Windows Port: Active Knowledge Base (Living Document)

---

## Maintenance & Synchronization Protocol
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

**Current Version:** 025
**Last Updated:** 2026-02-16
**Current Focus:** Phase III — wepoll Integration & epoll Unification (Strategic Shift)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using `wepoll` (C library shim over AFD_POLL).
- **Mantra:** Unify Linux/Windows under the `epoll` model (Stateful Reactor).
- **Core Challenge:** Managing the transition from stateless `poll()` to stateful `epoll` without breaking Reactor OS-independence.

---

## 2. Technical State of Play
- **Strategic Pivot:** native IOCP/AFD_POLL implementation postponed. 
- **Intermediate Goal:** Use `wepoll` (C library) as a git submodule to reach parity quickly.
- **Linux Goal:** Migrate Linux backend to native `epoll`.
- **PinnedState Analysis:** Completed and saved (Gemini Verdict). This logic will be used when replacing `wepoll` with a native Zig shim later.
- **CI Status:** Windows GitHub CI disabled.
- **External AI Brief:** Created for "Incarnation Safety" and "Zombie Lifecycle" logic (for future native shim).

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-16, Gemini CLI — Strategic Shift):
- **Analyzed PinnedState plan** and identified critical ID-reuse race condition.
- **Created Gemini Verdict** document with "Zombie List" and "MessageID" safety logic.
- **Created External AI Brief** for high-level architectural review.
- **Decision:** Shift to `wepoll` submodule to unify Linux/Windows backends under `epoll` interface.
- **Disabled Windows CI** on GitHub.
- **Documented Migration Strategy** in `os/windows/analysis/wepoll-migration-strategy.md`.
- **No code changes made** to core logic yet.

---

## 4. Next Steps for AI Agent
1. **Linux epoll Migration:** Start implementing native `epoll` for Linux in `src/ampe/os/linux/poller.zig`.
2. **wepoll Submodule:** Add `wepoll` as a git submodule.
3. **Windows wepoll Backend:** Implement a new poller backend for Windows that calls the `wepoll` C API.
4. **Unified Poller Interface:** Ensure `Poll` struct hides the differences between real `epoll` and `wepoll`.

---

## 5. Conceptual Dictionary
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move while a kernel request is pending. Heap-allocated per channel, managed by Poller.
- **Indirection via ID:** Using `ChannelNumber` (u16) to find a moving object in `trgrd_map` instead of using a direct pointer. Cast: `u16 -> usize -> PVOID` for ApcContext.
- **Thin Skt:** An abstraction where `Skt` is just a handle + address + base_handle, not a container for polling implementation details (io_status, poll_info, is_pending, expected_events move to PinnedState).
- **Orphan Cleanup:** Freeing PinnedStates for channels that were removed while no AFD_POLL was pending (no cancellation completion will arrive). Done in `cleanupOrphans()` at start of `armFds()`.
- **Deferred Cleanup:** Freeing PinnedStates for removed channels in `processCompletions()` when the STATUS_CANCELLED completion arrives. Avoids use-after-free from kernel timing.

---
