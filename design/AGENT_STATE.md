# Agent State & Handover

**Current Version:** 086
**Last Updated:** 2026-05-15
**Last Agent:** Gemini CLI
**Active Phase:** Stage 6 — Investigating macOS POSIX backend failures; diagnostic testing.

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
- Stage 0.5 through Stage 6 (portable) are largely complete; cross-platform CI is passing for portable.
- **Current investigation:** `pollercore_tests.zig` fails on macOS for the native (`posix`) backend. Specifically, `TCP accept recv send via PollerCore` triggers a `recv` event but returns an empty queue.
- **Diagnostic steps (2026-05-15):** 
  - Added `Raw TCP connectivity` test to `tests/pollercore_tests.zig` to verify basic socket wrappers without poller logic.
  - Added explicit assertions for `sendBuf` return values to detect premature success or `WouldBlock` conditions.
  - Identified discrepancy in `mac/Skt.zig`: `EALREADY` is treated as "connected" (`true`), which may cause premature sends before the TCP handshake completes.
  - Noted Darwin-specific socket creation constraints (missing `SOCK_NONBLOCK`/`SOCK_CLOEXEC` in `socket()` call) and verified they are handled via `fcntl` in `acceptOs` but checked `SocketCreator.zig` for similar logic.

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

### 2026-05-15: Gemini CLI — Investigation of macOS POSIX backend failures

#### Summary
Investigated failing `pollercore_tests.zig` on macOS. The test `TCP accept recv send via PollerCore` fails because the server receives a `recv` trigger but `tryRecv()` returns an empty message queue. Suspect issues with non-blocking socket initialization or premature connection success reporting. Added diagnostic tests to isolate the failure between raw socket logic and kqueue/poller logic.

#### Changes
- `tests/pollercore_tests.zig` — Added `Raw TCP connectivity` diagnostic test; added assertions for `sendBuf` results.

#### Verification
| Check | Result |
| :---- | :----- |
| `zig build test` (Linux, Debug) | ✅ PASS (65/65) |
| macOS failure analysis | Pending diagnostic run |

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

### 2026-05-14: Gemini CLI — Stage 6: Heap allocation for TriggeredChannel in portable tests

#### Summary
Migrated `TriggeredChannel` instances in `tests/ampe/portable_poller_tests.zig` from stack allocation to heap allocation using `gpa.create()`. This change ensures pointer stability for `TriggeredChannel` objects, particularly when `ArrayHashMap.swapRemove` might cause map reallocations. Heap allocation guarantees that pointers remain valid throughout the test execution, preventing potential issues with stale data and improving test reliability. Corresponding `defer gpa.destroy()` calls have been added for proper memory management.

#### Changes
- `tests/ampe/portable_poller_tests.zig` — Updated `portable backend: map stability with notifier`, `wait with data`, `accept flow`, and `full echo` tests to use heap-allocated `TriggeredChannel` instances via `gpa.create()` and `gpa.destroy()`.

#### Verification
| Check | Result |
| :---- | :----- |
| `zig build test -Dnetwork=portable` (Linux, Debug) | ✅ PASS (after previous fixes) |
| `zig build test -Dnetwork=portable` (macOS, Debug) | pending CI run |

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
