# Agent State & Handover

**Current Version:** 053
**Last Updated:** 2026-05-04
**Last Agent:** Claude Sonnet 4.6
**Active Phase:** Pre-Implementation Analysis (COMPLETE)

---

## Current Status

- **Verification:** All 53 tests pass in `Debug`, `ReleaseSafe`, and `ReleaseFast` on Linux.
- **Cross-Compilation:** ALL platforms verified (Linux, Windows x86_64, macOS x86_64/aarch64).
- **Cleanup:** `tests/os_windows_tests.zig` deleted — all tests were duplicates of `sockets_tests.zig` / `Notifier_tests.zig` or permanently skipped on Linux.
- **Platform-Independent Notifier:** COMPLETED. Single shared `src/ampe/Notifier.zig` — zero posix imports, `initPair` poll loop, `getPort()` on all Skt backends.
- **Skt/SocketCreator Contract Tests:** COMPLETED. 18 new tests in `tests/ampe/sockets_tests.zig`.
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

## Architecture (after OS Folder Flattening)

### File Structure
```
src/ampe/
├── poller.zig                    # Facade: comptime selects backend
├── internal.zig                  # Facade: Skt, Socket, Notifier, SocketCreator
├── common.zig                    # Shared: TcIterator, isSocketSet, toFd, constants
├── core.zig                      # Shared struct fields + PollerCore generic
├── Notifier.zig                  # Shared: platform-independent (replaces 3 identical copies)
├── linux/
│   ├── Skt.zig, SocketCreator.zig, triggers.zig
│   └── epoll_backend.zig
├── windows/
│   ├── Skt.zig, SocketCreator.zig, triggers.zig
│   ├── wepoll_backend.zig
│   └── wepoll/                   # vendored copy (wepoll.c, wepoll.h)
├── mac/
│   ├── Skt.zig, SocketCreator.zig, triggers.zig
│   └── kqueue_backend.zig
└── usockets/
    ├── Skt.zig, Notifier.zig (stub), SocketCreator.zig (stub), triggers.zig
    └── usockets_backend.zig (stub)
```

### Key Design Decisions
1. **Comptime Selection (Zero Overhead):** Backend selected at compile time based on OS
2. **Each Backend is Complete:** No comptime branches inside functions, whole functions per OS
3. **Shared Logic via Composition:** PollerCore generic composes with backend-specific implementations
4. **Backward Compatibility:** `PollerOs(backend)` wrapper maintained for existing consumers

---

## Session History

### 2026-05-05: Claude Sonnet 4.6 — Folder Structure After usockets Migration

#### Summary
Analyzed what remains platform-specific after `bsd.c` absorbs OS differences.
Answered: `linux/`, `mac/`, `windows/` posix folders are unchanged — they are the posix backend.
`usockets/` becomes a single unified backend for all platforms under `-Dnetwork=usockets`.

`bsd.c` handles internally: accept variants (accept4/accept+fcntl), all setsockopt, connect
Windows fast-fail, EINTR retry, MSG_NOSIGNAL compat, abstract UDS addrlen, macOS path workaround.

Only three small comptime branches remain in `usockets/Skt.zig`:
- Error mapping: `WSAGetLastError()` vs `errno`
- Abstract UDS prefix: `path[0] = 0` (Linux only, already in Notifier.zig)
- WSAStartup/Cleanup: stays in Reactor.zig (already there)

`windows/shims/` (C headers: sys/epoll.h, sys/timerfd.h, sys/eventfd.h) stays as build
infrastructure for Windows usockets compilation. Not Zig code.

#### Changes:
- `design/transition-2-usockets.md` — §16 appended (folder structure after migration)

#### Verification:
No code changes. Analysis and documentation only.

---

### 2026-05-04: Claude Sonnet 4.6 — bun-usockets Chosen as Implementation Target

#### Summary
Updated verdict and transition documents to reflect the final backend decision:
**bun-usockets** (`vendor/bun-usockets/`) is the implementation target for all platforms.

Decisive factors:
- `us_socket_local_address` is public in bun-usockets — needed for `Skt.getPort()`.
  Upstream uSockets has no public equivalent.
- `us_loop_run_bun_tick` is an exported symbol that matches tofu's tick model exactly.
- Windows forced-epoll is already battle-tested by the Bun team.
- bun-usockets is already vendored; upstream is not.

Appended §15 to `design/transition-2-usockets.md`:
- Corrected API mapping table (POLL_TYPE_CALLBACK path)
- Internal headers that must be included (`internal.h`, `networking/bsd.h`)
- Windows shim strategy (unchanged from §13; corrected eventfd/timerfd reasoning)
- Implementation sequence: Linux → Windows → macOS → Linux sandwich, 4-mode verify

Updated verdict in `design/transition-2-usockets-verdict.md`:
- §14 rewritten with balanced tradeoff analysis
- Final verdict section added explicitly recommending bun-usockets
- Summary table last row corrected

#### Changes:
- `design/transition-2-usockets-verdict.md` — §14 rewritten, Final Verdict section added
- `design/transition-2-usockets.md` — §15 appended (bun-usockets implementation proposal)
- `design/AGENT_STATE.md` — this entry

#### Verification:
No code changes. Analysis and documentation only.

---

### 2026-05-04: Claude Sonnet 4.6 — usockets Migration Plan Verdict

#### Summary
Reviewed and verified `design/transition-2-usockets.md` (Gemini CLI analysis of usockets migration)
against the actual source code of both uSockets backends:
- `/home/g41797/dev/root/github.com/uNetworking/uSockets/` (upstream)
- `/home/g41797/dev/root/github.com/g41797/tofu/vendor/bun-usockets/` (bun fork)

Saved detailed findings to `design/transition-2-usockets-verdict.md`.

#### Key findings:

1. **All "bsd_*" and `POLL_TYPE_CALLBACK` APIs are internal-only** — not in `libusockets.h`.
   Both approaches require including internal headers (`internal/internal.h`, `networking/bsd.h`).
   Workable since tofu vendors full source, but the migration plan does not acknowledge this.

2. **`us_loop_run_bun_tick` is not in bun-usockets' public header** — defined in `epoll_kqueue.c`,
   linkable as an exported symbol, but not officially declared in `libusockets.h`.

3. **`us_socket_local_address` is bun-only** — present in bun-usockets `libusockets.h` (line 536),
   absent from upstream uSockets. Critical for `Skt.getPort()`. Upstream would need raw
   `getsockname` (reintroducing posix) or internal struct access.

4. **Accept mapping is wrong for the POLL_TYPE_CALLBACK path** — §7/§9 say `on_open callback`,
   but with POLL_TYPE_CALLBACK there is no on_open. Correct: manual `bsd_accept_socket(us_poll_fd(p), &addr)`.

5. **"Template approach" (§12.2) is architecturally backwards** — `usockets/` IS the backend for
   `-Dnetwork=usockets` builds, not a source of templates to copy to posix folders.

6. **eventfd/timerfd shims ARE needed** — but because uSockets creates them internally at loop init,
   not because tofu calls `us_wakeup_loop` (which it won't, since Notifier uses socket-pairs).

7. **§14 verdict understates bun-usockets** — `us_socket_local_address` being public and the existing
   vendored state make bun-usockets the stronger practical choice for initial implementation.

#### Changes:
- `design/transition-2-usockets-verdict.md` — new verdict document

#### Verification:
No code changes. Analysis only.

---

### 2026-05-04: Claude Sonnet 4.6 — Test Cleanup

#### Summary
Deleted `tests/os_windows_tests.zig` — a staging file from the wepoll integration phase.
All live tests in it were duplicates of `sockets_tests.zig` and `Notifier_tests.zig`; the
Windows-only Poller POC tests (Stages 0–4) were fully commented out.
Removed its import from `tofu_tests.zig`.

#### Changes:
- `tests/os_windows_tests.zig` — deleted
- `tests/tofu_tests.zig` — removed `os_windows_tests.zig` import
- `design/AGENT_STATE.md` — this entry

#### Verification:

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (53/53) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |

---

### 2026-05-04: Claude Sonnet 4.6 — Platform-Independent Notifier

#### Summary
Consolidated three byte-for-byte identical `Notifier.zig` files (linux/, mac/, windows/) into a
single shared `src/ampe/Notifier.zig` with zero `std.posix` imports.

Key design changes:
- **`getPort() ?u16`** added to all four `Skt.zig` backends — returns `null` for UDS sockets, port for TCP.
- **`initPair`** — new single-thread poll loop (same pattern as `TCP connect and accept` test) replaces `waitConnect` + accept-retry. Works for both TCP (port 0) and UDS paths.
- **`initTCP`** — uses port 0 (OS assigns); retrieves port via `listener.getPort().?`. Eliminates `FindFreeTcpPort()` call.
- **Removed** posix-dependent functions: `create`, `destroy`, `isReadyToSend`, `_isReadyToSend`, `isReadyToRecv`, `_isReadyToRecv`, `waitConnect`, `sendByte`, `recvByte`, `send_notification`.
- **`recv_notification`** signature changed from `socket_t` → `*Skt`; `triggeredSkts.zig:246` updated.
- **`Notifier_tests.zig`** rewritten — clean send/recv round-trip, no posix, no isReady* calls.
- **`os_windows_tests.zig`** Windows Notifier test rewritten — same clean round-trip.

#### Changes:
- `src/ampe/Notifier.zig` — new shared file
- `src/ampe/linux/Skt.zig`, `mac/Skt.zig`, `windows/Skt.zig`, `usockets/Skt.zig` — added `getPort() ?u16`
- `src/ampe/internal.zig` — Notifier selection simplified to single `@import("Notifier.zig")`
- `src/ampe/triggeredSkts.zig:246` — `recv_notification(nskt.skt.socket.?)` → `recv_notification(nskt.skt)`
- `tests/ampe/Notifier_tests.zig` — rewritten (clean round-trip, no posix)
- `tests/os_windows_tests.zig` — Windows Notifier test rewritten
- `src/ampe/linux/Notifier.zig`, `mac/Notifier.zig`, `windows/Notifier.zig` — deleted
- `design/notifier-platform-independent.md` — plan saved
- `design/AGENT_STATE.md` — this entry

#### Verification:

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (53/53) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (53/53) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |

---

### 2026-05-04: Claude Sonnet 4.6 — Skt/SocketCreator Contract Tests

#### Summary
Added `tests/ampe/sockets_tests.zig` — 18 contract tests for `linux/Skt.zig` and `linux/SocketCreator.zig`.
Tests use only the public `tofu.*` API (zero `std.posix` in test code) so they run unchanged after posix removal.
Fixed two race conditions in the initial implementation of the multi-thread TCP tests:

1. **`TCP recvToBuf returns null when no data`** — server thread sent RST (SO_LINGER=0) before client's second `connect()` call. Fix: listener pre-created in main thread; server stores accepted conn in `ctx.conn`; main thread closes it after `connectWithRetry` returns.

2. **`TCP connect and accept`** — non-blocking connect/accept cannot be retried on the same socket across threads without races. Fix: rewritten as single-threaded poll loop — interleaves `connect()` and `accept()` retries in one loop, no server thread needed.

#### Changes:
- `tests/ampe/sockets_tests.zig` — new file (18 tests, 4 groups)
- `tests/tofu_tests.zig` — added `_ = @import("ampe/sockets_tests.zig");` guarded by `if (builtin.os.tag == .linux)`
- `src/ampe/linux/Skt.zig`, `mac/Skt.zig`, `windows/Skt.zig`, `usockets/Skt.zig` — added `isSet()` method
- `design/sockets-tests-plan.md` — plan saved; updated to reflect final implementation
- `design/AGENT_STATE.md` — this entry

#### Verification:

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (53/53) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (53/53) |
| `zig build test -Doptimize=ReleaseFast` | ✅ PASS (53/53) |

---

### 2026-05-04: Claude Sonnet 4.6 — Socket Abstraction Cleanup

#### Summary
Removed raw `Socket` type from `MsgSender` and `MsgReceiver` in `triggeredSkts.zig`.
Both now store `*Skt` pointing to the parent `IoSkt.skt`. Instance methods `sendBuf`/`recvToBuf`
added to all four `Skt.zig` files. `sendBufTo` deleted (zero callers). `Reactor.zig` hardcoded
`std.posix.socket_t` fixed to `internal.Socket`.

#### Changes:
- `linux/Skt.zig`, `mac/Skt.zig`, `windows/Skt.zig`, `usockets/Skt.zig` — renamed free fns to `sendBufFd`/`recvToBufFd`; added instance methods `sendBuf`/`recvToBuf`; deleted `sendBufTo`
- `triggeredSkts.zig` — `MsgSender`/`MsgReceiver`: `socket: Socket` → `skt: *Skt`; updated `set()`, send/recv loops, `IoSkt.initServerSide()`, `postConnect()`, `refreshPointers()`
- `Reactor.zig` — fixed `Socket` type import
- `design/remove-socket-from-msgsender.md` — session plan saved

#### Verification:

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseFast` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseSmall` | ✅ PASS (35/35) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |

---

### 2026-05-04: Claude Sonnet 4.6 — OS Folder Flattening (Restructure)

#### Summary
Flattened `src/ampe/os/` and `src/ampe/poller/` into four sibling OS folders directly under `src/ampe/`.
Each OS folder is now self-contained with its own backend, Notifier, SocketCreator, and triggers.
wepoll vendored by copy (submodule removed). Reactor shutdown race condition fixed. CI workflows aligned.

#### Structure after this session:
```
src/ampe/
├── linux/    — Skt.zig, Notifier.zig, SocketCreator.zig, triggers.zig, epoll_backend.zig
├── windows/  — Skt.zig, Notifier.zig, SocketCreator.zig, triggers.zig, wepoll_backend.zig, wepoll/
├── mac/      — Skt.zig, Notifier.zig, SocketCreator.zig, triggers.zig, kqueue_backend.zig
├── usockets/ — Skt.zig, Notifier.zig (stub), SocketCreator.zig (stub), triggers.zig, usockets_backend.zig
├── common.zig, core.zig
├── poller.zig, internal.zig  (facades — imports updated)
```
Deleted: `src/ampe/os/`, `src/ampe/poller/`, top-level `Notifier.zig`, `SocketCreator.zig`, `linux/poll_backend.zig` (not in use).

#### Other fixes in this session:
- `Reactor.zig` — shutdown race condition: atomic `shutdownFlag`, unconditional `waitFinish()`, `timedWait(10s)` with detach on timeout, defer LIFO ordering corrected
- `.github/workflows/linux.yml` — test order aligned (Debug→Safe→Fast→Small)
- `.github/workflows/mac.yml` / `windows.yml` — added `rm -rf ./.zig-cache/` between test runs

#### Verification:

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseFast` | ✅ PASS (35/35) |
| `zig build test -Doptimize=ReleaseSmall` | ✅ PASS (35/35) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |

---

### 2026-05-03: Claude Sonnet 4.6 — Phase 3: FindFreeTcpPort to Skt.zig

#### Summary
Moved `FindFreeTcpPort` logic from `testHelpers.zig` to platform-specific `Skt.zig` files.
`testHelpers.FindFreeTcpPort()` is now a thin wrapper — all 7 callers unchanged.

#### Changes:
- `src/ampe/os/linux/Skt.zig` — added `findFreeTcpPort` (posix impl, covers Linux + macOS)
- `src/ampe/os/windows/Skt.zig` — added `findFreeTcpPort` (ws2_32 impl with linger + 20ms sleep)
- `src/ampe/os/usockets/Skt.zig` — added `findFreeTcpPort` stub (`error.NotImplemented`)
- `src/ampe/testHelpers.zig` — replaced body with `return Skt.findFreeTcpPort()`; added `internal`/`Skt` import; removed `posix` import

#### Verification results:

| Check | Result |
| :---- | :----- |
| `zig build` (posix default) | ✅ PASS |
| `zig build test` (posix default) | ✅ PASS (all tests) |
| `zig build -Dnetwork=usockets` | ✅ PASS |
| `zig build -Dtarget=x86_64-windows -Dnetwork=posix` | ✅ PASS |
| `grep posix\. src/ampe/testHelpers.zig` | ✅ PASS (zero results) |

---

### 2026-05-03: Claude Sonnet 4.6 — Phase 2: Network-Independent triggeredSkts.zig

#### Summary
Removed all `std.posix` and `ws2_32` references from `triggeredSkts.zig`.

#### Changes:
- `src/ampe/triggeredSkts.zig` — replaced `std.posix.iovec_const`/`iovec` with internal `IoBufConst`/`IoBuf` structs; removed `sendBuf`, `sendBufTo`, `recvToBuf` function bodies; updated call sites to `Skt.sendBuf(...)` and `Skt.recvToBuf(...)`; removed unused `builtin` import
- `src/ampe/os/linux/Skt.zig` — added `sendBuf`, `sendBufTo`, `recvToBuf` (posix impl)
- `src/ampe/os/windows/Skt.zig` — added `sendBuf`, `sendBufTo`, `recvToBuf` (ws2_32 impl)
- `src/ampe/os/usockets/Skt.zig` — added `sendBuf`, `sendBufTo`, `recvToBuf` (stubs)

#### Verification results:

| Check | Result |
| :---- | :----- |
| `zig build` (posix default) | ✅ PASS |
| `zig build test` (posix default) | ✅ PASS (all tests) |
| `zig build -Dnetwork=usockets` | ✅ PASS (stubs compile) |
| `zig build -Dtarget=x86_64-windows -Dnetwork=posix` | ✅ PASS |
| `grep std.posix\|ws2_32 triggeredSkts.zig` | ✅ PASS (zero results) |

---

### 2026-05-03: Claude Sonnet 4.6 — usockets Migration Structural Split

#### Summary
Prepared tofu for usockets migration. Created information base, analysis documents, and executed structural split to enable build-time network backend selection.

#### Documents created:
- `design/transition-2-usockets.md` — full migration information base (inventory, usockets API analysis, Bun integration patterns, mapping tables, Hook-Back strategy, constraints)
- `design/transition-2-usockets-plan.md` — implementation plan with coordination instructions for future agents

#### Structural split (Phase 1) — COMPLETE:
- `build.zig` — added `-Dnetwork=posix|usockets` option; `build_options` module wired to all modules
- `src/ampe/internal.zig` — updated Skt/Socket selection to use `build_options.network`
- `src/ampe/poller.zig` — updated Poller selection to use `build_options.network`
- `src/ampe/os/usockets/Skt.zig` — new usockets Skt stub (compile-only)
- `src/ampe/poller/usockets_backend.zig` — new usockets Poller stub (compile-only)

#### Verification results:

| Check | Result |
| :---- | :----- |
| `zig build` (posix default) | ✅ PASS |
| `zig build test` (posix default) | ✅ PASS (all tests) |
| `zig build -Dnetwork=posix` | ✅ PASS |
| `zig build -Dnetwork=usockets` | ✅ PASS (stubs compile) |
| `zig build -Dtarget=x86_64-windows -Dnetwork=posix` | ✅ PASS |

---

### 2026-02-27: Claude Sonnet 4.6 — Site Documentation Polish (Session 2)

#### Rules added to design/RULES.md (Section 5 — Documentation Style):
- Short sentences over long ones
- Bullet lists for sequences and multi-step flows
- No marketing language, no AI filler, plain English for non-native speakers
- Tech terms are fine as-is

#### Changes to docs_site/docs/mds/:

**overview.md:**
- Opening paragraph rewritten: "asynchronous Zig messaging library" (dropped "protocol and"), native Zig clarification, wepoll note added
- AI agent credits NOT added to Credits section (author did not ask for this — do not add)

**features.md** — 6 fixes:
- "Asynchronous": "Enables non-blocking..." → "Non-blocking message exchange."
- "Duplex": "Supports two-way..." → "Two-way communication."
- "Peer-to-Peer": "Allows equal roles after connection establishment." → "Equal roles after connection."
- "Multithread-friendly": "safe for concurrent access" → "thread-safe"
- "Backpressure": "Allows to control receive of messages" (grammar error) → "Flow control for incoming messages"
- "Customizable flows": "Allows to build various..." (grammar error) → "Any flow — not just request/response or pub/sub"

**key-ingredients.md:** "poll loop" → "event loop"

**imports.md:** "poll-style loop" → "event loop"

**platform-support.md** — full pass:
- Reactor/Proactor sections rewritten: shorter, prose trimmed, code blocks do the work
- wepoll description: "epoll emulator for Windows, internally based on IOCP."
- Removed AI filler: "Control flow is explicit and predictable", "bounded, mechanical, and isolated", "This is a deliberate architectural guarantee", long closing sentence
- `Io.Evented` section: Scenario A/B simplified

**poller-design.md:**
- Architecture opener: "bridges the gap" cliché removed
- Acknowledgements: participant names now links ([Author], [Claude Code], [Gemini CLI])
- Added: "This document is also a result of that cooperation. The author disagreed with the writing style. The vote was 2:1."

#### Open questions:
- AI labeling for poller-design.md and platform-support.md — unresolved, ask author
- Author said "return to previous doc" after platform-support.md — unclear which doc; ask at session start

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
| macOS native tests | Pending (setLingerAbort + abstract socket fixes) |

---

## Constraints for Next Agent (MANDATORY)

- **Git disabled.** Do NOT run any git commands. Author manages version control manually.
- **No GitHub CI references.** GitHub workflows are not in use. Say "native hardware testing", not "CI run".
- **overview.md Credits** — do NOT add AI agent credits there. Author did not ask for this.
- **Doc style** — see `design/RULES.md` §5. Short sentences. Bullet lists for sequences. No marketing language. Plain English for non-native speakers. Tech terms are fine.
- **"allows to verb"** is a grammar error in English. Restructure any such phrase found in docs.
- **Architectural changes** require explicit author approval before implementation.

---

## Immediate Tasks for Next Agent

1. **Per-OS posix removal** — each OS folder (`linux/`, `windows/`, `mac/`) now has its own copy of `Notifier.zig`, `SocketCreator.zig`, `triggers.zig`. Per-OS adaptation (removing `std.posix` calls for Zig 0.16+) can now proceed independently in each folder. `MsgSender`/`MsgReceiver` now use `*Skt` — the raw `Socket` type no longer appears in business logic.
2. **macOS native hardware testing** — pending. Run full test suite on native macOS.
3. **Native Windows Test** — pending. Run full test suite on native Windows machine.
4. **UDS Stress Analysis** — investigate AF_UNIX race conditions under heavy load on Windows.
5. **Legacy Cleanup** — consider removing legacy `PollerOs()` wrapper after full verification.
6. **AI labeling** — open question: should `poller-design.md` and `platform-support.md` get an explicit "AI-generated" label like sockets101.md? User said "I'm not sure." Resolve with author.

---

## Conceptual Dictionary

- **ABA Problem:** A race condition where a resource (e.g., file descriptor) is released and recycled, causing stale references to misidentify the new resource as the old one. In `PollerCore`, the monotonic `SeqN` prevents this by giving each channel a unique identity regardless of FD reuse.
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move. Managed by Poller.
- **Thin Skt:** An abstraction where `Skt` is just a handle + address + base_handle.
- **Abortive Close:** Closing a socket with RST (SO_LINGER=0) to bypass `TIME_WAIT`. Mandatory for Windows stability.
- **Sandwich Build:** Cross-compilation verification across all platforms (Linux → Windows → macOS → Linux).
- **PollerCore:** Generic type that composes with backend-specific implementations (epoll, wepoll, kqueue, poll). It utilizes heap-allocated `*TriggeredChannel` objects to ensure **Pointer Stability**. This is critical for two reasons: (1) it prevents iterator invalidation during map mutations (e.g., adding a channel during an `accept` event), and (2) it ensures that kernel-facing memory like the Windows `IO_STATUS_BLOCK` remains at a fixed address for the duration of asynchronous operations, preventing memory corruption.
- **Triggers:** A packed `u8` struct with named fields (`notify`, `accept`, `connect`, `send`, `recv`, `pool`, `err`, `timeout`). The original heart of tofu's portability — expresses *intent* (what the Reactor wants to happen) rather than *mechanism* (how the OS signals it).
