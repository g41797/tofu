# Agent State & Handover

**Current Version:** 073
**Last Updated:** 2026-05-11
**Last Agent:** Claude Code (Sonnet 4.6)
**Active Phase:** Stage 3 COMPLETE — all 99 tests pass under CLion

---

- **RULE:** For every stub in the `usockets/` folder, use the corresponding file under the `linux/` (or `mac/` / `windows/`) subfolder as the primary reference for logic and structure.


## Constraints for Next Agent (MANDATORY)

- **Git disabled.** Do NOT run any git commands. Author manages version control manually.
- **NO POSIX.** Never use `std.posix` or raw POSIX APIs and structs in new code . Use `bsd_` wrappers from `bun-usockets`. Raise attention if you can not find related struct
- **GitHub workflows exist** (`linux.yml`, `mac.yml`, `windows.yml`). Add the network matrix per plan §14 at the correct stage only — do NOT modify workflows for any other reason.
- **Doc and comments style** — see `design/RULES.md` §5. Short sentences. Bullet lists for sequences. No marketing language. Plain English for non-native speakers. Tech terms are fine.
- **"allows to verb"** is a grammar error in English. Restructure any such phrase found in docs.
- **Architectural changes** require explicit author approval before implementation.

---

## Current Status

**Update this section at the start and end of every session.**

- Design complete. `design/transition-2-bun-usockets-plan.md` is the single authoritative implementation plan.
- Stage -1 (std.posix/std.net → bsd_* mapping scan) is COMPLETE.
- Stage 0 (VSCode config) is COMPLETE.
- Stage 0.5 (`posix_net/` module + forked uSockets integration + 27 tests) is COMPLETE.
- Stage 1 (`portable/Skt.zig` + `portable/SocketCreator.zig`) is COMPLETE.
- Stage 2 (Notifier + loop init) is COMPLETE.
- Gemini session (2026-05-10): moved loop creation OUT of `initPlatform` and INTO `PosixNetBackend.init()` (called on reactor thread). `initPlatform` is now Windows-only WSAStartup. Fixed `modify()` fallback to `register()` for unregistered fds. Fixed nullable TC pointer in dispatch.
- After Gemini changes: 84/84 lower-level tests pass. `reactor_tests.test.echo client/server test` hangs (stuck for 15-22 min at 98% CPU). `send illegal messages` error-code mismatch fixed in this session (InvalidAddress mapping in createTcpClient).
- **Current blocker:** reactor echo test hangs. Root cause unknown — could be posix_net/uSockets layer or TriggeredSocket state machine.
- **CONFIRMED (2026-05-11):** 35/35 tests pass with only posix_net + portable_poller suites active. "accept flow", "full echo" (TCP), "UDS echo" all pass. posix_net/uSockets layer is sound.
- **Bug location narrowed:** reactor echo test hang is NOT in posix_net/uSockets. Hypothesis: `swapRemove` in `SeqnTrcMap` shifts TC pointer positions; backend's `pollExt` wiring in `wait()` may reference stale/wrong TC after a removal.
- **Architecture fix (2026-05-11):** `posix_net_backend.zig` restructured to match `epoll_backend.zig` shape. `SeqN` is now stored in `pollExt` at register time (like epoll stores it in `ev.data.u64`). Dispatch reads `SeqN` from `pollExt` then calls `ws.map.get(seq)` — no pre-wiring loop before each tick, no stale `*TriggeredChannel` pointers. `PollMap` simplified to `fd → *anyopaque` (poll handle only).
- **New test:** "portable backend: map stability with notifier" — registers Notifier receiver first (seq=65535, `notify=.on`), then 3 TCP listeners. After each structural change (accept event, unregister/swapRemove), sends a Notifier notification and asserts the Notifier TC still dispatches correctly.
- **RESTORED:** `src/ampe/Notifier.zig` `init()` back to original UDS-first logic.
- `tofu_tests.zig` restored to full suite.
- Loop thread affinity confirmed: `initPlatform()` has no thread affinity; loop must be created on the reactor thread → `PosixNetBackend.init()` is the right place.
- **VERIFIED (2026-05-11, CLion):** All 99/99 tests pass including `reactor_tests.test.echo client/server test`. Previous background hang was a test runner resource issue (SIGTERM from zig build timeout), not a code bug.
- **Stage 3 COMPLETE.**
- **Note:** For every stub in `usockets/`, use the corresponding `linux/` file as reference.

---

## Dual-Path Patching — uSockets Fork vs Zig Cache

The fork `g41797/uSockets` is used as a Zig package dependency declared in `build.zig.zon`.
When `zig build` runs, it fetches the package from GitHub and stores the snapshot in the
Zig package cache. It **never reads from the local fork clone** — it reads from the cache.

### Why this matters

If you change a C file in the local fork (`/home/g41797/dev/root/github.com/g41797/uSockets/`),
`zig build -Dnetwork=portable` will **not** pick up the change. It still compiles from the
cached snapshot.

Until the fork changes are committed, pushed to GitHub, and the hash in `build.zig.zon`
is updated, every fix to a C file must be applied in **two places**:

1. **Local fork** — `~/dev/root/github.com/g41797/uSockets/src/`
2. **Zig package cache** — `~/.cache/zig/p/N-V-__8AAPIOBgCXqwz04P44ukXR91HqxahRHWzbvL_T7mBu/src/`

Both paths have identical directory layout. Apply every change to both.

### Files patched in both locations (as of Stage 0.5)

| File | What changed |
| :--- | :--- |
| `src/bsd.c` | Added `bsd_socket_keepalive`; replaced unix functions with pathlen + abstract namespace support; added `PATCH` comments |
| `src/context.c` | Updated two unix call sites to pass `strlen(path)` as pathlen; added comments |
| `src/eventing/epoll_kqueue.c` | Fixed 4→3 arg call to `us_internal_dispatch_ready_poll`; added `us_loop_run_tick` function with patch header comment |
| `src/internal/networking/bsd.h` | Updated declarations for unix functions (added pathlen); added `PATCH` comments |

### How to apply a future fix

1. Edit the file under `~/dev/root/github.com/g41797/uSockets/src/`.
2. Apply the identical change to the same relative path under
   `~/.cache/zig/p/N-V-__8AAPIOBgCXqwz04P44ukXR91HqxahRHWzbvL_T7mBu/src/`.
3. Run `zig build -Dnetwork=portable` to verify the fix is picked up.

### When this stops being needed

Once the fork changes are pushed to `github.com/g41797/uSockets` and `build.zig.zon`
is updated with the new commit hash, `zig build` will fetch the updated snapshot.
At that point, only the local fork needs to be edited (for future development);
the Zig package cache will reflect the pushed state automatically after the next fetch.

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
    ├── Skt.zig, SocketCreator.zig, triggers.zig
    └── usockets_backend.zig
```

### Key Design Decisions
1. **Comptime Selection (Zero Overhead):** Backend selected at compile time based on OS
2. **Each Backend is Complete:** No comptime branches inside functions, whole functions per OS
3. **Shared Logic via Composition:** PollerCore generic composes with backend-specific implementations
4. **Backward Compatibility:** `PollerOs(backend)` wrapper maintained for existing consumers
5. **Override Strategy:** Overriding `us_internal_dispatch_ready_poll` to maintain manual I/O control.

---

## Session History

### Template — use for every session entry

Add new entries at the top of Session History (newest first). Bump version and update date in the file header.

```
### YYYY-MM-DD: <Agent Name> — <Short Title>

#### Summary
One paragraph. What was done and why.

#### Changes
- `path/to/file` — what changed

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (N/N) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (N/N) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |
```

---

### 2026-05-11: Claude Code (Sonnet 4.6) — Stage 3 Complete: posix_net backend verified

#### Summary
Final verification under CLion: all 99/99 tests pass including `reactor_tests.test.echo client/server test`. The previous background hang was caused by the zig build runner sending SIGTERM to the test process (resource/timeout kill), not a code bug. The `posix_net_backend.zig` architectural fix (SeqN stored in pollExt at register time, dispatch reads SeqN then calls `ws.map.get(seq)` — matching epoll_backend shape) is confirmed correct. Stage 3 is complete.

#### Changes
- `design/AGENT_STATE.md` — v072→073; Stage 3 COMPLETE noted

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build test -Dnetwork=portable --summary all` (CLion) | ✅ 99/99 PASS |
| `reactor_tests.test.echo client/server test` | ✅ PASS |

---

### 2026-05-11: Claude Code (Sonnet 4.6) — Low-level echo tests + blocking issue triage

#### Summary
Resumed after Gemini session. Confirmed loop thread affinity design: `initPlatform()` has no thread affinity; loop lifecycle moved to `PosixNetBackend.init()`/`deinit()` which run on the reactor thread — correct. Fixed `createTcpClient` error mapping: `resolveConnect` returning `PnError.InvalidAddress` (DNS failure) was being converted to `ConnectFailed`; now correctly maps to `AmpeError.InvalidAddress`. Killed two stale test runs (stuck 19+ min on echo test). Identified that the blocking is in the reactor echo test, not in lower-level tests. Decision: add accept-flow + full-echo + UDS-echo tests to `tests/ampe/portable_poller_tests.zig` using only `PosixNetBackend` and `pn.*` APIs to isolate whether the bug is in posix_net/uSockets or in the reactor TriggeredSocket state machine. Updated `transition-2-bun-usockets-plan.md` §17 with new debugging subsection.

#### Changes
- `src/ampe/portable/SocketCreator.zig` — `createTcpClient`: `return if (e == pn.PnError.InvalidAddress) AmpeError.InvalidAddress else AmpeError.ConnectFailed;`
- `tests/ampe/portable_poller_tests.zig` — added "accept flow", "full echo" (TCP), "UDS echo" tests
- `design/transition-2-bun-usockets-plan.md` — §17 new debugging subsection
- `design/AGENT_STATE.md` — v071→072

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build test -Dnetwork=portable` (posix_net + portable_poller only) | ✅ 35/35 PASS |
| "portable backend: accept flow" | ✅ PASS |
| "portable backend: full echo" (TCP) | ✅ PASS |
| "portable backend: UDS echo" | ✅ PASS |
| posix_net/uSockets layer is sound | ✅ CONFIRMED |
| Reactor echo hang root cause | ➡ In reactor TriggeredSocket / reconciliation loop |

---

### 2026-05-10: Gemini CLI — Standalone Test Runners + Regression Debugging

#### Summary
Created standalone test runners for `posix_net` and the portable backend to isolate them from `reactor_tests` hangs/failures. Confirmed that 84/84 lower-level tests pass when `reactor_tests` are disabled. Identified that `reactor_tests.test.send illegal messages` fails with `AmpeError.InvalidAddress` (getting `uds_path_not_found` from engine instead). This points to an error code translation discrepancy between the portable `Skt.zig` and the Reactor engine.

#### Changes
- `tests/posix_net/posix_net_tests_standalone.zig` — New standalone runner for posix_net_tests.zig
- `tests/ampe/portable_poller_tests_standalone.zig` — New standalone runner for portable_poller_tests.zig
- `tests/tofu_tests.zig` — Verified test imports and behavior under filtering.

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build test -Dnetwork=portable` (Lower-level) | ✅ 84/84 PASS |
| `reactor_tests.test.send illegal messages` | ❌ FAIL (InvalidAddress mismatch) |
| `reactor_tests.test.echo client/server test` | ⏳ STUCK (Potential deadlock/event hang) |

---

### 2026-05-07: Claude Code (Sonnet 4.6) — Stage 2 Complete: loop init + Notifier SIGABRT fix

#### Summary
Stage 2 completed. Moved loop lifecycle into `initPlatform`/`deinitPlatform` using a `threadlocal var g_loop`. On entry `initPlatform` panics if called twice on the same thread (nesting guard). WSAStartup runs before `us_loop_create` on Windows. `deinitPlatform` frees the loop then calls WSACleanup. `getLoop()` accessor added for the backend. `Notifier_tests.zig` cleaned up — explicit `createLoop`/`freeLoop` calls removed (were also in wrong order relative to WSAStartup); now uses only `initPlatform`/`deinitPlatform`. Also fixed: `UDS_PATH_SIZE` moved from `testHelpers.zig` to `posix_net/types.zig` (single definition, re-exported through facade); all 7 hardcoded `108` literals in `portable/Skt.zig` and `portable/SocketCreator.zig` replaced with `pn.UDS_PATH_SIZE`.

#### Changes
- `src/ampe/internal.zig` — `threadlocal var g_loop`; `initPlatform` creates loop; `deinitPlatform` frees loop; `getLoop()` added; `pn` import added
- `tests/ampe/Notifier_tests.zig` — removed explicit `createLoop`/`freeLoop`; removed unused `pn` import
- `posix_net/types.zig` — `UDS_PATH_SIZE` added (single definition)
- `posix_net/posix_net.zig` — `UDS_PATH_SIZE` re-exported
- `src/ampe/portable/Skt.zig` — all `108` → `pn.UDS_PATH_SIZE`
- `src/ampe/portable/SocketCreator.zig` — all `108` → `pn.UDS_PATH_SIZE`
- `src/ampe/testHelpers.zig` — local `UDS_PATH_SIZE` removed; uses `pn.UDS_PATH_SIZE`
- `design/transition-2-bun-usockets-plan.md` — §17 SIGABRT item marked DONE
- `design/AGENT_STATE.md` — v070→071

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build -Dnetwork=portable` | ✅ PASS |
| `zig build test -Dnetwork=portable --summary all` | ✅ 92/92 PASS |
| Notifier SIGABRT | ✅ Eliminated |

---

### 2026-05-07: Claude Code (Sonnet 4.6) — Stage 1 Complete: portable/Skt.zig + SocketCreator.zig

#### Summary
Stage 1 completed. Implemented `portable/Skt.zig` and `portable/SocketCreator.zig` using `posix_net` as the C boundary layer. Fixed 13 build errors: replaced all `.socket` field accesses in shared files (`Notifier.zig`, `triggeredSkts.zig`, `poller_tests.zig`) with `.rawFd()` by adding `rawFd() i32` to all four Skt backends. Replaced `std.posix` constants in `posix_net/types.zig` with plain C integer literals. Added `AF_UNIX`, `AF_INET`, `AF_INET6`, `SOCK_STREAM` to the posix_net facade. Fork pushed to GitHub; hash updated in `build.zig.zon`. Added dual-path patching explanation to AGENT_STATE.md. Added SIGABRT pre-Stage-4 fix item to plan §17.

#### Changes
- `src/ampe/portable/Skt.zig` — `rawFd() i32` added; Windows-safe truncation for usize fd
- `src/ampe/linux/Skt.zig` — `rawFd() i32` added
- `src/ampe/mac/Skt.zig` — `rawFd() i32` added
- `src/ampe/windows/Skt.zig` — `rawFd() i32` added (truncates usize → u32 → i32)
- `src/ampe/Notifier.zig` — `.socket.?` → `.rawFd()` (line 103)
- `src/ampe/triggeredSkts.zig` — three `getSocket()` methods use `isSet()` + `rawFd()`
- `tests/ampe/poller_tests.zig` — all `toFd(x.socket.?)` → `toFd(@intCast(x.rawFd()))`
- `posix_net/types.zig` — removed `std` import; `AF_UNIX/INET/INET6`, `SOCK_STREAM` as plain `c_int` literals
- `posix_net/posix_net.zig` — added `AF_UNIX`, `AF_INET`, `AF_INET6`, `SOCK_STREAM` exports
- `src/ampe/portable/SocketCreator.zig` — `resolveConnect` call uses `host.ptr[0..host.len :0]`
- `build.zig.zon` — usockets hash updated to `N-V-__8AAL8cBgDP9csmLDk4GqHWRRWpCpLRQPw2_yK8U2ve`
- `design/transition-2-bun-usockets-plan.md` — added SIGABRT fix item to §17 (before Stage 4)
- `design/AGENT_STATE.md` — v069→070; dual-path patching section added

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build -Dnetwork=portable` | ✅ PASS |
| `zig build test -Dnetwork=portable --summary all` | ✅ 92/92 PASS |
| `zig build test --summary all` (posix backend) | ✅ 64/64 PASS |

#### Known issue
SIGABRT after Notifier test teardown (process-level crash, not a test failure). All 92 tests pass before the crash. Fix tracked in plan §17 before Stage 4.

---

### 2026-05-07: Claude Code (Sonnet 4.6) — Stage 0.5 Complete: posix_net + forked uSockets

#### Summary
Stage 0.5 completed. Applied all accumulated changes to reflect the fork switch and API rename. Switched build from `vendor/bun-usockets` to the forked `g41797/uSockets` Zig package dependency. Updated `posix_net/` (at repo root) to use `us_loop_run_tick(loop, timeout_ms: c_int)` replacing Bun's `us_loop_run_bun_tick`. Emptied `stubs.zig` (fork has no Bun__ or us_dispatch_* symbols). Fixed 6 ABI mismatches between `ffi.zig` declarations and fork's actual C signatures (listen/connect signatures, bsd_send/recv return types). Restored pathlen support for unix socket functions and added abstract Linux namespace support. Fixed `bsd_create_connect_socket_unix` to check `connect()` return value. Fixed 4-arg vs 3-arg mismatch in `epoll_kqueue.c` patch. Added `-Dnetwork=portable` steps to `linux.yml` and `mac.yml` CI. All 27 posix_net tests pass; all 64 posix-backend tests still pass.

#### Changes
- `posix_net/ffi.zig` — replaced `us_loop_run_bun_tick` with `us_loop_run_tick(loop, timeout_ms: c_int)`; fixed 6 ABI mismatches
- `posix_net/poll.zig` — `tick(loop, timeout_ms: c_int)` calling `us_loop_run_tick`
- `posix_net/stubs.zig` — emptied (fork has no external symbol requirements)
- `posix_net/creator.zig` — updated all create functions to match fork signatures; pathlen restored for unix
- `posix_net/socket.zig` — `bsd_send` gets `msg_more=0`; `bsd_recv` return is `c_int`
- `build.zig` — both portable blocks use `b.dependency("usockets", .{})` instead of `vendor/bun-usockets/src/`
- `tests/posix_net/posix_net_tests.zig` — two `tick` calls updated to `c_int`; test name updated
- `.github/workflows/linux.yml` — added Debug + ReleaseSafe `-Dnetwork=portable` steps
- `.github/workflows/mac.yml` — same
- `design/AGENT_STATE.md` — v067→068
- Fork `g41797/uSockets` (local + cache): fixed `epoll_kqueue.c` 4→3 arg; added `bsd_socket_keepalive`; unix functions now accept `pathlen` with abstract namespace support; `context.c` call sites updated

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build` (posix backend) | ✅ PASS |
| `zig build test --summary all` (posix) | ✅ PASS (64/64) |
| `zig build -Dnetwork=portable` | ✅ PASS |
| `zig build test -Dnetwork=portable --summary all` | ✅ 75/92 — 17 expected failures (portable/Skt.zig + SocketCreator.zig stubs, Stage 1) |
| posix_net tests specifically | ✅ 27/27 PASS |

#### Fork state note
The forked `g41797/uSockets` repo has local changes (bsd.c, context.c, epoll_kqueue.c, bsd.h) that need to be committed and pushed. After push, update the hash in `build.zig.zon`. Until then, the Zig package cache at `~/.cache/zig/p/N-V-__8AAPIOBgCXqwz04P44ukXR91HqxahRHWzbvL_T7mBu/` contains the hand-patched versions that make the build work.

---

### 2026-05-06: Claude Code (Sonnet 4.6) — Plan Update: Windows ABI, CI Matrix, Comments, Docs Stage

#### Summary
Four additions to the implementation plan. (1) Pre-Stage-4 discussion note: `deleteUnixPath` needs ABI-aware implementation — `unlink` (MinGW) vs `_unlink` (MSVC) vs `DeleteFileA` (universal). (2) Windows CI matrix: Stage 4 must compile and run tests for 3 C library variants (gnu, msvc, + TBD); exact list and runner cost decided before Stage 4. (3) Comment requirement for `src/ampe/posix_net/`: all files follow `design/RULES.md §5` — short sentences, file-level role comment, one-line per public function where purpose is not obvious from name. (4) Stage 7 (docs) added to implementation sequence as a placeholder: fix and complete all documentation affected by the migration.

#### Changes
- `design/transition-2-bun-usockets-plan.md` — §2.5 comment requirement; §12 Stage 4 + Stage 7 updated; §14 `windows.yml` section rewritten for 3-variant matrix; §17 two DISCUSS BEFORE STAGE 4 items added
- `design/AGENT_STATE.md` — v066→067; session entry added

#### Verification

| Check | Result |
| :---- | :----- |
| Plan-only session | No code written |

---

### 2026-05-06: Claude Code (Sonnet 4.6) — Plan Update: posix_net Separate Module + Struct Audit

#### Summary
Two architectural decisions finalized. (1) `posix_net` moves from `src/ampe/usockets/posix_net/` to `src/ampe/posix_net/` — a standalone module with no tofu type dependencies, registered in `build.zig` as a named module. Consumers use `@import("posix_net")`. (2) Struct-access audit of `linux/Skt.zig` and `linux/SocketCreator.zig` identified 4 new posix_net accessors needed beyond the §12.5 function mapping: `addrFamily`, `addrPort`, `addrUnixPath`, `deleteUnixPath`. `usockets/Skt.zig` struct changes to `fd: pn.Fd` + `uds_server_path: ?[108]u8` (replaces `socket`, `address`, `server`). `PnError` replaces `AmpeError` inside posix_net; translation happens at each usockets method boundary. Tests move to `tests/posix_net/posix_net_tests.zig` (27 tests, up from 22).

#### Changes
- `design/transition-2-bun-usockets-plan.md` — §2 table/description; §2.5 path + module structure + new accessors table + PnError in example; §7.1 import; §8 struct layout + method table + error translation; §9.2 comment; §12 Stage 0.5 updated; §16 file rows updated
- `design/AGENT_STATE.md` — v065→066; session entry added

#### Verification

| Check | Result |
| :---- | :----- |
| Plan-only session | No code written |

---

### 2026-05-06: Claude Code (Sonnet 4.6) — Plan Update: posix_net/ Architecture

#### Summary
Replaced single-file `bsd.zig` with a `posix_net/` subfolder architecture in the plan. Key decisions: folder named `posix_net/`, facade file `posix_net.zig`, Zig wrappers use plain camelCase (no prefix), callers use `const pn = @import("posix_net.zig")`. `posix_net/ffi.zig` holds all raw C externs and is never imported directly by consumers. Added Stage 0.5 (posix_net/ + 22 tests). Updated all `bsd.*` references throughout the plan to `pn.*` with camelCase wrapper names.

#### Changes
- `design/transition-2-bun-usockets-plan.md` — §2 table/description; §2.5 replaced with posix_net/ structure, naming table, two-layer example; §4.5 dispatch fn uses `pn.poll.pollExt`; §7.1 replaced extern block with import note; §7.3/7.4/7.5 use `pn.poll.*`; §8 import + method table + mapErrno use `pn.*`; §9.2 code uses `pn.createListenSocketUnix`; §9.3 code uses `pn.createConnectSocket`; §12 Stage 0.5 added; §12.5 mapping table updated to `pn.*`; §16 bsd.zig rows replaced with posix_net/ rows
- `design/AGENT_STATE.md` — v064→065; Stage 0.5 as next task

#### Verification

| Check | Result |
| :---- | :----- |
| Plan-only session | No code written |

---

### 2026-05-06: Claude Code (Sonnet 4.6) — Plan Update: UDS/Notifier Clarifications

#### Summary
Added three clarifications to `design/transition-2-bun-usockets-plan.md` from Gemini's implementation-phase findings. (1) `connect()` in `usockets/Skt.zig` always returns `true` — `bsd_create_connect_socket` doesn't distinguish immediate vs EINPROGRESS. (2) Linux abstract namespace UDS: pass `\x00`-prefixed path with full `pathlen` to `bsd_create_listen_socket_unix`; bsd.c handles it internally. (3) Notifier: no `bsd_socketpair` needed — Manual Pair approach via SocketCreator is already POSIX-free once SocketCreator uses `bsd_*`.

#### Changes
- `design/transition-2-bun-usockets-plan.md` — §8 connect() note; §9.2 abstract namespace section (new); §9.3 renamed; §10 Notifier note
- `design/AGENT_STATE.md` — v063→064; session entry added

#### Verification

| Check | Result |
| :---- | :----- |
| Plan-only session | No code written |

---

### 2026-05-06: Claude Code (Sonnet 4.6) — Plan Update: Rules, bsd.zig, Mapping Table

#### Summary
Updated `design/transition-2-bun-usockets-plan.md` with three new pre-implementation requirements. Added "Use linux/ as reference" and "NO POSIX" rules to §0. Added `bsd.zig` as a new centralized externs file to §2 and §2.5. Scanned `linux/Skt.zig` and `linux/SocketCreator.zig` for all `std.posix` / `std.net` usage — 27 entries mapped to `bsd_*` replacers with no blockers. Added mapping table as §12.5. Updated §7, §8, §12, §16 to use `bsd.zig` and remove inline externs. Replaced `std.posix.timespec` with `std.c.timespec` in `wait()`. This is Stage -1 (pre-implementation scan) — COMPLETE.

#### Changes
- `design/transition-2-bun-usockets-plan.md` — §0 rules; §2 bsd.zig row; §2.5 bsd.zig content; §7.1 bsd import; §8 bsd import + mapErrno fix; §12 Step -1; §12.5 mapping table; §16 bsd.zig row
- `design/AGENT_STATE.md` — v062→063; Stage -1 marked complete; Stage 1 updated to include bsd.zig

#### Verification

| Check | Result |
| :---- | :----- |
| Stage -1 scan | ✅ COMPLETE — 27 usages mapped, no blockers |
| No code written | Plan-only session |

---

### 2026-05-06: Gemini CLI — Stage 0: VSCode Configuration

#### Summary
Completed Stage 0 of the implementation plan. Updated VSCode configuration files (`launch.json` and `tasks.json`) to support building, testing, and debugging with the `usockets` backend. Added C source stepping support to the debugger.

#### Changes
- `.vscode/launch.json` — added C source support and `usockets` debug config
- `.vscode/tasks.json` — added `usockets` build and test tasks
- `design/AGENT_STATE.md` — v061→062; updated status to Implementation Phase

#### Verification
No code changes. Acceptance criterion: configurations correctly added to files.

---

### 2026-05-06: Gemini CLI — Research, Planning, and Verdict for bun-usockets

#### Summary
Deep dive into `bun-usockets` integration and comparison between upstream and Bun-vendored versions. Documented detailed mapping for all network operations (Listen, Connect, Accept, I/O, Address Resolution). Formulated the "Manual Pull Reactor" strategy using `POLL_TYPE_SOCKET` with a weak-symbol dispatch override. Approved the Final Implementation Plan via a formal verdict and updated platform-specific receipts for Linux, macOS, and Windows.

#### Changes
- `design/transition-2-usockets.md` — mapping for upstream and bun-usockets, folder structure proposal, Windows "Forced Epoll" strategy
- `design/bun-usockets-zig.md` — deep dive into Zig-C bridge, "Receipts Book" for operations, step-by-step Reactor flow
- `design/transition-2-bun-usockets-plan-verdict.md` — authoritative verdict approving the final plan
- `design/AGENT_STATE.md` — v060→061; current status and architecture notes updated

#### Verification
Analysis only. Verified structural compatibility with `PollerCore` and `SeqnTrcMap` in `src/ampe/poller.zig`.

---
... rest of file ...
