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
- **Maximize Tofu/POSIX Abstraction (MANDATORY):** Use `tofu`'s existing abstractions (e.g., `Skt` methods) and follow the error handling patterns of the POSIX layer. Avoid direct `ws2_32` calls.
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

**Current Version:** 016
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
    - **Linux:** Compiles and tests pass (Sandwich Verification active).
    - **Windows:** ALL POC tests pass (including Stage 3 Stress) in both **Debug** and **ReleaseFast** modes.
- **Log Management:** All outputs go to `zig-out/` log files.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-14, Gemini CLI Agent):
- **Full Reactor POC Alignment:**
  - Refactored `stage3_stress.zig` client thread to a proper **Reactor loop**.
  - Fixed spurious wakeups by using infinite AFD timeout and extracting events from `poll_info`.
- **Verification Sequence (PASS):**
  - `Linux Debug` -> `Windows Debug` -> `Windows ReleaseFast` -> `Linux ReleaseFast`.
  - All Stage 3 Stress tests passed (50/50 messages) without hangs.
- **Abstraction Mandate:** Aligned `Skt.zig` and POCs with the "Maximize Tofu Abstraction" rule (returning 0 for WouldBlock).

### Current State:
- Feasibility phase is officially CLOSED.
- Next: Production implementation of `Poller.waitTriggers` using the verified `AfdPoller` engine.

---

## 4. Next Steps for AI Agent
1. **Production Windows Poller:** Implement `waitTriggers` in `src/ampe/os/windows/poller.zig` using `AfdPoller`.
2. **Notifier Refactoring:** Extract `Notifier.zig` into a platform-agnostic facade.
3. **Phase III Transition:** Start building `WindowsReactor`.
