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
3. Check the Decision Log for constraints: ./decision-log.md
4. Proceed to the "Next Steps for AI" section at the bottom.
-->

**Current Version:** 002 (Successor to reactor-kb-001)
**Last Updated:** 2026-02-12
**Current Focus:** Phase I (Feasibility POC) - Stage 0 (Wakeup)

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
- **Discovery Complete:** We have identified that `tofu` uses `std.posix.poll` on Linux and a socket-based `Notifier`.
- **Strategy Change:** We will replace the loopback socket `Notifier` with a native `NtSetIoCompletion` wakeup on Windows.
- **Feasibility Gate:** We are currently in the **POC Phase** to validate undocumented NT APIs before touching production `src/` code.

---

## 3. Session Context & Hand-off

### Completed in Last Session:
- Established the `/os/windows/` portfolio directory structure.
- Consolidated all discovery Q&A into `decision-log.md`.
- Refactored the Roadmap to align with the new directory structure.
- Archived the original `reactor-kb-001.md` to `reference/`.

### Current Blockers:
- None. Ready to begin Stage 0 POC.

### Files of Interest:
- `spec-base.md`: The original IOCP-as-Reactor specification.
- `analysis/003-feasibility.md`: The detailed stages for the POC.

---

## 4. Next Steps for AI Agent
1. **Initiate Stage 0 POC (Wakeup Test):**
    - Create `/home/g41797/dev/root/github.com/g41797/tofu/os/windows/poc/stage0_wake.zig`.
    - Implement a minimal loop using `NtCreateIoCompletion` and `NtRemoveIoCompletionEx`.
    - Prove that `NtSetIoCompletion` from a separate thread can unblock the loop.
2. **Success Criteria:** The loop must exit gracefully upon receiving a manual completion packet with a specific "Shutdown" key.

---
*End of Active KB*
