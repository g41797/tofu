# Windows Port: Active Knowledge Base (Living Document)

---

## ⚠️ Maintenance & Synchronization Protocol
**Every AI agent interacting with this repository MUST adhere to these rules:**
1. **Read First:** On session start, read this file, `spec-v6.1.md`, `master-roadmap.md`, and `decision-log.md` entirely.
2. **Update on Milestone:** Update the "Technical State" and "Next Steps" sections immediately upon completing a POC Stage or a major refactor.
3. **Update on Discovery:** If you find a technical blocker or a discrepancy in the source code, log it here immediately.
4. **Final Hand-off:** Before ending a session, update the "Session Context & Hand-off" section with a summary of work done and clear instructions for the successor.
5. **User Command:** If the user says "Sync KB", perform a full audit of these files against the current codebase state and Spec v6.1.

---

<!--
AI RESUME INSTRUCTIONS:
1. Read this file to understand the current state.
2. Read Spec v6.1.md (authoritative specification).
3. Read the Master Roadmap: ./master-roadmap.md
4. Read the latest QUESTIONS_XXX.md for developer dialogue.
5. Check the Decision Log for constraints: ./decision-log.md
6. Proceed to the "Next Steps for AI" section at the bottom.
-->

**Current Version:** 008
**Last Updated:** 2026-02-13
**Current Focus:** Phase I (Feasibility POC) — Stage 1 (Accept Test)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` (Zig messaging library) to Windows 10+ using IOCP + AFD_POLL while preserving the single-threaded Reactor pattern.
- **Environment:** Development is performed across two OSes: **Linux** (primary development and existing Reactor) and **Windows 10** (target platform and port implementation).
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven, no public callbacks).
- **Source of Truth:** 
    - [Spec v6.1](./spec-v6.1.md) — Consolidated authoritative specification
    - [Master Roadmap](./master-roadmap.md)
    - [Decision Log](./decision-log.md)

---

## 2. Technical State of Play
- **Stage 0 POC Complete:** Implemented `os/windows/poc/stage0_wake.zig` (IOCP creation, `NtSetIoCompletion`, and wakeup verified).
- **Module Infrastructure:** `os/windows/poc/poc.zig` created as `win_poc` module and integrated into `build.zig`. `tofu` module is now correctly imported by `win_poc`.
- **Test Infrastructure:** `tests/os_windows_tests.zig` now imports POCs via the `win_poc` module.
- **Build System:** `build.zig` correctly links `ws2_32`, `ntdll`, and `kernel32` for Windows targets.
- **Extended NT Bindings:** `os/windows/poc/ntdllx.zig` updated to include `extern` definitions for `CreateEventA`, `WaitForSingleObject`, and related constants from `kernel32.dll`.
- **AFD_POLL Logic Verified (Event-based):** The core logic for creating a listening socket, obtaining its base handle, issuing an `AFD_POLL_ACCEPT` request, and receiving its completion (via a manual reset event) has been successfully verified in `stage1_accept.zig`.
- **Spec Status:** Spec v6.1 released — all prior contradictions resolved, including precise re-arming rule for AFD_POLL.

---

## 3. Session Context & Hand-off

### Completed in Last Session:
- **`decision-log.md` updated:** Added rule about preferring Zig Standard Library for OS-independent functionality.
- **`stage1_accept.zig` refactored and debugged:**
    - Corrected Winsock initialization order (`WSAStartup`).
    - Implemented `SO_REUSEADDR` for the listening socket.
    - Switched from IOCP completion wait (`NtRemoveIoCompletionEx`) to a temporary event-based wait (`CreateEventA`, `WaitForSingleObject`) for `AFD_POLL` completion verification. This successfully isolated and confirmed the `AFD_POLL_ACCEPT` event triggering.
    - Updated `Skt.zig` and `SocketCreator.zig` to ensure `posix.socket` is used, as it handles cross-platform differences for sockets. This reverted previous `comptime if` changes.
    - Resolved module import conflicts by making `Skt` and `SocketCreator` public in `src/tofu.zig` and correctly importing `tofu` into `winPocMod` in `build.zig`.
    - Corrected syntax for `std.net.Address` unwrapping in `SocketCreator.zig`.
    - Defined `extern` bindings for `CreateEventA` and `WaitForSingleObject` in `ntdllx.zig` and linked `kernel32.lib` in `build.zig`.
    - Added `WSAStartup` and `WSACleanup` calls to the client thread to properly initialize Winsock for that thread, resolving the "Client socket creation failed" error observed in GitHub Actions.
    - Refactored server socket creation in `Stage1Accept.init()` to use `SocketCreator.fromAddress()`.
    - Refactored client socket creation in the client thread to use `SocketCreator.fromAddress()`.
    - Manually fixed client thread's `run` function return type (`!void`) and associated error handling.
    - Implemented Windows-specific `Skt.setLingerAbort()`.
    - Corrected `optlen` type in `Skt.setLingerAbort()` for Windows.
    - Addressed various compilation errors related to constants and types.
- **Stage 1 POC (Accept Test) now passes with event-based completion.** This confirms the successful setup and detection of an incoming connection via `AFD_POLL_ACCEPT`.

### Current Blockers:
- None.

### Files of Interest:
- `spec-v6.1.md` — Primary reference for all implementation details.
- `os/windows/poc/stage0_wake.zig` — Reference for IOCP wakeup.
- `os/windows/poc/stage1_accept.zig` — The working POC for AFD_POLL_ACCEPT.
- `analysis/003-feasibility.md` — Stage definitions (still useful for context).
- `src/ampe/Skt.zig` - Refactored for proper cross-platform socket handling via `std.posix`.
- `src/ampe/SocketCreator.zig` - Uses `std.posix.socket` for creating sockets.
- `os/windows/poc/ntdllx.zig` - Contains kernel32 function externs.

---

## 4. Next Steps for AI Agent
1. **Reintegrate IOCP for Stage 1 POC (Accept Test):**
   - In `os/windows/poc/stage1_accept.zig`, revert the temporary event-based waiting mechanism.
   - Restore `ntdllx.NtRemoveIoCompletionEx` for waiting on IOCP completion.
   - Ensure the `AFD_POLL` operation correctly posts its completion to the IOCP. This likely involves passing `self.iocp` and a `CompletionKey` to `ntdll.NtDeviceIoControlFile` instead of the event handle.
   - Remove the `event_handle` field, its creation, and its closing.
2. **Verify IOCP Completion:** Ensure `NtRemoveIoCompletionEx` successfully retrieves the completion packet for `AFD_POLL_ACCEPT`.
3. **Apply Spec v6.1 Re-arming Rule:** Once IOCP completion is verified, implement the re-arming logic for `AFD_POLL` immediately upon completion (before processing I/O) to keep the unprotected window minimal.
4. **Dialogue:** Update `QUESTIONS_003.md` (or create 004) with any new questions regarding `SIO_BASE_HANDLE`, AFD structures, or re-arming behavior.
5. **Hand-off:** After completing Stage 1, update this ACTIVE_KB.md and mark progress.
