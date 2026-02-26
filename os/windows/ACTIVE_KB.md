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
- **Cross-Platform Compilation (MANDATORY):** You MUST verify that the codebase compiles for all platforms (Linux, Windows, macOS) before finishing a task.
- **Architectural Approval (MANDATORY):** Any change to important architecture parts (e.g., changing the memory model, adding allocators to core structures like `Skt`, or shifting from IOCP to Sync Poll) MUST be explicitly approved by the author. Provide an explanation and intent for discussion before applying such changes.
- **Log File Analysis (MANDATORY):** Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout.
- **Coding Style (MANDATORY):**
    1. **Little-endian Imports:** Imports at the bottom of the file.
    2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
    3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.

---

**Current Version:** 041
**Last Updated:** 2026-02-26
**Current Focus:** Phase IV — Poller Refactoring (COMPLETED) + Cross-Platform Fixes

---

## 1. Project Context Summary
- **Target:** Porting `tofu` to Windows 10+ using `wepoll` (C library shim over AFD_POLL).
- **Mantra:** Unify Linux/Windows/macOS under the `epoll` model (Stateful Reactor).
- **Core Challenge:** Achieving stability under high stress while navigating Windows network stack semantics.

---

## 2. Technical State of Play
- **Strategic Pivot:** wepoll implementation STABILIZED.
- **Linux Goal:** Migrated Linux backend to native `epoll` (COMPLETED).
- **Windows Goal:** wepoll integrated and verified in `Debug` and `ReleaseFast` (COMPLETED).
- **macOS Goal:** kqueue backend implemented in poller refactoring (COMPLETED).
- **Poller Refactoring:** COMPLETED — clean separation achieved with comptime backend selection.
- **Pointer Stability:** ACHIEVED via heap-allocated `TriggeredChannel` pointers and 4-step stable header I/O.
- **Abortive Closure:** ACHIEVED. Integrated `SO_LINGER=0` into all WinSock paths to eliminate `TIME_WAIT` hangs.
- **Error Resilience:** Added retry loops to `listen()` and `connect()` to handle rapid churn on Windows.
- **Cross-Platform & Stability Fixes (2026-02-26):**
  - macOS: Fixed EV flags, fcntl constants, O_NONBLOCK bitcast, LLD linker exclusion
  - macOS: Fixed `setLingerAbort()` panic - use raw `system.setsockopt` for Darwin targets
  - macOS: Fixed abstract socket usage in Notifier.zig - restricted to Linux
  - macOS: Robust `KqueueBackend.modify()` using explicit `EV_ENABLE`/`EV_DISABLE` + `EV_RECEIPT` for error safety.
  - macOS: Refined `fromEvent` in `triggers.zig` for reliable `EV_EOF` and `EV_ERROR` detection.
  - macOS: Fixed `KqueueBackend.wait()` bug where timeout was ignored (passed `null` to `kevent`).
  - Notifier: Fixed `initUDS` and `waitConnect` logic to prevent hangs and correctly order `connect()`.
  - All platforms: Added `clearRetainingCapacity()` to Poller backends for safe buffer usage.
  - Windows: Set minimum version to RS4 in build.zig for UDS support
  - All platforms: Fixed hardcoded UDS path size (now comptime: macOS/BSD=104, Linux/Windows=108)
  - Investigation: Resolved `ReleaseFast` `SIGSEGV` by reverting aggressive zero-initialization and `accept` order changes. 100% test pass rate achieved on Linux in all modes.
- **Verification:** Full sandwich pass — Linux tests (Debug/ReleaseFast) + Windows/macOS cross-compilation all verified.

---

## 3. Poller Architecture (Phase IV Complete)

### New File Structure
```
src/ampe/
├── poller.zig                    # Facade: comptime selects backend
├── poller/
│   ├── common.zig                # Shared: TcIterator, isSocketSet, toFd, constants
│   ├── triggers.zig              # Trigger mapping: epoll/kqueue conversions
│   ├── core.zig                  # Shared struct fields + PollerCore generic
│   ├── poll_backend.zig          # ISOLATED: Legacy poll (will be obsolete)
│   ├── epoll_backend.zig         # Linux epoll implementation
│   ├── wepoll_backend.zig        # Windows wepoll implementation (includes FFI)
│   └── kqueue_backend.zig        # macOS/BSD kqueue implementation
```

### Key Design Decisions
1. **Comptime Selection (Zero Overhead):** Backend selected at compile time based on OS
2. **Each Backend is Complete:** No comptime branches inside functions, whole functions per OS
3. **Shared Logic via Composition:** PollerCore generic composes with backend-specific implementations
4. **Backward Compatibility:** `PollerOs(backend)` wrapper maintained for existing consumers

---

## 4. Session Context & Hand-off

### Completed This Session (2026-02-26, Claude Opus 4.5 — Cross-Platform Fixes):
- **macOS Cross-Compilation Fixes:**
  - `triggers.zig` - Fixed EV flags (use integer constants instead of packed struct)
  - `Skt.zig (linux)` - Fixed fcntl constants, O_NONBLOCK bitcast
  - `address.zig`, `testHelpers.zig` - Fixed hardcoded UDS path size
  - `build.zig` - Made `use_lld` conditional (LLD doesn't support Mach-O)
- **Windows UDS Fix:**
  - `build.zig` - Set minimum Windows version to RS4 for `has_unix_sockets = true`
  - Refactored to `standardTargetOptionsQueryOnly()` + `resolveTargetQuery()` pattern
- **macOS Runtime Fixes:**
  - `Skt.zig (linux)` - Fixed `setLingerAbort()` panic by using raw `system.setsockopt`
    - stdlib's `std.posix.setsockopt` treats EINVAL as unreachable, but macOS returns EINVAL for SO_LINGER
  - `Notifier.zig` - Fixed abstract socket usage to be Linux-only
    - Changed `if (builtin.os.tag != .windows)` to `if (builtin.os.tag == .linux)`
    - macOS/BSD do NOT support abstract Unix sockets (setting `socket_file[0] = 0`)
    - This caused "uds_path_not_found" errors on macOS CI
- **Verification:** Full sandwich pass (Linux Debug/ReleaseFast + Windows/macOS x86_64/aarch64 cross-compile)

### Previous Session (2026-02-25, Claude Opus 4.5 — poller refactoring):
- Created `src/ampe/poller/` directory with 7 new files
- Updated `poller.zig` facade with comptime backend selection
- Updated `internal.zig` and `Reactor.zig` to use new `Poller` type
- Changed `mac.yml` to manual dispatch only

---

## 5. Next Steps for AI Agent
1. **Commit Changes:** All cross-platform fixes ready (git disabled this session)
2. **macOS CI Verification:** Trigger manual workflow to verify:
   - `setLingerAbort()` raw syscall fix (EINVAL handling)
   - Abstract sockets Linux-only fix (Notifier.zig)
3. **Native Windows Test:** Run full test suite on native Windows machine
2. **macOS CI Test:** Trigger manual workflow to verify kqueue backend
3. **UDS Stress Analysis:** Investigate AF_UNIX race conditions under high load
4. **Cleanup:** Consider removing legacy `PollerOs()` wrapper after full verification

---

## 6. Conceptual Dictionary
- **ABA Problem:** A race condition where a resource (e.g., file descriptor) is released and recycled, causing stale references to misidentify the new resource as the old one. In `PollerOs`, the monotonic `SeqN` prevents this by giving each channel a unique identity regardless of FD reuse.
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move. Managed by Poller.
- **Thin Skt:** An abstraction where `Skt` is just a handle + address + base_handle.
- **Abortive Close:** Closing a socket with RST (SO_LINGER=0) to bypass `TIME_WAIT`. Mandatory for Windows stability.
- **Sandwich Build:** Cross-compilation verification across all platforms (Linux → Windows → macOS → Linux).
- **PollerCore:** Generic type that composes with backend-specific implementations (epoll, wepoll, kqueue, poll). It utilizes heap-allocated `*TriggeredChannel` objects to ensure **Pointer Stability**. This is critical for two reasons: (1) it prevents iterator invalidation during map mutations (e.g., adding a channel during an `accept` event), and (2) it ensures that kernel-facing memory like the Windows `IO_STATUS_BLOCK` remains at a fixed address for the duration of asynchronous operations, preventing memory corruption.

---
