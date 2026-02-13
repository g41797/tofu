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

**Current Version:** 009
**Last Updated:** 2026-02-13
**Current Focus:** Phase I (Feasibility POC) — Stage 2 (Echo)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` (Zig messaging library) to Windows 10+ using IOCP + AFD_POLL while preserving the single-threaded Reactor pattern.
- **Environment:** Development is performed across two OSes: **Linux** (primary development and existing Reactor) and **Windows 10** (target platform and port implementation).
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven, no public callbacks).
- **Source of Truth:**
    - [Spec v6.1](./spec-v6.1.md) — Consolidated authoritative specification
    - [Master Roadmap](./master-roadmap.md)
    - [Decision Log](./decision-log.md)
- **Mandatory Rules:** See Decision Log sections 5 (Git disabled — NEVER use git commands), 6 (Build & Test Commands), and 7 (Mandatory Testing & Verification Rule). Always run `zig build` before `zig build test`. Always Debug first, then ReleaseFast. Both must pass.
- **Completed Plan:** [Stage 1 IOCP Reintegration](./plan-stage1-iocp-reintegration.md) — implemented and verified (Decision Log section 9).

---

## 2. Technical State of Play
- **Stage 0 POC Complete:** Implemented `os/windows/poc/stage0_wake.zig` (IOCP creation, `NtSetIoCompletion`, and wakeup verified).
- **Module Infrastructure:** `os/windows/poc/poc.zig` created as `win_poc` module and integrated into `build.zig`. `tofu` module is now correctly imported by `win_poc`.
- **Test Infrastructure:** `tests/os_windows_tests.zig` now imports POCs via the `win_poc` module.
- **Build System:** `build.zig` correctly links `ws2_32`, `ntdll`, and `kernel32` for Windows targets.
- **Extended NT Bindings:** `os/windows/poc/ntdllx.zig` updated to include `extern` definitions for `CreateEventA`, `WaitForSingleObject`, and related constants from `kernel32.dll`.
- **AFD_POLL Logic Verified (Event-based):** The core logic for creating a listening socket, obtaining its base handle, issuing an `AFD_POLL_ACCEPT` request, and receiving its completion (via a manual reset event) has been successfully verified in `stage1_accept.zig`.
- **AFD_POLL via IOCP Verified:** `stage1_accept_integrated_iocp.zig` confirms that AFD_POLL completions post directly to IOCP when `Event=null` and `ApcContext=non-null` are passed to `NtDeviceIoControlFile`. `NtRemoveIoCompletionEx` successfully retrieves the completion with correct `ApcContext` and `Events=0x80` (AFD_POLL_ACCEPT). Verified in both Debug and ReleaseFast.
- **Spec Status:** Spec v6.1 released — all prior contradictions resolved, including precise re-arming rule for AFD_POLL.

---

## 3. Session Context & Hand-off

### Completed in Current Session:
- **IOCP-integrated accept test implemented:** Created `os/windows/poc/stage1_accept_integrated_iocp.zig` as a separate file (event-based `stage1_accept.zig` preserved untouched). Key differences: no event handle, `Event=null` + `ApcContext=@ptrCast(&io_status_block)` in `NtDeviceIoControlFile`, wait via `NtRemoveIoCompletionEx` with 10-second timeout. Successfully receives `AFD_POLL_ACCEPT` (0x80) via IOCP in both Debug and ReleaseFast modes.
- **Test infrastructure updated:** Added `stage1_iocp` import in `poc.zig` and new test in `os_windows_tests.zig`.
- **Decision Log Section 8.2 validated:** ApcContext non-null rule confirmed working — the returned `FILE_COMPLETION_INFORMATION.ApcContext` matches the pointer passed to `NtDeviceIoControlFile`.

### Completed in Prior Sessions:
- **Analysis of `Skt.accept()` and `Skt.connect()` confirmed:** Both functions correctly support Linux and Windows through their underlying `posix` implementations (`posix.system.connect`, `windows.accept`) and platform-specific error handling.
- **Architectural divergence noted:** The `iocp-reactor-complete-analysis-001.md` document strongly advocates for `AcceptEx` (Proactor model) for connection acceptance, while the current POC uses `AFD_POLL_ACCEPT` (Reactor-like readiness). This highlights a key architectural decision point for future phases.
- **Critical bug fixed in `stage1_accept.zig`:** Separate input/output buffers for `NtDeviceIoControlFile(AFD_POLL)` caused the output buffer to never be populated. Fixed by using same buffer for both.
- **Stage 1 POC (Accept Test) event-based completion verified.**
- **Stage 0 POC (IOCP Wakeup) completed.**
- **Build system, module infrastructure, and extended NT bindings established.**

### Current Blockers:
- None.

### Files of Interest:
- `spec-v6.1.md` — Primary reference for all implementation details.
- `os/windows/poc/stage0_wake.zig` — Reference for IOCP wakeup.
- `os/windows/poc/stage1_accept.zig` — The working POC for AFD_POLL_ACCEPT (event-based).
- `os/windows/poc/stage1_accept_integrated_iocp.zig` — IOCP-integrated AFD_POLL_ACCEPT POC.
- `analysis/003-feasibility.md` — Stage definitions (still useful for context).
- `src/ampe/Skt.zig` - Refactored for proper cross-platform socket handling via `std.posix`.
- `src/ampe/SocketCreator.zig` - Uses `std.posix.socket` for creating sockets.
- `os/windows/poc/ntdllx.zig` - Contains kernel32 function externs.

---

## 4. Next Steps for AI Agent
1. **Stage 2 POC (Full Echo):** Implement a complete echo server/client test that exercises the full IOCP + AFD_POLL lifecycle:
   - Accept a connection via IOCP-driven AFD_POLL_ACCEPT.
   - Perform async read/write on the accepted connection using AFD_POLL_RECEIVE/AFD_POLL_SEND.
   - Implement AFD_POLL re-arming immediately upon completion (before processing I/O) per Spec v6.1.
   - Verify data round-trip (client sends data, server echoes it back).
2. **Memory ownership for AFD_POLL_INFO:** Finalize during Stage 2 (Decision Log Section 4).
3. **Completion key design:** Finalize during Stage 2 (Decision Log Section 4).
4. **Hand-off:** After completing Stage 2, update this ACTIVE_KB.md and mark progress.
