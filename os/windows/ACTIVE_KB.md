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
- **Verification Rule (MANDATORY):** You MUST run all tests in BOTH `Debug` and `ReleaseFast` modes. Successful completion of a task requires:
    1. `zig build test` (Debug)
    2. `zig build test -O ReleaseFast` (ReleaseFast)
- **Cross-Platform Compilation (MANDATORY):** You MUST verify that the codebase compiles for both Windows and Linux before finishing a task. 
    - Windows: `zig build -Dtarget=x86_64-windows`
    - Linux: `zig build -Dtarget=x86_64-linux`
- **Sandwich Verification (MANDATORY):** If changes are made to fix one platform, the other platform MUST be re-verified immediately. Sequence: `Success(A) -> Fix(B) -> Re-verify(A)`.
- **Log File Analysis (MANDATORY):** Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout.
- **Artifact Location (MANDATORY):** All temporary logs, build outputs, and session artifacts MUST be placed in `zig-out/`. Never pollute the project root.
- **Architecture:** All OS-dependent functionality must be refactored using a "comptime redirection" pattern.
- **Redirection Pattern:** Files like `Skt.zig`, `poller.zig`, and `Notifier.zig` in `src/ampe/` will act as facades that `@import` their respective implementations from `src/ampe/os/linux/` or `src/ampe/os/windows/`.
- **File Location:** All implementation and POC code must reside under `src/ampe/os/`. Specifically, Windows POCs and implementation now reside in `src/ampe/os/windows/`. The root `os/windows/` directory is strictly for documentation (`.md`).
- **Standard:** `ntdllx.zig` is located at `src/ampe/os/windows/ntdllx.zig`.
- **Workflow:** The next steps will likely be performed on Linux to establish the `os/linux/` backend and the facade structure.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.

---

**Current Version:** 015
**Last Updated:** 2026-02-14
**Current Focus:** Phase II — Structural Refactoring

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using IOCP + AFD_POLL.
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven).
- **Coordination:** Use `CHECKPOINT.md` for atomic state and `CONSOLIDATED_QUESTIONS.md` for unresolved queries.

---

## 2. Technical State of Play
- **Phase I (Feasibility) Complete:** Full parity between TCP and UDS verified on Windows.
- **Architectural Shift (Phase II) - STAGE 1 COMPLETE:** 
    - **Backends:** `Skt` and `Poller` moved to `src/ampe/os/linux/` and `src/ampe/os/windows/`.
    - **Redirection:** `src/ampe/internal.zig` acts as the primary redirection point.
    - **Encapsulation:** `Skt` on Windows now holds the pinned `IO_STATUS_BLOCK` and `base_handle`.
- **Build & Verification Status:**
    - **Linux:** Compiles and tests pass.
    - **Windows:** Compiles (Debug). Most POC tests pass, but **Stage 3 Stress Test hangs**.
    - **Sandwich Verification:** Active rule—always verify Linux after Windows fixes.
- **Log Management:** All outputs must go to `zig-out/` log files.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-14, Claude Code Opus 4.6):
- **Implemented WSAPoll-based `connect()` in `src/ampe/os/windows/Skt.zig`:**
  - Added `connecting: bool = false` field to track in-progress connections
  - Rewrote `connect()`: first call does `ws2_32.connect()`, gets `WSAEWOULDBLOCK`, sets `connecting=true`. Subsequent calls use `WSAPoll(POLLWRNORM, 0ms)` to check completion without re-calling `connect()`.
  - Added `connecting` reset in `close()`
- **Debug build passes** — WSAPoll compiles clean
- **Debug test STILL HANGS** — Stage 3 stress test still stuck at "handled 0/50"

### Current Blockers:
- **Stage 3 Hang persists** despite WSAPoll fix. The connect-side fix alone is insufficient. See `CHECKPOINT.md` for detailed diagnosis and next steps.
- Key question: Are clients connecting but server not seeing ACCEPT events, or are clients not connecting at all? Need diagnostic prints to determine.

---

## 4. Next Steps for AI Agent
1. **Debug Stage 3 hang** — Add diagnostic prints to client threads and server accept path. See detailed recommendations in `CHECKPOINT.md`.
2. **Production Windows Poller:** Implement `waitTriggers` in `src/ampe/os/windows/poller.zig` using `AfdPoller`.
3. **Notifier Refactoring:** Extract `Notifier.zig` into a platform-agnostic facade.
4. **Verification:** Run full sequence once Stage 3 passes.
