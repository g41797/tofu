# libevent Evaluation — Key Findings

**Date:** 2026-06-03
**Source:** `/home/g41797/Downloads/libevent-evaluation-claude.md` (full report)
**Status:** Findings only. No code changes proposed. Architectural decisions require author approval.

---

## 1. Central fact

libevent is a polling library only. It does not provide socket I/O.

The user must own every socket call:

- `socket`, `bind`, `listen`, `accept`, `connect`
- `send`, `recv`, `close`, `shutdown`
- `setsockopt`, `getsockname`
- `getaddrinfo`
- errno / `WSAGetLastError` mapping
- EINTR retry, UDS path handling, non-blocking mode

libevent ships small helpers in `event2/util.h`:

- `evutil_socket_t`
- `evutil_make_socket_nonblocking`
- `evutil_make_listen_socket_reuseable`
- `evutil_closesocket`

These cover roughly 5% of what uSockets `bsd.c` provides.

libevent's `bufferevent_*` API does perform I/O internally. Tofu cannot use it.
It calls `recv` into an internal buffer. This breaks tofu's pool-based backpressure.
Same reason that ruled out uSockets `us_socket_t`.

---

## 2. What maps cleanly

| Tofu Trigger | libevent equivalent | Class |
| :--- | :--- | :--- |
| `recv` | `EV_READ` on socket fd | Native |
| `send` | `EV_WRITE` on socket fd | Native |
| `accept` | `EV_READ` on listener fd | Native |
| `connect` | `EV_WRITE` on connecting fd | Native |
| `notify` | `EV_READ` on Notifier receiver | Native |
| `err` | `EV_CLOSED` (libevent 2.1+) or EOF on recv | Easy mapping |
| `timeout` | `event_base_loopexit(base, &tv)` before each loop call | Native |
| `pool` | Stays in PollerCore reconciliation | Not OS-observable |

Per-fd userdata is `void *arg` in `event_new(...)`. The `SeqN` passes as `arg`.
No weak-symbol override is needed. The current `us_internal_dispatch_ready_poll`
override pattern goes away.

Tick model: `event_base_loop(base, EVLOOP_ONCE)` with `event_base_loopexit`
for timeout. Matches tofu's Reactor "pull" loop.

---

## 3. The one architectural impedance

libevent has no equivalent of `EPOLL_CTL_MOD`. Changing watched events on an fd
requires `event_del + event_assign + event_add`.

PollerCore reconciliation already calls `modify` only when triggers change.
Cost is one extra syscall pair per change. Negligible for tofu's workload.

---

## 4. Windows

libevent ships a native `wepoll` backend since the 2.2 series.

This removes the entire Windows adapter layer:

- `sys/epoll.h`
- `sys/timerfd.h`
- `sys/eventfd.h`

Those headers existed for the uSockets *loop* layer (`epoll_kqueue.c`).
With libevent owning the loop, `bsd.c` on Windows compiles against
`winsock2.h` directly.

---

## 5. Sockets layer — vendor vs port

Two options for the socket-side after libevent takes over polling.

### Option A — Vendor `bsd.c` + `bsd.h` + `pn_utils.c` into tofu (RECOMMENDED)

Extract only the socket files from the uSockets fork. Commit them into tofu's tree
as a tofu-owned C module. Drop everything else (`loop.c`, `socket.c`, `context.c`,
`eventing/*`, `internal/internal.h`, `internal/loop_data.h`, `udp.c`, `quic.c`).

Apply tofu's existing patches directly to the vendored copy. The patches
stop being "fork patches". They become "tofu's version of `bsd.c`".

Keep `posix_net/wrapper/{ffi,socket,creator,types}.zig` Zig facade verbatim.

Costs:

- ~50 LOC build glue
- ~900 LOC vendored C
- Zero new Zig sockets code

Gains:

- Fork goes away. No dual-path patching.
- No weak-symbol override.
- No Windows adapter layer (see §4).
- Battle-tested socket behavior from uWebSockets / Bun.
- Apache 2.0 license is already accepted.

### Option A2 — Write a minimal C adapter from scratch (`pn_socket.c`)

Middle option. Tofu-owned C from line 1. No uSockets heritage.

Implement only the symbols tofu uses (~15 functions). Call libc / Winsock2 directly.

Honest size: ~250–400 LOC C, not ~120. Reasons:

- Winsock2 type mismatches (`SOCKET` vs `c_int`, narrowed return types).
- macOS 104-byte `sun_path` chdir workaround.
- Linux abstract UDS namespace.
- Windows `SIO_TCP_INITIAL_RTO` loopback fast-fail.
- `MSG_NOSIGNAL` (Linux) vs `SO_NOSIGPIPE` (macOS) vs neither (Windows).
- Three per-OS `addrinfo` struct layouts.
- EINTR retry loops per syscall.

All of these are battle-tested inside the vendored `bsd.c`.

Gains over Option A:

- No third-party heritage.
- No license tracking.
- No upstream drift.

Costs over Option A:

- Reimplements code that already works.
- Production verification on three OSes is greenfield work.
- Risk of reintroducing edge-case bugs fixed years ago in `bsd.c`.

When Option A2 makes sense:

- If the author has a strategic objection to vendored third-party C.
- If `bsd.c`'s 876 LOC is judged too large to vendor.

### Option B — Port `bsd.c` to pure Zig

Write a new Zig module via `extern "c" fn` (POSIX) and `extern "ws2_32" fn` (Windows).

Costs:

- ~560 LOC new Zig total
  - Shared facade: ~150 LOC
  - Linux: ~80 LOC
  - macOS / BSD: ~100 LOC
  - **Windows (Winsock2): ~200 LOC** (largest share — see §6)
  - Build glue: ~30 LOC

Gains:

- No vendored C for the socket layer (`wepoll/` stays as today).
- Tofu owns the full Zig surface.

Path B is optional. Tofu vendors `wepoll/` C already. "No vendored C" is not
a current project invariant.

### Recommendation

Adopt Option A as the default destination.

Option A2 (minimal C from scratch) is a viable alternative if the author has
strategic reasons to avoid uSockets-origin code.

Option B (pure Zig port) is optional polish for later. Not required.

Every headline maintenance gain comes from Option A alone:

- No fork ✓
- No dual-path patching ✓
- No weak-symbol override ✓
- No Windows adapter layer ✓
- System-distributable libevent + vendored `bsd.c` ✓
- Zig 0.16 safe ✓

---

## 6. Per-OS C library mapping (for Option B)

Reference for the Zig sockets API if Option B is chosen later.

| Concern | POSIX (Linux/macOS/BSD) | Windows |
| :--- | :--- | :--- |
| C library linked | `libc` | `ws2_32.dll` |
| Socket handle type | `c_int` | `SOCKET` = `usize` |
| Invalid sentinel | `-1` | `INVALID_SOCKET` |
| Error indicator | `-1` + `errno` | `SOCKET_ERROR` + `WSAGetLastError()` |
| Lifecycle | none | `WSAStartup` / `WSACleanup` |
| Close | `close(fd)` | `closesocket(s)` |
| Non-blocking | `fcntl(fd, F_SETFL, O_NONBLOCK)` | `ioctlsocket(s, FIONBIO, &one)` |
| Send/recv return | `ssize_t` | `int` |
| Would-block | `EAGAIN` / `EWOULDBLOCK` | `WSAEWOULDBLOCK` |
| Accept (non-blocking) | `accept4` on Linux; `accept` + `fcntl` on macOS | `accept` + `ioctlsocket` |
| Connect loopback fast-fail | n/a | `WSAIoctl(SIO_TCP_INITIAL_RTO)` |
| Abstract UDS | Linux only: `sun_path[0] = 0` | Not supported |
| `sun_path` length | 108 (Linux) / 104 (macOS) | 108 |
| `MSG_NOSIGNAL` substitute | `SO_NOSIGPIPE` on macOS | n/a (no SIGPIPE on Windows) |

Roughly half of this is already encoded in `posix_net/wrapper/types.zig`
and `wrapper/ffi.zig`. Option B is partly translation, partly new work.

---

## 7. Zig 0.16 risk

Path A: vendored C is decoupled from Zig stdlib. No `std.posix` / `std.net` on
the critical path. Safe.

Path B: `extern fn` to libc / `ws2_32` is a core Zig language feature, not stdlib.
No dependency on `std.posix` / `std.net`. Safe.

Both options remove the Zig 0.16 risk from the socket layer.

---

## 8. uSockets API surface used by tofu today

Counted from `posix_net/wrapper/ffi.zig`.

### Polling (replaced by libevent)

- `us_create_loop`, `us_loop_free`, `us_loop_run_tick` (★ tofu-patched)
- `us_create_poll`, `us_poll_free`, `us_poll_init`
- `us_poll_start`, `us_poll_change`, `us_poll_stop`
- `us_poll_ext`, `us_internal_poll_type`
- `us_internal_dispatch_ready_poll` (★ tofu-overridden weak symbol)

### Socket (replaced by vendored `bsd.c` in Option A, or Zig port in Option B)

- `bsd_create_socket`, `bsd_create_listen_socket`, `bsd_create_listen_socket_unix`
- `bsd_accept_socket`, `bsd_connect_socket_unix`
- `bsd_recv`, `bsd_send`
- `bsd_close_socket`, `bsd_shutdown_socket`, `bsd_shutdown_socket_read`
- `bsd_set_nonblocking`, `bsd_socket_nodelay`
- `bsd_socket_keepalive` (★ tofu-added)
- `bsd_set_linger_abort` (★ tofu-added, in `pn_utils.c`)
- `bsd_would_block`
- `bsd_local_addr`, `bsd_remote_addr`
- `bsd_addr_get_port`, `bsd_addr_get_ip`, `bsd_addr_get_ip_length`

### Tofu-owned helpers (already in `pn_utils.c`)

- `pn_create_listen_socket`
- `pn_create_listen_socket_unix`
- `pn_create_connect_socket_unix`
- `pn_create_listen_socket_from_sockaddr`
- `pn_connect_socket`
- `pn_wait_writable`

### DNS (via libc, unchanged)

- `getaddrinfo`, `freeaddrinfo`

Three symbols carry tofu patches (`us_loop_run_tick`,
`us_internal_dispatch_ready_poll`, the `pathlen`-aware UDS variants).
Patches go away under Option A by becoming part of the vendored copy.

---

## 9. Effort estimate

### Polling layer (always required)

- `libeventnet_backend.zig` — ~200 LOC Zig
- Build glue (libevent linking) — ~30 LOC

### Sockets layer

| Option | Cost |
| :--- | :--- |
| A — vendor `bsd.c` + `bsd.h` + `pn_utils.c` | ~50 LOC build glue, ~900 LOC vendored C, zero new Zig |
| B — port to pure Zig | ~560 LOC new Zig + ~30 LOC build glue |

### Sunset stages (after libeventnet validates)

- Drop `posixnet/` — ~1,200 LOC deleted
- Drop uSockets fork as a build.zig.zon dependency — build simplification
- Drop `stdposix/` once libeventnet is the default — additional code removal

---

## 10. Recommended sequencing

Each stage ships independently.

1. **Add `libeventnet` platform alongside `posixnet`.** Linux first.
   - Implement `libeventnet_backend.zig`.
   - Vendor `bsd.c` + `bsd.h` + `pn_utils.c` (Option A).
   - Reuse `posix_net/wrapper/*.zig` Zig facade.
   - Gate behind `-Dnetwork=libeventnet`.

2. **Extend libeventnet to macOS and Windows.**
   - libevent's native `wepoll` backend covers Windows.
   - No adapter headers needed.

3. **Run contract tests against libeventnet for at least one CI cycle on all three OSes.**
   - `tests/ampe/sockets_tests.zig`
   - `tests/ampe/Notifier_tests.zig`
   - `tests/pollercore_tests.zig`

4. **Deprecate `posixnet`.** Remove from CI matrix.

5. **Deprecate `stdposix`** once libeventnet has been the default for at least one release.

6. **(Optional) Port vendored `bsd.c` to pure Zig (Option B).**
   Only if a project goal requires removing all vendored socket C.

---

## 11. Risks

| Risk | Severity | Mitigation |
| :--- | :--- | :--- |
| libevent's `wepoll` on Windows behaves differently from tofu's current vendored `wepoll` | Medium | Same upstream `wepoll`, just integrated. Run existing Windows contract tests first. |
| `EV_CLOSED` not delivered on all libevent backends | Low | Fall back to EOF detection via `recv() == 0` (already in `pn.recvToBuf`). |
| Vendored `bsd.c` drift from upstream | Low | Pin to known-good commit. Re-sync periodically only when needed. |
| Three backends in CI matrix during transition | Low | Stage 9 partitioning already supports per-network test gating. |
| Option B per-OS errno mapping mistakes (if chosen later) | Medium | Existing `tests/ampe/sockets_tests.zig` is platform-independent by design. |

---

## 12. Open questions for the author

1. Adopt libeventnet as a third platform alongside `posixnet` and `stdposix`?
2. Confirm Option A (vendor `bsd.c`) as the recommended path?
3. Confirm sunset order: `posixnet` first, then `stdposix`?
4. Build choice: link system libevent, or vendor libevent in `build.zig.zon`?
5. Should Option B (pure-Zig port) be tracked as a follow-up, or removed from scope?

---

## 13. libevent build configuration

Strategy distilled from the parallel agy evaluation (`libevent-evaluation-agy.md`).
Keeps `build.zig` simple and the binary small.

### 13.1 Core-only file list

Compile only the files tofu needs.

Always:

- `event.c`, `evmap.c`, `evutil.c`, `evutil_rand.c`, `evutil_time.c`
- `log.c`, `signal.c`

Per OS:

- Linux: `epoll.c`, `epoll_sub.c`
- macOS / BSD: `kqueue.c`
- Windows: `wepoll.c`

Excluded:

- `evdns.c` — tofu uses libc `getaddrinfo`.
- `evhttp.c`, `evrpc.c`, `http.c` — protocol layers.
- `bufferevent_*.c` — buffered I/O violates pool backpressure.
- `bufferevent_openssl.c`, `bufferevent_mbedtls.c` — TLS.
- `event_iocp.c`, `buffer_iocp.c` — IOCP not used.
- `ws.c`, `evrpc*`, `event_tagging.c` — unused.

### 13.2 Static `event-config.h`

libevent expects `event-config.h` with feature macros. Upstream generates it
via CMake. Tofu does not use CMake.

Recommendation: commit one static `event-config.h` under
`src/platform/libeventnet/event/` with preprocessor branches.

```c
#if defined(__linux__)
  #define EVENT__HAVE_EPOLL 1
  #define EVENT__HAVE_EVENTFD 1
#elif defined(__APPLE__) || defined(__FreeBSD__)
  #define EVENT__HAVE_KQUEUE 1
#elif defined(_WIN32)
  #define EVENT__HAVE_WEPOLL 1
#endif

#define EVENT__VERSION "2.2.1-tofu"
#define EVENT__DISABLE_THREAD_SUPPORT 1
```

`build.zig` adds the include path. No per-platform flag plumbing.

### 13.3 Disable thread support

Tofu runs single-threaded per Reactor. libevent's locks are dead code.

Define `EVENT__DISABLE_THREAD_SUPPORT` in `event-config.h`.

Effects:

- No lock acquisition in `event_*` paths.
- No pthreads / Windows critical section dependency.
- Smaller binary.
- `evthread_use_*` becomes no-ops. Tofu does not call them.

The Notifier socketpair already handles cross-thread wakeup at the tofu layer.

### 13.4 `err` mapping — two options

Both work. Decide once.

**Option α — `EV_CLOSED`.**
libevent 2.1+ feature. Requires `EV_FEATURE_EARLY_CLOSE`.
Delivered as a flag in the callback `what`. Idiomatic.

**Option β — `getsockopt(SO_ERROR)`.**
Portable across all libevent versions. Called from callback when needed.
Slightly more work. Works everywhere.

Recommendation: start with Option α on epoll and kqueue. Fall back to Option β
on backends that lack `EV_CLOSED`. EOF on `recv` already maps to
`PeerDisconnected` in `pn`.

---

## 14. Option B vs Option C — sequencing disagreement

The parallel agy evaluation recommends **Option C (replace `posixnet`)**.
This document recommends **Option B (add `libeventnet` alongside, then sunset)**.

Both reports agree on the end state:

- libevent for polling.
- Tofu-owned socket layer (vendored `bsd.c` or equivalent).
- `posixnet` and `stdposix` retired.

The difference is sequencing risk, not direction.

| Approach | Pro | Con |
| :--- | :--- | :--- |
| Option B (this report) | Parallel platforms during validation. Each step independently shippable. CI safety net. Matches RULES.md §0 4-mode rule and §4 sandwich rule. | Two backends in tree during transition. Doubled CI matrix for one release cycle. |
| Option C (agy report) | Single step. No transition duplication. Smaller end-state code surface throughout. | Big-bang risk. All three OSes must pass before merge. Regression of `posixnet` mid-flight has no fallback. |

This is properly the author's call. The recommendation in §5 stands as
Option B but should be read as a sequencing preference, not a hard
architectural requirement.

---

## 15. Clone strategy — `posixnet/` → `libeventnet/`

`libeventnet/` should be **cloned from** `posixnet/`, not built by sharing files.

### 15.1 Why clone

- The transition is time-bounded. After sunset, only `libeventnet/` remains.
- RULES.md §6 already establishes "same shape, different engine" as the project pattern.
- The wrapper layer diverges. Posixnet keeps `poll.zig`, the uSockets dispatch hook,
  and `adapters/sys/*.h` Windows headers. Libeventnet needs none of these.
- The fork dependency stays isolated. Posixnet's `ffi.zig` points at the uSockets
  fork via `build.zig.zon`. Libeventnet's `ffi.zig` points at vendored `bsd.c` in-tree.
- Edits to the clone cannot regress posixnet's CI during the validation period.

### 15.2 Target folder layout

```
src/platform/libeventnet/                ← cloned from posixnet/
├── libeventnet_backend.zig              ← NEW (replaces posixnet_backend.zig)
├── triggers.zig                         ← REWRITE (EV_READ/EV_WRITE replace LIBUS_SOCKET_*)
├── linux/
│   ├── Skt.zig                          ← CLONE verbatim from posixnet/linux/Skt.zig
│   └── SocketCreator.zig                ← CLONE verbatim
├── mac/{Skt,SocketCreator}.zig          ← CLONE verbatim
├── windows/{Skt,SocketCreator}.zig      ← CLONE verbatim
└── csocket/                             ← NEW C module (replaces wrapper/)
    ├── bsd.c                            ← VENDOR from uSockets fork (with tofu patches applied)
    ├── bsd.h                            ← VENDOR
    ├── pn_utils.c                       ← VENDOR (already tofu-owned)
    └── facade/                          ← cloned & trimmed from posixnet/wrapper/
        ├── ffi.zig                      ← CLONE, drop us_* poll declarations, keep bsd_* and pn_*
        ├── socket.zig                   ← CLONE verbatim
        ├── creator.zig                  ← CLONE verbatim
        ├── types.zig                    ← CLONE verbatim
        └── csocket.zig                  ← CLONE of posix_net.zig facade (renamed module)
```

### 15.3 File-by-file change classification

| File in `posixnet/wrapper/` | Status in `libeventnet/csocket/facade/` |
| :--- | :--- |
| `poll.zig` | Removed. libevent owns the loop. |
| `adapters/us_epoll_win.c` | Removed. No `epoll_kqueue.c` to compile on Windows. |
| `adapters/sys/epoll.h` | Removed. Not needed for `bsd.c`. |
| `adapters/sys/timerfd.h` | Removed. Not needed for `bsd.c`. |
| `adapters/sys/eventfd.h` | Removed. Not needed for `bsd.c`. |
| `adapters/win_compat.h` | Keep if `bsd.c` includes it on Windows. Verify after vendoring. |
| `adapters/pn_utils.c` | Keep. Move into `csocket/` as a vendored file. |

### 15.4 Per-file edit summary

- `ffi.zig` clone:
    - Keep all `bsd_*` and `pn_*` declarations.
    - Keep the `addrinfo` per-OS struct definitions.
    - Keep `getaddrinfo`, `freeaddrinfo`, `unlink`, `_unlink`.
    - Remove `us_create_loop`, `us_loop_free`, `us_loop_run_tick`.
    - Remove `us_create_poll`, `us_poll_free`, `us_poll_init`, `us_poll_start`,
      `us_poll_change`, `us_poll_stop`, `us_poll_ext`, `us_internal_poll_type`.
- Per-OS `Skt.zig` and `SocketCreator.zig`:
    - No code edits.
    - Change one import: `@import("posix_net")` → `@import("csocket")`.
- `triggers.zig` rewrite:
    - Replace `LIBUS_SOCKET_READABLE` with `EV_READ`.
    - Replace `LIBUS_SOCKET_WRITABLE` with `EV_WRITE`.
    - Add `EV_CLOSED` mapping for `err`.
    - Drop the macOS `EV_ERROR` / `EV_EOF` branch — libevent normalizes those.
- `libeventnet_backend.zig` (new):
    - Same `PollerCore<Backend>` shape as `posixnet_backend.zig`.
    - Replace `pn.poll.*` calls with `event_*` calls.
    - Replace the `us_internal_dispatch_ready_poll` weak override with a libevent
      callback that reads `SeqN` from the event's `void *arg`.

### 15.5 Sunset of `posixnet/`

When libeventnet has been the default for one release:

- Delete `src/platform/posixnet/` (entire folder).
- Remove uSockets from `build.zig.zon`.
- Remove the `-Dnetwork=posixnet` build option.
- Remove posixnet from CI matrix.

The vendored `bsd.c` under `libeventnet/csocket/` survives. The dual-path
patching dance disappears with the fork.

### 15.6 RULES.md §6 update (for the author)

Today RULES.md §6 covers "posix backends" and "the portable backend".
After libeventnet is added, §6's "same shape, different engine" rule should
explicitly cover three backends:

- `stdposix` — Zig stdlib / syscalls
- `posixnet` — uSockets fork via FFI
- `libeventnet` — libevent + vendored `bsd.c` via FFI

Not edited here. Requires author approval per §0.

---

*End of findings.*
