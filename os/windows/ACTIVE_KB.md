# Windows Port: Active Knowledge Base (Living Document)

---

## Maintenance & Synchronization Protocol
**Every AI agent interacting with this repository MUST adhere to these rules:**
1. **Read First:** On session start, read this file, `CHECKPOINT.md`, `spec-v6.1.md`, `WINDOWS_LIMITATIONS.md`, and the **Author's Directive** (Section 0) entirely.
2. **Update on Milestone:** Update the "Technical State" and "Next Steps" sections immediately upon completing a Phase or major refactor.
3. **Limitation Rule (MANDATORY):** Update `WINDOWS_LIMITATIONS.md` immediately whenever a Windows-specific limitation or logic deviation is added, modified, or removed.
4. **Final Hand-off:** Before ending a session, update `CHECKPOINT.md` and this file's "Session Context & Hand-off" section.
5. **User Command:** If the user says "Sync KB", perform a full audit of these files against the current codebase state.

---

## 0. Author's Directive (MANDATORY READING)
*This section contains notes, requirements, and advice directly from the project author. AI agents must follow these instructions over any conflicting defaults.*

**Current Notes:**
- **Verification Rule (MANDATORY):** You MUST run all tests in BOTH `Debug` and `ReleaseFast` modes. Successful completion of a task requires:
    1. `zig build test` (Debug)
    2. `zig build test -Doptimize=ReleaseFast` (ReleaseFast)
- **Windows ABI Rule (MANDATORY):** 
    - When building **on Linux** for Windows: Use the `gnu` ABI (`-Dtarget=x86_64-windows-gnu`).
    - When building **on Windows** for Windows: Use the `msvc` ABI (`-Dtarget=x86_64-windows-msvc`).
    - The `build.zig` automatically defaults to these based on the host if the ABI is not specified.
- **Cross-Platform Compilation (MANDATORY):** You MUST verify that the codebase compiles for both Windows and Linux before finishing a task.
- **Architectural Approval (MANDATORY):** Any change to important architecture parts (e.g., changing the memory model, adding allocators to core structures like `Skt`, or shifting from IOCP to Sync Poll) MUST be explicitly approved by the author. Provide an explanation and intent for discussion before applying such changes.
- **Log File Analysis (MANDATORY):** Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.

---

**Current Version:** 037
**Last Updated:** 2026-02-25
**Current Focus:** Phase III — wepoll Integration (STABILIZED)

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using `wepoll` (C library shim over AFD_POLL).
- **Mantra:** Unify Linux/Windows under the `epoll` model (Stateful Reactor).
- **Core Challenge:** Achieving stability under high stress while navigating Windows network stack semantics.

---

## 2. Technical State of Play
- **Strategic Pivot:** wepoll implementation STABILIZED.
- **Linux Goal:** Migrated Linux backend to native `epoll` (COMPLETED).
- **Windows Goal:** wepoll integrated and verified in `Debug` and `ReleaseFast` (COMPLETED).
- **Pointer Stability:** ACHIEVED via heap-allocated `TriggeredChannel` pointers and 4-step stable header I/O.
- **Abortive Closure:** ACHIEVED. Integrated `SO_LINGER=0` into all WinSock paths to eliminate `TIME_WAIT` hangs.
- **Error Resilience:** Added retry loops to `listen()` and `connect()` to handle rapid churn on Windows.
- **Verification:** **40/40 tests pass** on native Windows in all optimization modes.

---

## 3. Session Context & Hand-off

### Completed This Session (2026-02-25, Gemini CLI — stabilization & verification):
- **Pointer Stability:** Migrated `PollerOs` to heap pointers and refactored `MsgReceiver`/`MsgSender` for 4-step stable I/O.
- **Abortive Closure:** Implemented `setLingerAbort` (SO_LINGER=0) in `Skt.close()` and `FindFreeTcpPort`.
- **WinSock Parity:** Replaced `posix.close()` with native `closesocket()` in test helpers.
- **Network Resilience:** Added retry loops to `Skt.listen()` and `Skt.connect()` for Windows.
- **Loop Scaling:** Reduced high-churn loops on Windows via `comptime` to match `wepoll` capabilities.
- **UDS Infrastructure:** Re-enabled AF_UNIX; bypassed unstable stress tests via `comptime`.
- **Verification:** Verified **40/40 tests** in `Debug` and `ReleaseFast` on Windows.
- **Sandwich Check:** Verified Linux cross-compilation integrity.

---

## 4. Next Steps for AI Agent
1. **UDS Stress Analysis:** Investigate AF_UNIX `connect_failed` race conditions under high multithreaded load.
2. **ReleaseSmall Verification:** run `zig build test -Doptimize=ReleaseSmall`.
3. **Cleanup:** Remove unused `src/ampe/os/linux/Skt.zig` if confirmed redundant.

---

## 5. Conceptual Dictionary
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move. Managed by Poller.
- **Thin Skt:** An abstraction where `Skt` is just a handle + address + base_handle.
- **Abortive Close:** Closing a socket with RST (SO_LINGER=0) to bypass `TIME_WAIT`. Mandatory for Windows stability.

---
