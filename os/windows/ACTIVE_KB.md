# Windows Port: Active Knowledge Base (Living Document)

---

## Maintenance & Synchronization Protocol
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
- **Architectural Approval (MANDATORY):** Any change to important architecture parts (e.g., changing the memory model, adding allocators to core structures like `Skt`, or shifting from IOCP to Sync Poll) MUST be explicitly approved by the author. Provide an explanation and intent for discussion before applying such changes.
- **Log File Analysis (MANDATORY):** Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.

---

**Current Version:** 024
**Last Updated:** 2026-02-16
**Current Focus:** Phase III — PinnedState Implementation (Plan Complete, Execution Pending)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using IOCP + AFD_POLL.
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven).
- **Core Challenge:** Resolving memory instability in the async Windows backend.

---

## 2. Technical State of Play
- **Repository Reorganization:** POC code moved to `poc/windows/`. Future ports follow the same pattern.
- **Platform Lifecycle Encapsulation:** Integrated Winsock `WSAStartup`/`WSACleanup` into `initPlatform()` and `deinitPlatform()` helper functions in `Reactor.zig`.
- **Windows Poller Implementation:** `waitTriggers` currently uses asynchronous `AFD_POLL` via IOCP.
- **CRITICAL BUG IDENTIFIED:** `std.AutoArrayHashMap` moves `TriggeredChannel` objects, invalidating pointers held by the Windows kernel.
- **APPROVED FIX:** "Indirection via Channel Numbers + Stable Poller Pool".
- **DETAILED IMPLEMENTATION PLAN:** `os/windows/analysis/claude-plan-pinned-state.md`.
- **ADDITIONAL BUG:** `SocketContext.arm()` in `afd.zig` passes stack-local `io_status` to kernel — use-after-return.
- **Build Status:** ALL active tests pass (35/35) on Windows (Debug/ReleaseFast) and Linux cross-compiles.
- **Sources of Truth:** `docs_site/docs/mds/` added — tofu user-facing documentation for channel semantics.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-16, Claude Code — PinnedState Planning):
- **Full codebase audit** for PinnedState implementation readiness.
- **Read all documentation** under `os/windows/` and `docs_site/docs/mds/` recursively.
- **Analyzed** `plan-investigation-reactor-poller.md` — confirmed diagnosis is correct, solution is architecturally sound.
- **Identified additional bug:** `SocketContext.arm()` io_status stack-local (afd.zig:85).
- **Gathered user decisions:** POC approach (both new+rewrite), memory strategy (simple now, pool later), base_handle location (stays in Skt), PinnedState lifecycle.
- **Created detailed implementation plan:** `os/windows/analysis/claude-plan-pinned-state.md` — 4 phases, code examples, risk assessment.
- **Updated CHECKPOINT.md** with plan summary and next steps.
- **No code changes made** — planning and analysis session only.

### Previous Session (2026-02-16, Gemini CLI — Reorganization & Lifecycle):
- Implemented repo reorganization (POCs to `poc/windows/`).
- Encapsulated platform setup (`initPlatform`/`deinitPlatform` in Reactor.zig).
- Root cause diagnosis confirmed. Full verification passed (35/35).

---

## 4. Next Steps for AI Agent
1. **Execute PinnedState Plan:** Follow `os/windows/analysis/claude-plan-pinned-state.md`.
   - Start with Phase 0 (POC): Fix SocketContext bug, create stage4_pinned.zig.
   - Then Phase 1 (Production): Iterator extension, PinnedState in Poller, thin Skt, refactor arm/process.
   - Each step has its own verification gate (4-step + Linux cross-compile).
2. **Enable Reactor Tests on Windows:** After PinnedState is in place.
3. **Memory Strategy Decision (Documented):** Simple heap alloc now. Block-based pool (~128/block) required for "ready" status — implement as separate future task.
4. **Skt Facade Refactoring (Q4.3):** Lower priority. After reactor tests pass.

---

## 5. Conceptual Dictionary
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move while a kernel request is pending. Heap-allocated per channel, managed by Poller.
- **Indirection via ID:** Using `ChannelNumber` (u16) to find a moving object in `trgrd_map` instead of using a direct pointer. Cast: `u16 -> usize -> PVOID` for ApcContext.
- **Thin Skt:** An abstraction where `Skt` is just a handle + address + base_handle, not a container for polling implementation details (io_status, poll_info, is_pending, expected_events move to PinnedState).
- **Orphan Cleanup:** Freeing PinnedStates for channels that were removed while no AFD_POLL was pending (no cancellation completion will arrive). Done in `cleanupOrphans()` at start of `armFds()`.
- **Deferred Cleanup:** Freeing PinnedStates for removed channels in `processCompletions()` when the STATUS_CANCELLED completion arrives. Avoids use-after-free from kernel timing.

---
