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
- **Windows ABI Rule (MANDATORY):** 
    - When building **on Linux** for Windows: Use the `gnu` ABI (`-Dtarget=x86_64-windows-gnu`).
    - When building **on Windows** for Windows: Use the `msvc` ABI (`-Dtarget=x86_64-windows-msvc`).
    - The `build.zig` automatically defaults to these based on the host if the ABI is not specified.
- **Cross-Platform Compilation (MANDATORY):** You MUST verify that the codebase compiles for both Windows and Linux before finishing a task.
- **Architectural Approval (MANDATORY):** Any change to important architecture parts (e.g., changing the memory model, adding allocators to core structures like `Skt`, or shifting from IOCP to Sync Poll) MUST be explicitly approved by the author. Provide an explanation and intent for discussion before applying such changes.
- **Log File Analysis (MANDATORY):** Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.

---

**Current Version:** 028
**Last Updated:** 2026-02-25
**Current Focus:** Phase III — wepoll Integration (Verification & Refinement)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using `wepoll` (C library shim over AFD_POLL).
- **Mantra:** Unify Linux/Windows under the `epoll` model (Stateful Reactor).
- **Core Challenge:** Managing the transition from stateless `poll()` to stateful `epoll` without breaking Reactor OS-independence.

---

## 2. Technical State of Play
- **Strategic Pivot:** native IOCP/AFD_POLL implementation postponed. 
- **Intermediate Goal:** Use `wepoll` (C library) as a git submodule to reach parity quickly.
- **Linux Goal:** Migrated Linux backend to native `epoll` (COMPLETED).
- **Windows Goal:** Integrated `wepoll` and established cross-platform build (COMPLETED).
- **Architecture:** Documented in `src/ampe/PollerOs-Design.md`.
- **Poller Logic:** Unified `PollerOs` handles both native `epoll` (Linux) and `wepoll` (Windows) using `*anyopaque` handles and `toFd` helper.
- **Build System:** `build.zig` automatically selects `gnu` ABI on Linux hosts and `msvc` on Windows hosts for Windows targets.
- **PinnedState Analysis:** Completed and saved (Gemini Verdict). This logic will be used when replacing `wepoll` with a native Zig shim later.
- **CI Status:** Windows GitHub CI disabled.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-25, Gemini CLI — wepoll Integration):
- **Integrated `wepoll`:** Added submodule to `src/ampe/os/windows/wepoll` and updated `build.zig` to compile `wepoll.c`.
- **Refactored Poller:** Updated `src/ampe/poller.zig` to use `*anyopaque` for handles and `usize` for Windows sockets, fixing pointer cast errors.
- **Unified Interface:** Implemented generic `toFd` and `isSocketSet` helpers to bridge `std.posix.fd_t` (Linux) and `SOCKET` (Windows).
- **Testing:** Verified "Sandwich Build" (Linux -> Windows/GNU -> Linux) and passed unit tests on Linux.
- **Cleanup:** Temporarily disabled outdated Windows POCs and UDS support on Windows to resolve build errors.

---

## 4. Next Steps for AI Agent
1. **Native Windows Verification:** Run `zig build test` on a real Windows machine to confirm runtime behavior of `wepoll` backend.
2. **Re-enable Windows Tests:** Once stable, uncomment and update `tests/os_windows_tests.zig` to use the new `Poller` API.
3. **Refine UDS Support:** Investigate correct target versions for Windows UDS support or finalize TCP-only Notifier for Windows.
4. **Cleanup:** Remove unused `src/ampe/os/linux/Skt.zig` if fully replaced by unified logic (or verify its role).

---

## 5. Conceptual Dictionary
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move while a kernel request is pending. Heap-allocated per channel, managed by Poller.
- **Indirection via ID:** Using `ChannelNumber` (u16) to find a moving object in `trgrd_map` instead of using a direct pointer. Cast: `u16 -> usize -> PVOID` for ApcContext.
- **Thin Skt:** An abstraction where `Skt` is just a handle + address + base_handle, not a container for polling implementation details (io_status, poll_info, is_pending, expected_events move to PinnedState).
- **Orphan Cleanup:** Freeing PinnedStates for channels that were removed while no AFD_POLL was pending (no cancellation completion will arrive). Done in `cleanupOrphans()` at start of `armFds()`.
- **Deferred Cleanup:** Freeing PinnedStates for removed channels in `processCompletions()` when the STATUS_CANCELLED completion arrives. Avoids use-after-free from kernel timing.

---
