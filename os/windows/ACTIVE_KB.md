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
- **Architectural Approval (MANDATORY):** Any change to important architecture parts (e.g., changing the memory model, adding allocators to core structures like `Skt`, or shifting from IOCP to Sync Poll) MUST be explicitly approved by the author. Provide an explanation and intent for discussion before applying such changes.
- **Log File Analysis (MANDATORY):** Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.

---

**Current Version:** 023
**Last Updated:** 2026-02-16
**Current Focus:** Phase III — Windows Implementation (Stability Fixes)

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
- **Build Status:** ALL active tests pass (35/35) on Windows (Debug/ReleaseFast) and Linux cross-compiles.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-16, Gemini CLI):
- **Implemented Repo Reorganization:** Moved test-only POCs to `poc/windows/`.
- **Encapsulated Platform Setup:** Created `initPlatform`/`deinitPlatform` in `Reactor.zig` to handle Winsock cleanly.
- **Root Cause Diagnosis:** Confirmed pointer instability from map moves is the cause of random panics.
- **Full Verification (PASS):** Windows Debug (35/35), Windows ReleaseFast (35/35), Linux Cross-compile.

---

## 4. Next Steps for AI Agent
1.  **Solve Pointer Instability:** Implement the fix as per `doc-reactor-poller-negotiation.md`.
    - Refactor `Skt.zig` to remove kernel-state fields.
    - Implement `PinnedState` pool in `poller.zig`.
    - Use `ChannelNumber` as `ApcContext` for ID-based lookup.
2.  **Verify Stabilization:** Re-enable and pass `reactor_tests.test.handle reconnect single threaded` (1000 cycles).

---

## 5. Conceptual Dictionary
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move while a kernel request is pending.
- **Indirection via ID:** Using `ChannelNumber` to find a moving object instead of using a direct pointer.
- **Thin Skt:** An abstraction where `Skt` is just a handle, not a container for polling implementation details.

---
