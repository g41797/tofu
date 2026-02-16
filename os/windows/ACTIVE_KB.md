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
- **Redirection Pattern:** Files like `Skt.zig` and `poller.zig` in `src/ampe/` act as facades that `@import` their respective implementations from `src/ampe/os/linux/` or `src/ampe/os/windows/`. `Notifier.zig` uses comptime branches instead (only 2 trivial platform differences).
- **File Location:** All implementation and POC code must reside under `src/ampe/os/`. Specifically, Windows POCs and implementation now reside in `src/ampe/os/windows/`. The root `os/windows/` directory is strictly for documentation (`.md`).
- **Standard:** `ntdllx.zig` is located at `src/ampe/os/windows/ntdllx.zig`.
- **Workflow:** The next steps will likely be performed on Linux to establish the `os/linux/` backend and the facade structure.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.
- **Architectural Approval (MANDATORY):** Any change to important architecture parts (e.g., changing the memory model, adding allocators to core structures like `Skt`, or shifting from IOCP to Sync Poll) MUST be explicitly approved by the author. Provide an explanation and intent for discussion before applying such changes.

---

**Current Version:** 020
**Last Updated:** 2026-02-16
**Current Focus:** Phase III — Windows Implementation (Stability Fixes)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using IOCP + AFD_POLL.
- **Mantra:** Maintain Reactor semantics (readiness-based, queue-driven).
- **Coordination:** Use `CHECKPOINT.md` for atomic state and `CONSOLIDATED_QUESTIONS.md` for unresolved queries.

---

## 2. Technical State of Play
- **Windows Poller Implementation:** `waitTriggers` implemented in `src/ampe/os/windows/poller.zig` using asynchronous `AFD_POLL` via IOCP.
- **CRITICAL ARCHITECTURAL CONFLICT:** Identified that `std.AutoArrayHashMap` in `Reactor.zig` moves `TriggeredChannel` objects during growth or `swapRemove`. This invalidates the pointers (`ApcContext` and `IoStatusBlock`) held by the Windows kernel for pending `AFD_POLL` requests, causing random panics and corruption.
- **Documentation:** `os/windows/analysis/doc-reactor-poller-negotiation.md` explains the stability issue and proposed fixes.
- **Build & Verification Status:**
    - **Linux:** Compiles (cross-compile) — Sandwich Verification active.
    - **Windows:** Production tests (reconnect tests) are failing with random panics due to pointer instability.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-16, Gemini CLI — Investigation & Planning):
- **Root Cause Investigation:** Discovered why Windows port was panicking during stress/reconnect tests. The "single threaded" reactor actually moves memory when map state changes, breaking the async contract of `AFD_POLL`.
- **Architectural Analysis:** Created detailed documentation comparing Linux (stateless) and Windows (stateful) poller negotiations.
- **Indirection/Stable Pointer Plan:** Proposed two paths forward: heap-allocating channels for a stable map, or using indirection IDs for completions.
- **Restored Baseline:** Cleaned up the poller code to use a dynamic `std.ArrayList` for completions while maintaining the IOCP architecture.

### Current State:
- **Phase III is in a critical stabilization stage.**
- The core Windows `Poller` logic is correct, but the *storage* of the data it points to is unstable.
- Next: Implement a solution for pointer stability (Stable Pointers or Indirection).

---

## 4. Next Steps for AI Agent
1. **Solve Pointer Instability:** Choose and implement a fix from `doc-reactor-poller-negotiation.md`.
    - Recommendation: **Indirection via Channel Numbers** for `ApcContext` is likely most idiomatic for Zig, combined with a stable storage for `IO_STATUS_BLOCK` if necessary.
2. **Verify Stability:** Use `zig build test --summary all -- -f "reconnect"` to verify that 1000 sequential reconnects no longer panic.
3. **Refactor Skt Facade (Q4.3):** Move `Skt` into the same facade pattern as `Poller`.

---

## 5. Conceptual Dictionary
- **Pointer Stability:** The requirement that a memory address remains valid and belongs to the same object for the duration of an asynchronous kernel request.
- **Indirection ID:** Using a non-pointer value (like an integer index) to reference an object, allowing the object to move while the ID remains a valid lookup key.
- **ApcContext:** An opaque pointer passed to the kernel and returned upon completion; currently misused as a direct `*TriggeredChannel`.
- **swapRemove:** The `ArrayHashMap` operation that destroys pointer stability by moving the last element into a middle slot.

---
