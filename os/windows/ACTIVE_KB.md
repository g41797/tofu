# Windows Port: Active Knowledge Base (Living Document)

---

## ⚠️ Maintenance & Synchronization Protocol
**Every AI agent interacting with this repository MUST adhere to these rules:**
1. **Read First:** On session start, read this file, `CHECKPOINT.md`, `spec-v6.1.md`, `master-roadmap.md`, and `decision-log.md` entirely.
2. **Update on Milestone:** Update the "Technical State" and "Next Steps" sections immediately upon completing a Phase or major refactor.
3. **Update on Discovery:** If you find a technical blocker or a discrepancy in the source code, log it here immediately.
4. **Final Hand-off:** Before ending a session, update `CHECKPOINT.md` and this file's "Session Context & Hand-off" section.
5. **User Command:** If the user says "Sync KB", perform a full audit of these files against the current codebase state.

---

**Current Version:** 013
**Last Updated:** 2026-02-13
**Current Focus:** Phase II — Structural Refactoring

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using IOCP + AFD_POLL.
- **Phase I (Complete):** Proven that Reactor-over-IOCP is feasible and stable under stress.
- **Phase II (Active):** Refactoring `src/ampe` to support modular platform backends.

---

## 2. Technical State of Play
- **Phase I Verified Findings:**
    - `AFD_POLL` + IOCP correctly emulates level-triggered Reactor semantics.
    - Optimal re-arming timing is **after** the non-blocking I/O call.
    - `ApcContext` reliably routes completion packets to socket-specific structures.
    - `NtCancelIoFile` enables safe asynchronous resource cleanup.
- **Infrastructure Readiness:**
    - `ntdllx.zig` contains all necessary NT bindings for the production Reactor.
    - Build system correctly links system libraries (`ws2_32`, `ntdll`, `kernel32`).
- **Zig 0.15.2 Nuance:** `std.ArrayList` requires an explicit allocator for all operations, and `.init(allocator)` is the correct initialization pattern.

---

## 3. Session Context & Hand-off

### Completed in Current Session:
- **Phase I Completion:** Verified all stages including Stress & Cancellation.
- **Coordination Protocol:** Created `CHECKPOINT.md` and updated `AI_ONBOARDING.md` for multi-agent support.
- **Documentation Sync:** Updated `master-roadmap.md`, `Decision Log`, and `ACTIVE_KB.md`.

### Current Blockers:
- None.

---

## 4. Next Steps for AI Agent
1. **Modularize Poller:** Extract the existing POSIX `poll` logic from `src/ampe/poller.zig` into `src/ampe/os/linux/poller.zig`.
2. **Facade Implementation:** Update `src/ampe/poller.zig` to use `@import` based on `builtin.os.tag`.
3. **Windows Poller Implementation:** Implement the verified IOCP + AFD_POLL logic in `src/ampe/os/windows/poller.zig`.
4. **Abstract Notifier:** Update `src/ampe/Notifier.zig` to use OS-specific signaling mechanisms.
