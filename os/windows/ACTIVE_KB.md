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

**Current Version:** 010
**Last Updated:** 2026-02-13
**Current Focus:** Phase I (Feasibility POC) — Stage 3 (Stress & Cancellation)

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
- **Completed Plans:** 
    - [Stage 1 IOCP Reintegration](./plan-stage1-iocp-reintegration.md) — implemented and verified.
    - **Stage 2 Full Echo** — implemented and verified (Decision Log Section 8.4).

---

## 2. Technical State of Play
- **Stage 0 POC Complete:** Implemented `os/windows/poc/stage0_wake.zig` (IOCP creation, `NtSetIoCompletion`, and wakeup verified).
- **Module Infrastructure:** `os/windows/poc/poc.zig` created as `win_poc` module and integrated into `build.zig`. `tofu` module is now correctly imported by `win_poc`.
- **Test Infrastructure:** `tests/os_windows_tests.zig` now imports POCs via the `win_poc` module.
- **Build System:** `build.zig` correctly links `ws2_32`, `ntdll`, and `kernel32` for Windows targets.
- **Extended NT Bindings:** `os/windows/poc/ntdllx.zig` updated to include `extern` definitions for `CreateEventA`, `WaitForSingleObject`, and related constants from `kernel32.dll`.
- **AFD_POLL Logic Verified (Event-based):** The core logic for creating a listening socket, obtaining its base handle, issuing an `AFD_POLL_ACCEPT` request, and receiving its completion (via a manual reset event) has been successfully verified in `stage1_accept.zig`.
- **AFD_POLL via IOCP Verified:** `stage1_accept_integrated_iocp.zig` confirms that AFD_POLL completions post directly to IOCP when `Event=null` and `ApcContext=non-null` are passed to `NtDeviceIoControlFile`. `NtRemoveIoCompletionEx` successfully retrieves the completion with correct `ApcContext` and `Events=0x80` (AFD_POLL_ACCEPT). Verified in both Debug and ReleaseFast.
- **Stage 2 Full Echo Verified:** `stage2_echo.zig` implemented a complete echo server/client using IOCP + AFD_POLL. Verified end-to-end data round-trip, multiple socket handling (listener + connection), and re-arming logic. Verified in both Debug and ReleaseFast.
- **Decision Log Updated:** Memory ownership and completion key design finalized (Section 4). Re-arming timing refined to "After I/O" to avoid double completions (Section 2).

---

## 3. Session Context & Hand-off

### Completed in Current Session:
- **Stage 2 POC (Full Echo) implemented:** Created `os/windows/poc/stage2_echo.zig`. 
- **End-to-end verification:** Server accepts connection via `AFD_POLL_ACCEPT`, then echoes data via `AFD_POLL_RECEIVE`. Client connects, sends data, and receives echo.
- **Refined re-arming:** Demonstrated that re-arming AFTER I/O calls is efficient and avoids redundant completions.
- **Verified in both modes:** All Stage 0, 1, and 2 POCs pass in Debug and ReleaseFast.
- **Decision Log updated:** Finalized memory ownership (per-context ownership) and Completion Key design (Key 0 for I/O, Key 1 for Signals).

### Completed in Prior Sessions:
- **IOCP-integrated accept test implemented:** Created `os/windows/poc/stage1_accept_integrated_iocp.zig`.
- **Analysis of `Skt.accept()` and `Skt.connect()` confirmed.**
- **Architectural divergence noted** regarding `AcceptEx`.
- **Critical bug fixed in `stage1_accept.zig`** (same buffer for input/output).

### Current Blockers:
- None.

### Files of Interest:
- `os/windows/poc/stage2_echo.zig` — Full echo POC (current reference).
- `spec-v6.1.md` — Primary reference.
- `decision-log.md` — Technical constraints and finalized designs.

---

## 4. Next Steps for AI Agent
1. **Stage 3 POC (Stress & Cancellation):** Implement a POC that handles:
   - Multiple concurrent connections (e.g., 10-20).
   - Async connection cancellation via `NtCancelIoFileEx`.
   - Robust cleanup (closing handles, freeing context memory after completion).
2. **Phase II (Refactoring) preparation:** Start planning the extraction of `Poller` and `Notifier` facades in `src/ampe/`.
3. **Hand-off:** Update this ACTIVE_KB.md after Stage 3.
