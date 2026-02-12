# Windows Port: Active Knowledge Base (Living Document)

---

## ⚠️ Maintenance & Synchronization Protocol
**Every AI agent interacting with this repository MUST adhere to these rules:**
1.  **Read First:** On session start, read this file, `master-roadmap.md`, and `decision-log.md` entirely.
2.  **Update on Milestone:** Update the "Technical State" and "Next Steps" sections immediately upon completing a POC Stage or a major refactor.
3.  **Update on Discovery:** If you find a technical blocker or a discrepancy in the source code, log it here immediately.
4.  **Final Hand-off:** Before ending a session, update the "Session Context & Hand-off" section with a summary of work done and clear instructions for the successor.
5.  **User Command:** If the user says "Sync KB", perform a full audit of these files against the current codebase state.

---

<!-- 
AI RESUME INSTRUCTIONS:
1. Read this file to understand the current state.
2. Read the Master Roadmap: ./master-roadmap.md
3. Read the latest QUESTIONS_XXX.md for developer dialogue.
4. Check the Decision Log for constraints: ./decision-log.md
5. Proceed to the "Next Steps for AI" section at the bottom.
-->

**Current Version:** 005
**Last Updated:** 2026-02-12
**Current Focus:** Phase I (Feasibility POC) - Stage 1 (Accept)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` (Zig messaging) to Windows 10+ using IOCP/AFD_POLL.
- **Mantra:** Maintain the single-threaded Reactor pattern.
- **Source Truth:** 
    - [Architecture Analysis](./analysis/001-architecture.md)
    - [Hard-coded Patterns](./analysis/002-refactoring.md)
    - [POC Roadmap](./analysis/003-feasibility.md)

---

## 2. Technical State of Play
- **Stage 0 POC Complete:** Implemented `os/windows/poc/stage0_wake.zig`.
- **Module Infrastructure:** Created `os/windows/poc/poc.zig` as a module root and added it to `build.zig` as the `win_poc` module to resolve "import outside module path" errors.
- **Test Infrastructure:** `tests/os_windows_tests.zig` now imports POCs via the `win_poc` module.
- **Build System:** `build.zig` now correctly links `ws2_32` and `ntdll` to both the library and test modules on Windows.

---

## 3. Session Context & Hand-off

### Completed in Last Session:
- Resolved Linux build error by moving Windows POCs into a formal Zig module (`win_poc`).
- Updated `build.zig` and `tests/os_windows_tests.zig` to use module-based imports.
- Ensured proper library linkage for test artifacts on Windows.
- Fixed "invalid byte" error in `stage0_wake.zig` caused by raw newlines in string literals.

### Current Blockers:
- None. Ready to begin Stage 1 POC (Accept Test).

### Files of Interest:
- `os/windows/poc/stage0_wake.zig`: The reference for IOCP wakeup.
- `analysis/003-feasibility.md`: For Stage 1 requirements.

---

## 4. Next Steps for AI Agent
1. **Initiate Stage 1 POC (Accept Test):**
    - Create `os/windows/poc/stage1_accept.zig`.
    - Use `AFD_POLL` to detect an incoming TCP connection.
    - Obtain the base socket handle using `SIO_BASE_HANDLE`.
    - Register for `AFD_POLL_ACCEPT` and verify completion.
2. **Success Criteria:** The IOCP returns a completion for the listener socket when a client connects.
3. **Dialogue:** Update `QUESTIONS_003.md` with any new technical questions regarding `SIO_BASE_HANDLE` or AFD structures.
*End of Active KB*
