# Agent State & Handover

**Current Version:** 084
**Last Updated:** 2026-05-13
**Last Agent:** Gemini CLI
**Active Phase:** Stage 6 in progress — macOS CI fixes applied (addrinfo layout + LIBUS_SOCKET_WRITABLE + EV_EOF mapping + accept address bug); awaiting CI confirmation; Windows native 4-mode pending

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
- **Stage 4 COMPLETE.** Windows adapter headers done. `posix_net/adapters/` contains `sys/epoll.h` (wepoll redirect), `sys/timerfd.h`, `sys/eventfd.h`, `win_compat.h`, `us_epoll_win.c`. Cross-compile `zig build -Dtarget=x86_64-windows-gnu -Dnetwork=portable` succeeds.
- **Stage 5 COMPLETE.** macOS cross-compilation verified: `x86_64-macos` and `aarch64-macos` both succeed with `-Dnetwork=portable`.
- **Stage 6 in progress.** Windows native testing (CLion). Bug found: `bsd_set_nonblocking()` in vendored uSockets was a no-op on Windows — every socket created or accepted through the C layer was blocking. Fixed by replacing the `_WIN32` no-op with `ioctlsocket((SOCKET)fd, FIONBIO, &mode)` in `g41797/uSockets/src/bsd.c`. Affects the **portable backend only**: native Windows backend (`windows/SocketCreator.zig`) uses `std.posix.socket()` + explicit `ioctlsocket` directly, so `bsd_set_nonblocking` was never in its path. After author pushes this fix and updates `build.zig.zon` commit+hash, all portable-backend sockets (TCP/UDS, listener/client/accepted) will be non-blocking on Windows.
- **Stage 6 secondary issue — FIXED.** After `build.zig.zon` update, Linux portable test `handleReConnnectOfTcpClientServerST` failed with `ListenFailed`. Root cause was `setLingerAbort` being a no-op (sockets stayed in TIME_WAIT, blocking port reuse) and listener backlog mismatch (512 vs native 1024). Both fixed:
  - **DONE** `portable/Skt.zig:setLingerAbort` — was no-op with wrong comment. Now calls `pn.setLingerAbort(skt.fd)`.
  - **DONE** `posix_net/adapters/pn_utils.c` — new file: `bsd_set_linger_abort`, `pn_create_listen_socket`, `pn_create_listen_socket_unix`. Uses `bsd.h` (internal header — defines `LIBUS_SOCKET_ERROR`).
  - **DONE** `posix_net/ffi.zig` — 3 new extern declarations.
  - **DONE** `posix_net/socket.zig` — `setLingerAbort` wrapper.
  - **DONE** `posix_net/posix_net.zig` — `setLingerAbort` re-exported.
  - **DONE** `posix_net/creator.zig` — `createListenSocket` and `createListenSocketUnix` use `pn_create_listen_socket`/`pn_create_listen_socket_unix` with `backlog=1024`.
  - **DONE** `build.zig` — `pn_utils.c` wired into both `libMod` and `lib_unit_tests` portable blocks.
  - **Linux result:** 101/101 tests pass.
- **Windows UDS CI fix (2026-05-12):** `bsd_create_connect_socket_unix` in usockets `bsd.c` checks `errno != EINPROGRESS` after `connect()`. On Windows, non-blocking UDS connect sets `WSAGetLastError() == WSAEWOULDBLOCK`, not `errno == EINPROGRESS` — usockets treats it as a fatal error. Fixed by adding `pn_create_connect_socket_unix` to `posix_net/adapters/pn_utils.c`: Windows path re-implements the connect with `WSAGetLastError() != WSAEWOULDBLOCK` check; Linux path delegates to `bsd_create_connect_socket_unix`. Wired through `ffi.zig` and `creator.zig`.
- **macOS CI fix (2026-05-12):** Two bugs fixed. (1) `addrFamily` in `posix_net/socket.zig` read 2 bytes as `u16` from `sockaddr.mem[0]`. On macOS/BSD, `sockaddr` has `sa_len` (u8) at offset 0 and `sa_family` (u8) at offset 1 — the u16 read returns `sa_family * 256 + sa_len` instead of `sa_family`. Fixed with a comptime branch: macOS/BSD returns `addr.mem[1]`; Linux/Windows keeps the u16 read. (2) On macOS, non-blocking TCP connect to localhost may return `EINPROGRESS`; the tests then call `send()`/`getpeername()` immediately and get `ENOTCONN`. Fixed by adding `pn_wait_writable` to `pn_utils.c`: uses `select()` + `getsockopt(SO_ERROR)` to wait for connect completion. `resolveConnect` in `creator.zig` now calls `pn_wait_writable(fd, 5000)` after creating the connect socket.
- **macOS/Windows CI portable fixes (2026-05-13):** Two bugs fixed for CI. (1) `addrinfo` struct in `posix_net/ffi.zig` used wrong field layout on macOS/Windows. Linux glibc: `ai_addr` before `ai_canonname` with `ai_addrlen = socklen_t (4 bytes)`. macOS/BSD/Windows: `ai_canonname` before `ai_addr` with `ai_addrlen = SIZE_T (8 bytes on x64)`. Added two struct types (`addrinfo_posix` / `addrinfo_win`) and comptime dispatch: `if (.linux) addrinfo_posix else addrinfo_win`. Also added null guard for `ai_addr` in `creator.zig:resolveConnect`. (2) `pn_connect_socket` in `pn_utils.c` did not handle EALREADY/EISCONN on POSIX or WSAEALREADY/WSAEISCONN on Windows. The `initPair` retry loop calls `connect()` multiple times; second call returns EALREADY (already connecting) or EISCONN (already connected). Fixed: EALREADY → 1 (in progress), EISCONN → 0 (connected) on both platforms.
- **macOS CI portable fixes — Second Round (2026-05-13):** Four critical bugs fixed. (1) `LIBUS_SOCKET_WRITABLE` was defined as `4` (Linux/Windows bit) on Darwin/BSD, but uSockets uses `2` for kqueue; fixed in `types.zig`. (2) `fromEvents` in `triggers.zig` treated `EV_EOF` on a `READ` filter as a hard error; aligned with native macOS logic where `EV_EOF` is a read-ready event. (3) `accept()` in all portable backends incorrectly assigned the listener's address to new client sockets; added `toStdAddress` helper and fixed initialization in `Skt.zig`. (4) `addrinfo` struct layout corrected for BSD-based systems (`canonname` before `addr`, with `socklen_t` addrlen).
- **Pending:** Windows native 4-mode verification (`zbta_win.cmd`) after `build.zig.zon` update; macOS CI run to confirm final fixes pass.

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

### 2026-05-13: Gemini CLI — Stage 6: macOS CI portable backend fixes

#### Summary
Fixed several critical issues causing macOS CI failures for the portable backend. Root causes included mismatched socket constants (LIBUS_SOCKET_WRITABLE=4 instead of 2 on kqueue), incorrect EV_EOF handling (treated as error instead of read-ready), a major bug in `accept` (reused listener address for clients), and an incorrect `addrinfo` struct layout for BSD-based systems. All fixes were applied cross-platform where applicable, ensuring behavioral consistency across Linux, macOS, and Windows.

#### Changes
- `posix_net/types.zig` — Corrected `LIBUS_SOCKET_WRITABLE` for macOS/BSD; refined `AF_INET6` and `UDS_PATH_SIZE` conditions.
- `posix_net/ffi.zig` — Added `addrinfo_bsd` with correct field order (`canonname` before `addr`) and size for macOS/BSD.
- `posix_net/socket.zig` — Added `toStdAddress` helper; confirmed `addrFamily` layout for macOS.
- `src/ampe/portable/triggers.zig` — Updated `fromEvents` to handle kqueue-specific `EV_EOF` and `EV_ERROR` bits.
- `src/ampe/portable/linux/Skt.zig` — Fixed `accept` address initialization and `toAmpe` mapping.
- `src/ampe/portable/mac/Skt.zig` — Fixed same.
- `src/ampe/portable/win/Skt.zig` — Fixed same.

#### Verification
| Check | Result |
| :---- | :----- |
| `zig build test -Dnetwork=portable` (Linux, Debug) | ✅ PASS (101/101) |
| `addrinfo` layout (macOS) | ✅ verified vs std.c.zig |
| `LIBUS_SOCKET_WRITABLE` (macOS) | ✅ verified vs epoll_kqueue.h |

---

### 2026-05-13: Claude Code (Sonnet 4.6) — Stage 6: macOS/Windows CI portable fixes + legacy file cleanup

#### Summary

Three fixes for macOS CI (8 failures) and Windows CI (Notifier CommunicationFailed). Root cause 1: `addrinfo` struct in `posix_net/ffi.zig` used Linux glibc field order everywhere. macOS/BSD/Windows use BSD order — `ai_canonname` before `ai_addr`, with `ai_addrlen` as 8-byte `SIZE_T`. On macOS, the wrong layout caused `ai_addr` to read as null (field at wrong offset), triggering a "pointer cast to null" panic in `resolveConnect`. Fixed by splitting into `addrinfo_posix` (Linux) and `addrinfo_win` (everything else) with comptime dispatch. Root cause 2: `pn_connect_socket` returned -1 for EALREADY (POSIX) and WSAEALREADY (Windows). The `initPair` retry loop calls `connect()` in a loop; after first EINPROGRESS/WSAEWOULDBLOCK, subsequent calls get EALREADY. Treating EALREADY as a hard error caused Notifier `initPair` to fail on Windows and macOS connect-retry tests to fail. Fixed in `pn_utils.c`: EALREADY → 1 (in progress), EISCONN → 0 (connected) on both platforms. Also added null guard for `ai_addr` in `resolveConnect`. Cleanup: deleted `Skt_legacy.zig` and `SocketCreator_legacy.zig` (dead code — all three supported OSes have per-OS subfolders). Dispatch now uses `@compileError` for unsupported OS.

#### Changes
- `posix_net/ffi.zig` — split into `addrinfo_posix` + `addrinfo_win`; comptime dispatch `if (.linux) posix else win`; comment explaining layout difference
- `posix_net/creator.zig` — `resolveConnect`: null guard for `ai_addr` before `@ptrCast`; check `< 0` for `pn_connect_socket`
- `posix_net/adapters/pn_utils.c` — `pn_connect_socket`: EALREADY/EISCONN → in-progress/connected on POSIX; WSAEALREADY/WSAEISCONN same on Windows
- `src/ampe/portable/Skt.zig` — dispatch: `else => @compileError("portable backend: unsupported OS")`
- `src/ampe/portable/SocketCreator.zig` — dispatch: same
- `src/ampe/portable/Skt_legacy.zig` — DELETED
- `src/ampe/portable/SocketCreator_legacy.zig` — DELETED
- `design/AGENT_STATE.md` — v082→083

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build test -Dnetwork=portable` (Linux, Debug) | ✅ 101/101 |
| `zig build -Dtarget=x86_64-macos -Dnetwork=portable` | ✅ cross-compile OK |
| `zig build -Dtarget=aarch64-macos -Dnetwork=portable` | ✅ cross-compile OK |
| macOS CI (8 failures) | pending CI run |
| Windows CI (Notifier CommunicationFailed) | pending CI run |
