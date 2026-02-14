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
- **Architecture:** All OS-dependent functionality must be refactored using a "comptime redirection" pattern.
- **Redirection Pattern:** Files like `Skt.zig`, `poller.zig`, and `Notifier.zig` in `src/ampe/` will act as facades that `@import` their respective implementations from `src/ampe/os/linux/` or `src/ampe/os/windows/`.
- **File Location:** All implementation and POC code must reside under `src/ampe/os/`. Specifically, Windows POCs and implementation now reside in `src/ampe/os/windows/`. The root `os/windows/` directory is strictly for documentation (`.md`).
- **Standard:** `ntdllx.zig` is located at `src/ampe/os/windows/ntdllx.zig`.
- **Workflow:** The next steps will likely be performed on Linux to establish the `os/linux/` backend and the facade structure.

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
- **Phase I (Feasibility) Complete:** Full parity between TCP and UDS verified on Windows using AFD Reactor pattern.
- **Key Verified Findings:**
    - `AFD_POLL` + IOCP correctly emulates level-triggered Reactor semantics for all socket types.
    - **UDS Base Handle Rule:** Accepted UDS sockets return a layered WinSock handle. You MUST call `SIO_BASE_HANDLE` before associating with an IOCP to avoid missing completion packets.
    - **Connect Precision:** UDS `connect()` on Windows requires a `namelen` of exactly `2 + path.len + 1`.
    - **Non-blocking connect:** `AF_UNIX` connect returns `WSAEWOULDBLOCK` similarly to TCP; re-arming for `AFD_POLL_OUT` or `AFD_POLL_CONNECT` is required.
- **Zig 0.15.2:** Confirmed `std.ArrayList` requires explicit allocator passing for all operations.

---

## 3. Session Context & Hand-off

### Completed in Current Session:
- **UDS Extension:** Expanded Stage 1U to include full Echo and Stress testing.
- **UDS Discovery:** Identified and documented the "Base Handle Rule" for accepted UDS connections.
- **Troubleshooting:** Successfully used the "Event Trick" to resolve a hang in the IOCP loop.
- **Final Sync:** All Phase I feasibility requirements are met.

### Current Blockers:
- None.

---

## 4. Next Steps for AI Agent
1. **Modularize Poller:** Extract the existing POSIX `poll` logic from `src/ampe/poller.zig` into `src/ampe/os/linux/poller.zig`.
2. **Facade Implementation:** Update `src/ampe/poller.zig` to use `@import` based on `builtin.os.tag`.
3. **Windows Poller:** Implement production `src/ampe/os/windows/poller.zig`.
