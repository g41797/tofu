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

**Current Version:** 006  
**Last Updated:** 2026-02-12  
**Current Focus:** Phase I (Feasibility POC) — Stage 1 (Accept Test)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` (Zig messaging library) to Windows 10+ using IOCP + AFD_POLL while preserving the single-threaded Reactor pattern.
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven, no public callbacks).
- **Source of Truth:** 
    - [Spec v6.1](./spec-v6.1.md) — Consolidated authoritative specification
    - [Master Roadmap](./master-roadmap.md)
    - [Decision Log](./decision-log.md)

---

## 2. Technical State of Play
- **Stage 0 POC Complete:** Implemented `os/windows/poc/stage0_wake.zig` (IOCP creation, `NtSetIoCompletion`, and wakeup verified).
- **Module Infrastructure:** `os/windows/poc/poc.zig` created as `win_poc` module and integrated into `build.zig`.
- **Test Infrastructure:** `tests/os_windows_tests.zig` now imports POCs via the `win_poc` module.
- **Build System:** `build.zig` correctly links `ws2_32` and `ntdll` for Windows targets.
- **Spec Status:** Spec v6.1 released — all prior contradictions resolved, including precise re-arming rule for AFD_POLL.

---

## 3. Session Context & Hand-off

### Completed in Last Session:
- Released Spec v6.1 with clarified re-arming strategy and consolidated architecture decisions.
- All previous analysis documents (001–003) are now superseded by Spec v6.1.

### Current Blockers:
- None. Fully ready for Stage 1 POC.

### Files of Interest:
- `spec-v6.1.md` — Primary reference for all implementation details.
- `os/windows/poc/stage0_wake.zig` — Reference for IOCP wakeup.
- `analysis/003-feasibility.md` — Stage definitions (still useful for context).

---

## 4. Next Steps for AI Agent
1. **Initiate Stage 1 POC (Accept Test):**
   - Create `os/windows/poc/stage1_accept.zig`.
   - Create listener socket, obtain base handle via `SIO_BASE_HANDLE`.
   - Issue `AFD_POLL` with `AFD_POLL_ACCEPT`.
   - Verify completion packet is received when a client connects.
2. **Apply Spec v6.1 Re-arming Rule:** Re-arm AFD_POLL immediately upon completion (before processing I/O) to keep the unprotected window minimal.
3. **Success Criteria:** IOCP returns a completion for the listener socket on incoming connection.
4. **Dialogue:** Update `QUESTIONS_003.md` (or create 004) with any new questions regarding `SIO_BASE_HANDLE`, AFD structures, or re-arming behavior.
5. **Hand-off:** After completing Stage 1, update this ACTIVE_KB.md and mark progress.

*End of Active KB*
