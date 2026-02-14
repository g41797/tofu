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
- (Author: Add your notes, requirements, and advice here. These will be preserved across all AI sessions.)

---

**Current Version:** 014
**Last Updated:** 2026-02-13
**Current Focus:** Phase II — Structural Refactoring

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using IOCP + AFD_POLL.
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven).
- **Coordination:** Use `CHECKPOINT.md` for atomic state and `CONSOLIDATED_QUESTIONS.md` for unresolved queries.

---

## 2. Technical State of Play
- **Phase I Complete:** Proven that Reactor-over-IOCP is stable under stress.
- **Key Verified Findings:**
    - `AFD_POLL` + IOCP correctly emulates level-triggered Reactor semantics.
    - Optimal re-arming timing is **after** the non-blocking I/O call.
    - `ApcContext` reliably routes completion packets to socket-specific structures.
    - `NtCancelIoFile` enables safe asynchronous resource cleanup.
- **Zig 0.15.2:** Confirmed `std.ArrayList` requires explicit allocator passing for all operations.

---

## 3. Session Context & Hand-off

### Completed in Current Session:
- **Consolidated Questions:** Merged all `QUESTIONS_XXX.md` into `CONSOLIDATED_QUESTIONS.md`.
- **Infrastructure:** Added **Author's Directive** to `ACTIVE_KB.md`.
- **Rule Enforcement:** Updated `AI_ONBOARDING.md` with mandatory reading rules.

### Current Blockers:
- None.

---

## 4. Next Steps for AI Agent
1. **Modularize Poller:** Extract the existing POSIX `poll` logic from `src/ampe/poller.zig` into `src/ampe/os/linux/poller.zig`.
2. **Facade Implementation:** Update `src/ampe/poller.zig` to use `@import` based on `builtin.os.tag`.
3. **Windows Poller:** Implement production `src/ampe/os/windows/poller.zig`.
