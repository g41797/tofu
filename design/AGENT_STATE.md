# Agent State & Handover

**Current Version:** 041
**Last Updated:** 2026-02-27
**Last Agent:** Claude Sonnet 4.6
**Active Phase:** Repo Cleanup & Zig Forum Showcase Preparation (COMPLETED)

---

## Current Status

- **Verification:** All tests pass in `Debug` and `ReleaseFast` on Linux.
- **Cross-Compilation:** ALL platforms verified (Linux, Windows x86_64, macOS x86_64/aarch64).
- **Poller Refactoring:** COMPLETED. Clean separation achieved.
- **Stability:** ACHIEVED. Critical pointer stability refactor (heap storage + 4-step I/O) resolved all previous segmentation faults and protocol hangs.
- **Resilience:** Abortive closure (`SO_LINGER=0`) and retry loops in `listen`/`connect` resolved all transient `BindFailed`/`ConnectFailed` errors.
- **Repo Cleanup:** COMPLETED — `poc/`, `os/windows/analysis/`, obsolete files deleted; `os/windows/` reorganized to `design/`.

---

## Technical State of Play

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
  - macOS: Fixed `setLingerAbort()` panic — use raw `system.setsockopt` for Darwin targets
  - macOS: Fixed abstract socket usage in Notifier.zig — restricted to Linux
  - macOS: Robust `KqueueBackend.modify()` using explicit `EV_ENABLE`/`EV_DISABLE` + `EV_RECEIPT` for error safety.
  - macOS: Refined `fromEvent` in `triggers.zig` for reliable `EV_EOF` and `EV_ERROR` detection.
  - macOS: Fixed `KqueueBackend.wait()` bug where timeout was ignored (passed `null` to `kevent`).
  - Notifier: Fixed `initUDS` and `waitConnect` logic to prevent hangs and correctly order `connect()`.
  - All platforms: Added `clearRetainingCapacity()` to Poller backends for safe buffer usage.
  - Windows: Set minimum version to RS4 in build.zig for UDS support
  - All platforms: Fixed hardcoded UDS path size (now comptime: macOS/BSD=104, Linux/Windows=108)
- **Verification:** Full sandwich pass — Linux tests (Debug/ReleaseFast) + Windows/macOS cross-compilation all verified.

---

## Poller Architecture (Phase IV Complete)

### File Structure
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

## Session History

### 2026-02-27: Claude Sonnet 4.6 — Repo Cleanup & Forum Showcase Preparation
- Deleted `poc/` (8 files — IOCP POC work, superseded by wepoll)
- Deleted `os/windows/analysis/` (19 files — historical AI planning deliberations)
- Deleted `os/windows/spec-base.md`, `plan-stage1-iocp-reintegration.md`, `testRunner.zig`
- Reorganized `os/windows/` → `design/` (flat directory, 10 files)
  - Created `RULES.md` (extracted rules from AI_ONBOARDING.md + decision-log.md + ACTIVE_KB.md §0)
  - Created `AGENT_STATE.md` (merged ACTIVE_KB.md + CHECKPOINT.md)
  - Renamed all other files with consistent lowercase names
- Added cross-platform documentation to `docs_site/`:
  - Updated `features.md` with cross-platform line
  - Created `platform-support.md`
  - Created `poller-design.md` with 3 new sections + original content
  - Updated `mkdocs.yml` with Internals navigation section

### 2026-02-26: Claude Opus 4.5 — Cross-Platform Fixes
- `triggers.zig` - Fixed EV flags (use integer constants instead of packed struct)
- `Skt.zig (linux)` - Fixed fcntl constants, O_NONBLOCK bitcast
- `address.zig`, `testHelpers.zig` - Fixed hardcoded UDS path size
- `build.zig` - Made `use_lld` conditional (LLD doesn't support Mach-O)
- `build.zig` - Set minimum Windows version to RS4 for UDS support
- `Skt.zig (linux)` - Fixed `setLingerAbort()` panic by using raw `system.setsockopt`
- `Notifier.zig` - Fixed abstract socket usage to be Linux-only

### 2026-02-26: Gemini CLI Agent — Poller Backend Fixes
- `kqueue_backend.zig` - Robust `modify()` with `EV_RECEIPT` error handling
- `kqueue_backend.zig` - Fixed `wait()` timeout conversion fix
- `triggers.zig` - Refined kqueue `fromEvent()` for `EV_EOF`/`EV_ERROR`
- `Notifier.zig` - Fixed `initUDS` and `waitConnect` ordering
- All backends: Added `clearRetainingCapacity()` to `wait()` for safety

### 2026-02-25: Claude Opus 4.5 — Poller Refactoring
- Created `src/ampe/poller/` directory with 7 new files
- Updated `poller.zig` facade with comptime backend selection
- Updated `internal.zig` and `Reactor.zig` to use new `Poller` type
- Changed `mac.yml` to manual dispatch only

---

## Verification Results (2026-02-26)

| Platform | Status |
|----------|--------|
| Linux tests (Debug) | ✅ PASS (35/35) |
| Linux tests (ReleaseFast) | ✅ PASS (35/35) |
| Windows x86_64 cross-compile | ✅ PASS |
| macOS x86_64 cross-compile | ✅ PASS |
| macOS aarch64 cross-compile | ✅ PASS |
| macOS native tests (CI) | Pending (setLingerAbort + abstract socket fixes) |

---

## Immediate Tasks for Next Agent

1. **macOS CI Verification:** Trigger manual workflow to verify the new kqueue timeout fix and setLingerAbort fix.
2. **Native Windows Test:** Run full test suite on native Windows machine.
3. **UDS Stress Analysis:** Investigate AF_UNIX race conditions under high load (if any remain).
4. **Legacy Cleanup:** Consider removing legacy `PollerOs()` wrapper after full verification.

---

## Conceptual Dictionary

- **ABA Problem:** A race condition where a resource (e.g., file descriptor) is released and recycled, causing stale references to misidentify the new resource as the old one. In `PollerCore`, the monotonic `SeqN` prevents this by giving each channel a unique identity regardless of FD reuse.
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move. Managed by Poller.
- **Thin Skt:** An abstraction where `Skt` is just a handle + address + base_handle.
- **Abortive Close:** Closing a socket with RST (SO_LINGER=0) to bypass `TIME_WAIT`. Mandatory for Windows stability.
- **Sandwich Build:** Cross-compilation verification across all platforms (Linux → Windows → macOS → Linux).
- **PollerCore:** Generic type that composes with backend-specific implementations (epoll, wepoll, kqueue, poll). It utilizes heap-allocated `*TriggeredChannel` objects to ensure **Pointer Stability**. This is critical for two reasons: (1) it prevents iterator invalidation during map mutations (e.g., adding a channel during an `accept` event), and (2) it ensures that kernel-facing memory like the Windows `IO_STATUS_BLOCK` remains at a fixed address for the duration of asynchronous operations, preventing memory corruption.
- **Triggers:** A packed `u8` struct with named fields (`notify`, `accept`, `connect`, `send`, `recv`, `pool`, `err`, `timeout`). The original heart of tofu's portability — expresses *intent* (what the Reactor wants to happen) rather than *mechanism* (how the OS signals it).
