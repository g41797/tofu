# Agent State & Handover

**Current Version:** 059
**Last Updated:** 2026-05-05
**Last Agent:** Claude Sonnet 4.6
**Active Phase:** Implementation Ready — Stage 0 is next

---

## Current Status

- **Verification:** All 64 tests pass in `Debug` and `ReleaseSafe` on Linux. Full sandwich verified (Windows x86_64, macOS x86_64/aarch64).
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

### 2026-05-05: Claude Sonnet 4.6 — Design Folder Cleanup

#### Summary
Deleted two more obsolete design files. Design folder is now minimal and current.

#### Changes
- `design/transition-2-usockets-verdict.md` — deleted (decision and findings already captured in AGENT_STATE.md and the implementation plan)
- `design/AGENT_STATE.md` — this entry

#### Remaining design files
| File | Purpose |
| :--- | :--- |
| `AGENT_STATE.md` | Session state and handover |
| `RULES.md` | Contributor and agent rules |
| `poller-design.md` | Poller architecture documentation |
| `transition-2-usockets.md` | Migration information base |
| `transition-2-bun-usockets-plan.md` | Final implementation plan (stages 0–6) |

#### Verification
No code changes.

---

### 2026-05-05: Claude Sonnet 4.6 — Final bun-usockets Implementation Plan

#### Summary
Deep source-level analysis of `vendor/bun-usockets/src/` and all existing design documents.
Produced `design/transition-2-bun-usockets-plan.md` — the single authoritative implementation plan.
Deleted three obsolete design files.

#### Key findings (from reading actual C source)

- `us_internal_dispatch_ready_poll` is defined in **`loop.c`** (not socket.c). To override it from Zig via `export fn`, the C definition must be marked `__attribute__((weak))` — a one-line patch to `vendor/bun-usockets/src/loop.c`.
- All three Windows adapter headers are **required**: `sys/epoll.h` (wepoll redirect), `sys/timerfd.h`, `sys/eventfd.h`. bun-usockets calls `timerfd_create` and `eventfd` internally at loop init time regardless of user code.
- `bsd_create_connect_socket` takes a pre-resolved `sockaddr_storage*` — hostname resolution must be done via `getaddrinfo` C extern on the Zig side.
- `POLL_TYPE_SOCKET = 0` is the correct poll type. Store `*TriggeredChannel` in ext memory (`p + 1`, 16-byte aligned, `ext_size = @sizeOf(*TriggeredChannel)`).
- All bsd_* functions and `POLL_TYPE_*` constants are in internal headers — `internal/internal.h` and `internal/networking/bsd.h`. Both must be added as include paths in `build.zig`.
- `us_socket_local_address` (needed by `Skt.getPort()`) is in bun-usockets `libusockets.h` — absent from upstream uSockets. Confirms bun-usockets as the only viable choice.

#### Changes
- `design/transition-2-bun-usockets-plan.md` — new (final authoritative plan, stages 0–6)
- `design/transition-2-usockets-plan.md` — deleted (superseded)
- `design/bun-usockets-implementation.md` — deleted (superseded)
- `design/usockets-open-questions.md` — deleted (AI research dump, content incorporated)
- `design/AGENT_STATE.md` — this entry

#### Verification
No code changes. Analysis and documentation only.

---

### 2026-05-05: Claude Sonnet 4.6 — Design Doc Cleanup

#### Summary
Removed 10 obsolete files from `design/`. Remaining active files: 7.

#### Removed:
- `reactor-kb.md` — Reactor-over-IOCP knowledge base (IOCP approach abandoned)
- `spec.md` — Reactor-over-IOCP Specification v6.1 (same reason)
- `QUESTIONS.md` — Phase I Windows POC feasibility questions (all resolved)
- `notifier-platform-independent.md` — completed task plan
- `remove-socket-from-msgsender.md` — completed task plan
- `sockets-tests-plan.md` — completed task plan
- `uds-notes.md` — completed task plan (Status: COMPLETED)
- `transition-2-usockets-plan.md` — completed structural split plan (Status: COMPLETE)
- `roadmap.md` — Phase IV COMPLETE, all phases done
- `decisions.md` — early decision log superseded by `transition-2-usockets.md` and `AGENT_STATE.md`

#### Remaining design docs:
- `AGENT_STATE.md` — session state and handover (this file)
- `RULES.md` — contributor and agent rules
- `poller-design.md` — poller architecture documentation
- `poller-tests-plan.md` — poller test plans (Tasks 1–3)
- `transition-2-usockets.md` — usockets migration information base
- `transition-2-usockets-verdict.md` — bun-usockets vs upstream verdict
- `windows-notes.md` — Windows implementation limitations and deviations

---

### 2026-05-05: Claude Sonnet 4.6 — initPlatform/deinitPlatform + Platform-Independent Poller Tests

#### Summary
Three coupled changes.

**`initPlatform`/`deinitPlatform` promoted to tofu source:** `Reactor.zig` had private `initPlatform`/
`deinitPlatform` functions (WSAStartup/WSACleanup on Windows, no-op elsewhere). Extracted to
`src/ampe/internal.zig` as `pub fn initPlatform() AmpeError!void` / `pub fn deinitPlatform() void`.
`Reactor.zig` calls `internal.initPlatform`/`internal.deinitPlatform`. Exported via `tofu.zig` as
`tofu.initPlatform`/`tofu.deinitPlatform`. Single canonical implementation — no duplication across test files.

**`poller_tests.zig` made platform-independent:** All 8 backend contract tests now call
`try tofu.initPlatform()` / `defer tofu.deinitPlatform()`. Linux-only guard removed from `tofu_tests.zig`.
Tests run on all platforms (epoll, kqueue, wepoll, future usockets).

**`pollercore_tests.zig` updated:** Local `wsaInit`/`wsaDeinit` helpers replaced with
`tofu.initPlatform`/`tofu.deinitPlatform`. `builtin` import removed (no longer needed).

#### Changes:
- `src/ampe/internal.zig` — `initPlatform`/`deinitPlatform` added (public)
- `src/ampe/Reactor.zig` — `initPlatform`/`deinitPlatform` removed; calls `internal.initPlatform`/`internal.deinitPlatform`
- `src/tofu.zig` — `initPlatform`/`deinitPlatform` exported
- `tests/ampe/poller_tests.zig` — `tofu.initPlatform`/`deinitPlatform` in all 8 tests
- `tests/pollercore_tests.zig` — local helpers replaced by `tofu.initPlatform`/`deinitPlatform`
- `tests/tofu_tests.zig` — linux guard removed from `poller_tests` import
- `design/poller-tests-plan.md` — Task 3 section updated
- `design/transition-2-usockets.md` — §17 rewritten
- `design/AGENT_STATE.md` — this entry

#### Verification (full sandwich):

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (64/64) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (64/64) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |

---

### 2026-05-05: Claude Sonnet 4.6 — PollerCore Integration Tests (pollercore_tests.zig)

#### Summary
Converted `tests/windows_poller_tests.zig` (Windows-only, 2 tests) to
`tests/pollercore_tests.zig` — platform-independent PollerCore integration tests
that run on all backends (epoll, kqueue, wepoll, future usockets) without OS guards.

**Changes from original:**
- Skip guard removed (no `SkipZigTest`).
- WSA lifecycle: `wsaInit()`/`wsaDeinit()` comptime helpers — `if (builtin.os.tag == .windows)` prunes the block on POSIX; `std.os.windows` is never analyzed on Linux/macOS.
- Port 0 + `getPort().?` replaces `FindFreeTcpPort()`.
- `sendBuf()` replaces `send()` (correct `Skt` method name).
- `connectWithRetry` loop replaces single-shot `connect()` — safe across all platforms.
- `tofu_tests.zig`: Windows guard+import replaced by unconditional `_ = @import("pollercore_tests.zig")`.
- `windows_poller_tests.zig` retained as a file; no longer imported.

#### Changes:
- `tests/pollercore_tests.zig` — new file (2 PollerCore integration tests)
- `tests/tofu_tests.zig` — replaced windows guard with unconditional pollercore_tests import
- `design/poller-tests-plan.md` — Task 3 section added
- `design/transition-2-usockets.md` — §17 added (PollerCore test portability)
- `design/AGENT_STATE.md` — this entry

#### Verification:

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (64/64) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (64/64) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |

---

### 2026-05-05: Claude Sonnet 4.6 — Poller Backend Contract Tests + FdType Correction

#### Summary
Two coupled tasks.

**FdType correction:** `usockets_backend.zig` register/modify/unregister used `std.posix.fd_t`
(i32) but usockets backend compiles on all platforms. Corrected to `common.FdType`
(i32 on POSIX, usize on Windows — matches `LIBUS_SOCKET_DESCRIPTOR`).
`internal.zig` Socket type for usockets updated: inlined as
`if (builtin.os.tag == .windows) usize else std.posix.fd_t` to avoid circular import
(`internal.zig` ↔ `common.zig`).
`design/transition-2-usockets.md` §15.6 added documenting the alignment.

**Poller contract tests:** New `tests/ampe/poller_tests.zig` — 8 backend contract tests.
Tests the backend directly via `poller_instance.backend.*` (bypasses PollerCore).
Single-threaded throughout — write data before `wait()` for readable tests;
freshly connected socket is immediately writable for send tests.
`makeTC` uses `var tc: TriggeredChannel = undefined` + explicit `.exp`/`.act` init
(`std.mem.zeroes` rejected — TriggeredChannel has non-nullable pointer fields).

#### Changes:
- `src/ampe/usockets/usockets_backend.zig` — `std.posix.fd_t` → `common.FdType` (3 signatures)
- `src/ampe/internal.zig` — usockets Socket type inlined (circular import avoided)
- `design/transition-2-usockets.md` — §15.6 FdType Alignment added
- `tests/ampe/poller_tests.zig` — new file (8 tests)
- `tests/tofu_tests.zig` — poller_tests import added (linux guard)
- `design/poller-tests-plan.md` — plan saved
- `design/AGENT_STATE.md` — this entry

#### Verification:

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (62/62) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (62/62) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |

---

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

## Constraints for Next Agent (MANDATORY)

- **Git disabled.** Do NOT run any git commands. Author manages version control manually.
- **No GitHub CI references.** GitHub workflows are not in use. Say "native hardware testing", not "CI run".
- **overview.md Credits** — do NOT add AI agent credits there. Author did not ask for this.
- **Doc style** — see `design/RULES.md` §5. Short sentences. Bullet lists for sequences. No marketing language. Plain English for non-native speakers. Tech terms are fine.
- **"allows to verb"** is a grammar error in English. Restructure any such phrase found in docs.
- **Architectural changes** require explicit author approval before implementation.

---

## Immediate Tasks for Next Agent

The implementation plan is in `design/transition-2-bun-usockets-plan.md`. Stages in order:

1. **Stage 0 — VSCode config** — update `.vscode/launch.json` (add `"c"` to `sourceLanguages`, add `"Debug Tests (usockets)"` config) and `.vscode/tasks.json` (add `"zig build install usockets"` and `"zig build test usockets"` tasks). No code changes.

2. **Stage 1 — build.zig + Skt.zig + SocketCreator.zig** — wire bun-usockets C sources into `build.zig`; implement `usockets/Skt.zig` using `bsd_*` wrappers; implement `usockets/SocketCreator.zig` using `bsd_create_*` + `getaddrinfo` extern. Acceptance: `sockets_tests.zig` pass on Linux.

3. **Stage 2 — Notifier tests** — Notifier itself is done. Run `Notifier_tests.zig` under `-Dnetwork=usockets` to confirm. Acceptance: both tests pass.

4. **Stage 3 — triggers.zig + usockets_backend.zig** — implement full backend including `export fn us_internal_dispatch_ready_poll` override and `us_loop_run_bun_tick` wait loop. Requires one-line vendor patch: add `__attribute__((weak))` to `us_internal_dispatch_ready_poll` in `vendor/bun-usockets/src/loop.c`. Acceptance: all 64 tests pass, 4-mode sandwich on Linux.

5. **Stage 4 — Windows adapter headers** — create `src/ampe/windows/adapters/sys/epoll.h`, `timerfd.h`, `eventfd.h`. Acceptance: cross-compile `x86_64-windows-gnu -Dnetwork=usockets` succeeds.

6. **Stage 5 — macOS verify** — cross-compile `x86_64-macos` and `aarch64-macos`. Acceptance: compile succeeds.

7. **Stage 6 — native hardware testing + docs** — full sandwich on native Linux; bump `AGENT_STATE.md`.

---

## Conceptual Dictionary

- **ABA Problem:** A race condition where a resource (e.g., file descriptor) is released and recycled, causing stale references to misidentify the new resource as the old one. In `PollerCore`, the monotonic `SeqN` prevents this by giving each channel a unique identity regardless of FD reuse.
- **Pinned State:** Implementation-specific memory (like IO status blocks) that must not move. Managed by Poller.
- **Thin Skt:** An abstraction where `Skt` is just a handle + address + base_handle.
- **Abortive Close:** Closing a socket with RST (SO_LINGER=0) to bypass `TIME_WAIT`. Mandatory for Windows stability.
- **Sandwich Build:** Cross-compilation verification across all platforms (Linux → Windows → macOS → Linux).
- **PollerCore:** Generic type that composes with backend-specific implementations (epoll, wepoll, kqueue, poll). It utilizes heap-allocated `*TriggeredChannel` objects to ensure **Pointer Stability**. This is critical for two reasons: (1) it prevents iterator invalidation during map mutations (e.g., adding a channel during an `accept` event), and (2) it ensures that kernel-facing memory like the Windows `IO_STATUS_BLOCK` remains at a fixed address for the duration of asynchronous operations, preventing memory corruption.
- **Triggers:** A packed `u8` struct with named fields (`notify`, `accept`, `connect`, `send`, `recv`, `pool`, `err`, `timeout`). The original heart of tofu's portability — expresses *intent* (what the Reactor wants to happen) rather than *mechanism* (how the OS signals it).
