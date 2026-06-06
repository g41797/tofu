# Evaluation: libevent as a Long-Term Networking Backend for tofu on Zig 0.16

**Date:** 2026-06-03
**Author:** Claude (Opus 4.7)
**Subject repos:**

* `tofu` — `/home/g41797/dev/root/github.com/g41797/tofu`
* `uSockets` fork — `/home/g41797/dev/root/github.com/g41797/uSockets`
* `libevent` — `/home/g41797/Downloads/libevent-master/`

**Scope:** architectural suitability, maintenance cost, feature coverage, implementation effort. **Not** a benchmark.

---

## 1. Executive Summary

libevent **can** implement the current tofu backend contract. The fit is good but
not perfect, and the migration cost is real because the impedance mismatch lives
not in *polling* (which is a clean swap) but in *socket-level wrappers*
(`bsd_send`/`bsd_recv`/`bsd_create_listen_socket`) that the posixnet backend
currently reuses from the uSockets fork.

### 1.1 Central fact: libevent is a polling library, not a sockets library

**libevent provides only event-loop and readiness-notification abstractions.**
It performs no socket I/O on the user's behalf. Every socket operation —
`create`, `bind`, `listen`, `accept`, `connect`, `send`, `recv`, `close`,
`setsockopt`, address parsing, DNS resolution, errno handling — is the **caller's
responsibility**.

This is the opposite of uSockets, which is a polling abstraction **plus** a
complete BSD-sockets wrapper (`bsd.c`, ~876 LOC) that tofu's posixnet backend
relies on today.

**Consequence:** adopting libevent obligates tofu to **develop and own a Zig
sockets API** (a thin BSD-wrapper module) to replace the socket-side of
uSockets. This is the single largest cost of the migration and the single most
important architectural commitment to weigh.

### 1.2 Headline numbers (recommended path)

* Polling layer swap (`posixnet_backend.zig` → `libevent_backend.zig`): **~200 LOC Zig**.
* **Vendor `bsd.c` + `bsd.h` + `pn_utils.c` from uSockets into tofu's tree**
  (~900 LOC of battle-tested C, tofu-owned, no fork): **~50 LOC of build glue**.
  The existing `posix_net/wrapper/*.zig` Zig facade is reused verbatim.
* The `Skt` / `SocketCreator` Zig files in `posixnet/{linux,mac,windows}/`
  keep their shape — they re-import the same Zig facade over the vendored C.
* Optional later: port `bsd.c` to pure Zig (~560 LOC). Not required.

### 1.3 Recommendation

**Option B — Add a `libeventnet` platform** alongside the existing `posixnet`,
implemented via libevent (polling) + vendored `bsd.c`/`bsd.h`/`pn_utils.c`
(sockets) + reused Zig facade. Defined sunset for `posixnet` once `libeventnet`
reaches feature parity on all three platforms. Detailed justification in §10.

The recommendation does **not** require rewriting socket operations in Zig.
The §1.1 fact (libevent is polling-only) is addressed by vendoring the C
socket layer that tofu already depends on, rather than by reimplementing it.
Path 2 (full Zig port) remains an *optional* end-state, not a prerequisite.

---

## 2. Architecture: What tofu Actually Needs from a Backend

The tofu backend contract is small and well-defined. PollerCore
(`src/ampe/core.zig:15`) expects a generic `Backend` providing:

```
fn init(allocator) AmpeError!Backend
fn deinit(*Backend) void
fn register(*Backend, fd, seq, exp: Triggers) AmpeError!void
fn modify(*Backend, fd, seq, exp: Triggers) AmpeError!void
fn unregister(*Backend, fd) void
fn wait(*Backend, timeout, *SeqnTrcMap) AmpeError!Triggers
```

That's it. The rest of the architecture lives above the backend boundary.

### 2.1 Layer diagram

```
┌─────────────────────────────────────────────────────────┐
│ Reactor.zig            (single-threaded "pull" loop)    │
├─────────────────────────────────────────────────────────┤
│ TriggeredChannel  ──┐   (heap-stable, ABA-protected)    │
│   ├─ TriggeredSkt   │                                   │
│   │   ├─ NotificationSkt                                │
│   │   ├─ AcceptSkt                                      │
│   │   ├─ IoSkt   (MsgSender + MsgReceiver)              │
│   │   └─ DumbSkt                                        │
│   ├─ exp: Triggers ─┘   ← computed each tick (pull)     │
│   └─ act: Triggers      ← updated by backend            │
├─────────────────────────────────────────────────────────┤
│ PollerCore<Backend>      (dual map: ChN → SeqN → *TC)   │
│   reconciliation loop:                                  │
│     for tc in seqn_trc_map:                             │
│       new_exp = tc.tskt.triggers()                      │
│       if new_exp != tc.exp:                             │
│         backend.modify(fd, seq, new_exp)                │
│     backend.wait(timeout, &seqn_trc_map)                │
├─────────────────────────────────────────────────────────┤
│ Backend  ←── ★ THE REPLACEABLE PART ──★                 │
│   stdposix: epoll | kqueue | wepoll  (Zig std.posix)    │
│   posixnet: uSockets us_poll_t       (C via FFI)        │
│   libeventnet: libevent event/event_base (proposed)     │
└─────────────────────────────────────────────────────────┘
                          │
                          ↓
                    fd → OS event source
```

### 2.2 Event-delivery diagram

```
OS readiness
    ↓
Backend.wait()
    ↓                  (sets tc.act for each ready TC,
seqn_trc_map.get(seq)   returns aggregated total_act)
    ↓
PollerCore.waitTriggers() returns Triggers
    ↓
Reactor consumes per-TC: tryRecv / trySend / tryAccept / tryConnect
    ↓
user-visible message in Channel
```

### 2.3 Invariants the backend must honor

| Invariant | Source |
| :--- | :--- |
| `*TriggeredChannel` is heap-stable for its lifetime | `core.zig:54` |
| `SeqN` (u64) is the dispatch token — must be returnable on event delivery | `common.zig:9`, `core.zig:50` |
| `Triggers` is a packed `u8` of {notify, accept, connect, send, recv, pool, err, timeout} | `triggeredSkts.zig:4` |
| Manual I/O (no auto-recv on readiness — preserves pool backpressure) | `transition-2-usockets.md §6` |
| No threads owned by backend — single reactor thread drives the tick | `transition-2-usockets.md §8` |

### 2.4 The `pool` trigger is **not** an OS concern

`Triggers.pool` is set when the message pool is empty and a recv is pending. It is
synthesized by `MsgReceiver.recvIsPossible()` (`triggeredSkts.zig:773`) and merged
in PollerCore reconciliation, **never** delivered by an OS event. Any backend just
needs to ignore it — it survives a backend swap automatically.

---

## 3. Findings: stdposix Backend

### 3.1 Inventory

```
src/platform/stdposix/
├── linux/
│   ├── epoll_backend.zig     105 LOC   epoll_create1/ctl/wait
│   ├── triggers.zig           35 LOC   Triggers ↔ EPOLLIN/OUT
│   ├── Skt.zig               369 LOC   std.posix socket ops
│   └── SocketCreator.zig     199 LOC
├── mac/
│   ├── kqueue_backend.zig    145 LOC   kevent
│   ├── triggers.zig           ~50 LOC  Triggers ↔ EVFILT_*
│   ├── Skt.zig                ~       std.posix socket ops
│   └── SocketCreator.zig      ~
└── windows/
    ├── wepoll_backend.zig    131 LOC   wepoll FFI declared inline
    ├── triggers.zig           ~       Triggers ↔ EPOLLIN/OUT (wepoll)
    ├── Skt.zig                ~       ws2_32 socket ops
    └── SocketCreator.zig      ~
```

### 3.2 What stdlib provides

| Concern | Source |
| :--- | :--- |
| epoll syscall wrappers | `std.posix.epoll_create1`, `epoll_ctl`, `epoll_wait` |
| kqueue syscall wrappers | `std.posix.kqueue`, `kevent` |
| Socket syscalls | `std.posix.socket/bind/listen/accept/connect/send/recv/close` |
| Address types | `std.posix.sockaddr`, `socklen_t` |
| Error type | `std.posix.E` enum |

### 3.3 What tofu provides on top

| Component | Purpose |
| :--- | :--- |
| `Skt.acceptOs` | Hand-rolled accept that works on both Linux (accept4) and macOS (accept + fcntl) |
| `Skt.connectOs` | EINTR retry + tofu-specific error mapping |
| `Skt.setLingerAbort` | Raw `setsockopt` to bypass Zig's "EINVAL is unreachable" assertion |
| `triggers.zig` | `Triggers` ↔ EPOLLIN/OUT/RDHUP/PRI mapping with priority rules (recv > notify > accept on IN; send > connect on OUT) |
| `epoll_backend.wait` | Loop over `epoll_event[]`, look up `tc` via `seqn_trc_map.get(ev.data.u64)`, merge `tc.act` |

### 3.4 Register / modify / unregister / wait

Identical shape across all three OS variants. The Linux flow is the cleanest:

```zig
register: epoll_ctl(epfd, ADD, fd, {events=mask, data.u64=seq})
modify:   epoll_ctl(epfd, MOD, fd, {events=mask, data.u64=seq})
unregister: epoll_ctl(epfd, DEL, fd, null)
wait:     n = epoll_wait(epfd, evs, timeout)
          for ev in evs[0..n]: seqn_trc_map.get(ev.data.u64).?.act |= map(ev.events)
```

Both register/modify dual-recover (`ADD` falls through to `MOD` if already present
and vice versa), which gives idempotent semantics that PollerCore relies on. **Any
replacement backend must replicate this idempotency** or PollerCore reconciliation
would need a separate state tracking layer.

### 3.5 Abstractions to preserve

The PollerCore generic plus the `register/modify/unregister/wait` contract is the
full backend interface. Everything else (Triggers semantics, dual map, mark-for-delete
queue) is generic and never touches the OS.

### 3.6 Zig 0.16 risk

`std.posix.*` and `std.net.*` are being removed. The stdposix backend is the
**most exposed** part of the codebase: every Skt, SocketCreator, and the three
backend implementations rely on `std.posix` directly. tofu has already mitigated
this for posixnet (via the `posix_net` wrapper, `pn.*`), but **stdposix has no
migration path today** beyond being deprecated wholesale.

---

## 4. Findings: posixnet Backend

### 4.1 Inventory

```
src/platform/posixnet/
├── posixnet_backend.zig         145 LOC   PollerCore<PosixNetBackend>
├── triggers.zig                  46 LOC   Triggers ↔ LIBUS_SOCKET_READABLE/WRITABLE
├── linux/Skt.zig                133 LOC   bsd_* via pn.*
├── linux/SocketCreator.zig      ~150 LOC
├── mac/{Skt,SocketCreator}.zig  ~        (similar)
├── windows/{Skt,SocketCreator}  ~        (similar; SOCKET = usize)
└── wrapper/                     ~600 LOC  C-extern wrapper module exposed as `pn`
    ├── ffi.zig                  100 LOC   pure extern declarations
    ├── socket.zig               153 LOC   sendBuf/recvToBuf/accept/connect/...
    ├── creator.zig               99 LOC   createListenSocket/etc.
    ├── poll.zig                  62 LOC   us_create_loop/us_poll_*
    ├── types.zig                107 LOC   Addr, Fd, error enum
    └── adapters/                 *.c/h    Windows shims + pn_utils.c
```

### 4.2 uSockets API surface used

The backend uses **only** the polling primitives + raw BSD wrappers — **never** the
high-level `us_socket_t` / context / SSL / HTTP layers.

| Group | Symbols used |
| :--- | :--- |
| Loop | `us_create_loop`, `us_loop_free`, `us_loop_run_tick` (★ custom-patched) |
| Poll | `us_create_poll`, `us_poll_free`, `us_poll_init`, `us_poll_start`, `us_poll_change`, `us_poll_stop`, `us_poll_ext`, `us_internal_poll_type` |
| Dispatch | `us_internal_dispatch_ready_poll` (★ **weak symbol overridden** by tofu) |
| Sockets | `bsd_create_socket`, `bsd_create_listen_socket(_unix)`, `bsd_accept_socket`, `bsd_connect_socket_unix`, `bsd_recv`, `bsd_send`, `bsd_close_socket`, `bsd_shutdown_socket(_read)`, `bsd_set_nonblocking`, `bsd_socket_nodelay`, `bsd_socket_keepalive` (★ added by tofu), `bsd_would_block`, `bsd_addr_get_port`, `bsd_local_addr`, `bsd_remote_addr`, `bsd_addr_get_ip(_length)` |
| Custom helpers | `pn_create_listen_socket`, `pn_create_listen_socket_unix`, `pn_create_connect_socket_unix`, `pn_create_listen_socket_from_sockaddr`, `pn_connect_socket`, `pn_wait_writable`, `bsd_set_linger_abort` (all in `pn_utils.c` — tofu-owned) |

### 4.3 Required / Useful / Convenience classification

| API | Class | Notes |
| :--- | :--- | :--- |
| `us_create_poll`, `us_poll_start/change/stop/free`, `us_poll_ext`, `us_poll_init` | **Required** | Core polling abstraction |
| `us_create_loop`, `us_loop_free`, `us_loop_run_tick` | **Required** | Loop lifecycle; tick is patched-in |
| `us_internal_dispatch_ready_poll` | **Required (★)** | Overridden as the dispatch hook |
| `us_internal_poll_type` | **Required** | Filters SOCKET vs SHUT_DOWN polls |
| `bsd_recv` / `bsd_send` | **Useful** | EINTR retry + cross-platform errno; easily replaced by a 30-line Zig wrapper around `extern fn send/recv` |
| `bsd_create_listen_socket` | **Useful** | Wraps `getaddrinfo + socket + bind + listen + setsockopt`; replaceable by ~80 LOC Zig |
| `bsd_create_socket`, `bsd_set_nonblocking`, `bsd_close_socket`, `bsd_shutdown_socket*`, `bsd_socket_nodelay`, `bsd_would_block`, `bsd_addr_get_port`, `bsd_local_addr`, `bsd_remote_addr` | **Convenience** | All are 1–10 line libc wrappers |
| `bsd_socket_keepalive`, `bsd_set_linger_abort` | **Convenience (tofu-owned)** | Live in `pn_utils.c` — already not upstream |
| `bsd_create_listen_socket_unix`, `bsd_connect_socket_unix` | **Required for UDS** | Including `pathlen` patching for abstract namespace |
| `bsd_accept_socket` | **Useful** | Direct `accept4` / `accept`+fcntl wrap |

**Headline:** uSockets is used as a **portable BSD-socket layer + a poll abstraction**.
Of the ~22 distinct C symbols used, three (`us_loop_run_tick`,
`us_internal_dispatch_ready_poll`, the `pathlen` UDS variant) **require patches**.
The other 19 are routine wrappers that could be replicated in pure Zig with
modest effort.

### 4.4 Dispatch override (the critical pattern)

`src/platform/posixnet/posixnet_backend.zig:40-57`:

```zig
export fn us_internal_dispatch_ready_poll(poll, err, events) callconv(.c) void {
    const ws = g_wait_state orelse return;
    const seq_ptr: *SeqN = @ptrCast(@alignCast(pn.poll.pollExt(poll)));
    const tc = ws.map.get(seq_ptr.*) orelse return;
    const act = triggers_mod.usockets.fromEvents(events, err, tc.exp);
    tc.act = tc.act.lor(act);
    ws.total_act = ws.total_act.lor(act);
}
```

This **overrides** uSockets's own dispatch function — a weak symbol replaced at
link time. It is the linchpin that lets uSockets do the OS wait while tofu owns
the dispatch table. **No libevent equivalent is required** because libevent gives
each `event` its own `void *arg` natively — the same hook-back without symbol games.

---

## 5. Findings: uSockets Dependency Risk

### 5.1 Maintenance status of the fork

* **Fork:** `g41797/uSockets` — single-maintainer fork of bun-usockets.
* **Patches:** 4 files patched (`bsd.c`, `context.c`, `eventing/epoll_kqueue.c`, `internal/networking/bsd.h`).
* **Upstream cadence:** bun-usockets evolves against Bun runtime needs — not against API stability for external consumers.
* **No `ChangeLog`** in the upstream/fork repo — release cadence is unstructured.

### 5.2 Source surface of the fork

Compiled C: `bsd.c` (876 LOC) + `context.c` (525) + `loop.c` (395) + `socket.c` (231) + `udp.c` (150) + `eventing/epoll_kqueue.c` (545) = **~2,720 LOC of C** that ships in every tofu build, of which only `bsd.c` + `epoll_kqueue.c` + the tofu-owned `pn_utils.c` are actually exercised.

### 5.3 The dual-path patching problem

Per `AGENT_STATE.md`, every patch must be applied **twice** (local fork + Zig
package cache) until pushed upstream. This is a maintenance smell that won't
disappear unless the fork is published with a fixed commit and the
`build.zig.zon` hash is updated. It is not specific to libevent vs uSockets, but
it is part of the *cost of running a fork*.

### 5.4 What can be cut

If tofu were to keep `posixnet` and minimize its uSockets footprint, the
*actually used* surface is:

* `bsd.c` + `internal/networking/bsd.h` — necessary for BSD wrappers
* `eventing/epoll_kqueue.c` + `internal/eventing/epoll_kqueue.h` — necessary for the loop and poll types
* `loop.c` + `socket.c` — pulled in transitively (define `us_create_loop`, `us_loop_run_tick`)
* `internal.h`, `loop_data.h` — needed for struct definitions

Strict minimal subset is roughly **half the file count** of the full uSockets src
tree, but it still imports the *concept* set: `us_loop_t`, `us_poll_t`,
`POLL_TYPE_*`, the dispatch weak symbol. The minimum is not as minimal as the
file count suggests.

### 5.5 Estimate: minimal subset vs entire framework

| Question | Answer |
| :--- | :--- |
| Files actually compiled | ~6 (bsd, loop, socket, context if reachable, epoll_kqueue, internal headers) |
| Public APIs used | ~22 symbols (see §4.2) |
| Concepts imported | 4 (loop, poll, dispatch hook, BSD wrappers) |
| Fraction of the framework that matters | ≤ 25% |

A clean separation of the `bsd.c`+`pn_utils.c` socket layer from the `loop/poll`
layer would *enable* a future where tofu keeps the BSD wrappers and swaps the
poll layer for libevent — but that separation does not exist today inside the
fork.

---

## 6. Findings: libevent Capabilities

### 6.1 Event mechanisms supported

| Backend | File | Status |
| :--- | :--- | :--- |
| epoll | `epoll.c`, `epoll_sub.c` | Linux primary |
| kqueue | `kqueue.c` | macOS / BSD primary |
| evport | `evport.c` | Solaris |
| /dev/poll | `devpoll.c` | Legacy |
| poll | `poll.c` | Universal fallback |
| select | `select.c` | Universal fallback |
| wepoll | `wepoll.c` | **Windows — added in 2.2 series** |
| win32 select | `win32select.c` | Older Windows fallback |

**Critical:** libevent ships a `wepoll` backend natively, so Windows is covered
without the tofu "Forced Epoll" shim layer (`sys/epoll.h`, `sys/timerfd.h`,
`sys/eventfd.h`). That deletes a whole class of Windows-specific glue.

### 6.1.1 What libevent does NOT provide (confirmed)

libevent is a **polling library**, not a sockets library. For the low-level
`event` API that tofu would use, libevent provides **only** readiness
notification:

```c
void callback(evutil_socket_t fd, short what, void *arg);
```

When the callback fires, libevent has performed **no I/O**. It is the user's
responsibility to call every socket-lifecycle operation:

| Operation | libevent provides? | tofu must own |
| :--- | :--- | :--- |
| `socket()` | ❌ | yes |
| `bind()` | ❌ | yes |
| `listen()` | ❌ | yes |
| `accept()` | ❌ | yes |
| `connect()` | ❌ | yes |
| `send()` / `recv()` | ❌ | yes |
| `close()` / `shutdown()` | ❌ | yes |
| `setsockopt()` (NODELAY, REUSEADDR, LINGER, KEEPALIVE) | ❌ | yes |
| `getsockname()` / `getpeername()` | ❌ | yes |
| `getaddrinfo()` (DNS) | ❌ (separate `evdns_*` is async-only, not what tofu uses) | yes |
| `errno` / `WSAGetLastError` mapping | ❌ | yes |
| EINTR retry loops | ❌ | yes |
| UDS path handling (`sockaddr_un`, abstract namespace, path length quirks) | ❌ | yes |

libevent ships a few small portability helpers in `event2/util.h`:
`evutil_socket_t`, `evutil_make_socket_nonblocking`,
`evutil_make_listen_socket_reuseable`, `evutil_closesocket`. These are
**portability glue**, not full BSD wrappers. They cover roughly 5% of what
uSockets `bsd.c` provides.

libevent's higher-level `bufferevent_*` API does perform I/O internally, but
tofu cannot use it for the same reason it rejected uSockets's `us_socket_t`:
bufferevent automatically calls `recv` into an internal buffer when the fd is
readable, which violates tofu's pool-based backpressure model
(`transition-2-usockets.md §6`).

**Confirmed conclusion:** choosing libevent forces tofu to **develop a
dedicated Zig sockets API module**, owned and versioned by tofu, replacing
the BSD-wrapper layer that uSockets currently provides via `bsd.c`. The size
of this module is estimated in §8 and the development path in §7.4. This is
not optional — it is the unavoidable cost of replacing a "polling + sockets"
library (uSockets) with a "polling only" library (libevent).

### 6.2 Features tofu would use

| Feature | libevent symbol | Tofu use |
| :--- | :--- | :--- |
| Event base | `event_base_new`, `event_base_new_with_config`, `event_base_free` | One per Reactor instance |
| Per-fd watch | `event_new(base, fd, EV_READ\|EV_WRITE\|EV_PERSIST, cb, arg)`, `event_assign`, `event_add`, `event_del`, `event_free` | One `event` per registered TC |
| Tick semantics | `event_base_loop(base, EVLOOP_ONCE \| EVLOOP_NONBLOCK)` or `+ event_base_loopexit(base, &tv)` for a bounded wait | Drives `Backend.wait(timeout)` |
| Per-event userdata | `void *arg` in `event_new(...)` | Stores `SeqN` (or directly `*TriggeredChannel`) — replaces the pollExt+weak-symbol dance |
| Edge-trigger | `EV_ET` (on backends that support it) | Not strictly needed; level-triggered is fine |
| Disconnect | `EV_CLOSED` (2.1+, requires `EV_FEATURE_EARLY_CLOSE`) | Maps to `Triggers.err` |
| Timeout | `event_add(ev, &tv)` for per-event, `event_base_loopexit(base, &tv)` for loop-bounded | Maps to `Triggers.timeout` |
| Wakeup | `event_active(ev, EV_READ, 1)` from another thread (with `evthread_use_*`) | Not needed — tofu's Notifier uses a socketpair |
| Signals | `evsignal_new` | Not needed today |

### 6.3 Trigger mapping table

| tofu Trigger | libevent equivalent | Class |
| :--- | :--- | :--- |
| `recv` | `EV_READ` on socket fd | **Native** |
| `send` | `EV_WRITE` on socket fd | **Native** |
| `accept` | `EV_READ` on listener fd | **Native** |
| `connect` | `EV_WRITE` on connecting fd | **Native** |
| `notify` | `EV_READ` on Notifier's receiver socket | **Native** |
| `err` | `EV_CLOSED` (libevent 2.1+) **OR** EOF detected on recv | **Easy mapping** (`EV_CLOSED` requires `EV_FEATURE_EARLY_CLOSE`, available on epoll and kqueue; on wepoll mapped via EPOLLHUP) |
| `timeout` | `event_base_loopexit(base, &tv)` before each `event_base_loop` call | **Native** |
| `pool` | N/A (tofu-internal, set by `MsgReceiver`) | **Unsupported / not needed** — stays in PollerCore |

**Verdict:** every trigger that an OS can observe is **native or easy** in libevent.
Nothing falls into "Difficult" or "Unsupported".

### 6.4 The one architectural impedance

libevent has **no equivalent of `EPOLL_CTL_MOD`**: to change the watched events on
an fd, the canonical pattern is:

```c
event_del(ev);
event_assign(ev, base, fd, new_flags, cb, arg);
event_add(ev, &timeout);
```

PollerCore's reconciliation pattern already minimizes redundant `modify()` calls
(only invokes when `new_exp != tc.exp`), so the cost is acceptable — but it is
*one syscall pair* (del + add) per change versus a single `epoll_ctl(MOD)`. For
tofu's workload this is negligible.

A cleaner alternative is to keep **two `event` structs** per fd — one for read and
one for write — and add/del them independently as `Triggers` change. This is the
historical libevent pattern and avoids the `assign` reset.

---

## 7. Feasibility of `libeventnet`

### 7.1 Sketch

```
libevent (system .so / .dll)
    ↓ (FFI: ~25 extern fn declarations)
src/platform/libeventnet/wrapper/   (Zig FFI module, replaces posixnet/wrapper/)
    ↓
src/platform/libeventnet/libeventnet_backend.zig   (~200 LOC)
    ↓
PollerCore<LibeventBackend>      (unchanged generic in src/ampe/core.zig)
    ↓
TriggeredChannel / Skt / SocketCreator / Reactor   (unchanged above)
```

### 7.2 Component impact

| Component | Change class | Notes |
| :--- | :--- | :--- |
| `SeqN` | **No changes** | Pass as `arg` to `event_new(...)` — direct value, no pollExt needed |
| `Triggers` (packed u8) | **No changes** | Application-level type; survives any backend |
| `TriggeredChannel` | **No changes** | Heap stability, mark-for-delete, etc. — all in core |
| `PollerCore<Backend>` generic | **No changes** | Already swap-tested across epoll/kqueue/wepoll/usockets |
| `Notifier` | **No changes** | Already platform-independent; sockets get registered like any other fd |
| `Skt` (posixnet variant) | **Minor changes** | If reusing the `pn` socket wrappers: 0 changes. If migrating to libc-direct: replace `pn.sendBuf` etc. with libc extern wrappers (mechanical) |
| `SocketCreator` (posixnet variant) | **Minor changes** | Same reasoning as Skt |
| `libeventnet_backend.zig` | **NEW** | ~200 LOC; structure mirrors `posixnet_backend.zig` |
| `libeventnet/triggers.zig` | **NEW** | ~50 LOC; `Triggers` ↔ `EV_READ`/`EV_WRITE`/`EV_CLOSED`/`EV_TIMEOUT` |

### 7.3 Concrete backend sketch

```zig
const PollMap = std.AutoHashMap(FdType, *anyopaque); // fd → *struct event

threadlocal var g_wait_state: ?*WaitState = null;
const WaitState = struct { map: *SeqnTrcMap, total_act: Triggers };

const LibeventBackend = struct {
    base: *anyopaque,
    polls: PollMap,
    allocator: Allocator,

    pub fn init(alktr: Allocator) AmpeError!LibeventBackend {
        const base = le.event_base_new() orelse return AmpeError.CommunicationFailed;
        return .{ .base = base, .polls = PollMap.init(alktr), .allocator = alktr };
    }

    pub fn register(self: *LibeventBackend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void {
        // Allocate a long-lived heap copy of seq so we can pass &seq as arg
        const seq_box = self.allocator.create(SeqN) catch return AmpeError.AllocationFailed;
        seq_box.* = seq;

        const ev = le.event_new(self.base, fd, le.flagsFor(exp) | le.EV_PERSIST, callback, seq_box)
            orelse { self.allocator.destroy(seq_box); return AmpeError.AllocationFailed; };
        if (le.event_add(ev, null) != 0) {
            le.event_free(ev); self.allocator.destroy(seq_box);
            return AmpeError.CommunicationFailed;
        }
        try self.polls.put(fd, ev);
    }

    pub fn modify(self: *LibeventBackend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void {
        const ev = self.polls.get(fd) orelse return self.register(fd, seq, exp);
        _ = le.event_del(ev);
        // event_assign re-initializes in-place; seq pointer in arg is preserved by re-passing
        const seq_ptr = le.event_get_callback_arg(ev);
        _ = le.event_assign(ev, self.base, fd, le.flagsFor(exp) | le.EV_PERSIST, callback, seq_ptr);
        if (le.event_add(ev, null) != 0) return AmpeError.CommunicationFailed;
    }

    pub fn unregister(self: *LibeventBackend, fd: FdType) void {
        if (self.polls.fetchRemove(fd)) |entry| {
            const seq_ptr: *SeqN = @ptrCast(@alignCast(le.event_get_callback_arg(entry.value)));
            _ = le.event_del(entry.value);
            le.event_free(entry.value);
            self.allocator.destroy(seq_ptr);
        }
    }

    pub fn wait(self: *LibeventBackend, timeout: i32, map: *SeqnTrcMap) AmpeError!Triggers {
        var ws = WaitState{ .map = map, .total_act = .{} };
        g_wait_state = &ws; defer g_wait_state = null;

        if (timeout >= 0) {
            const tv = le.timeval{ .sec = @divTrunc(timeout, 1000), .usec = @mod(timeout, 1000) * 1000 };
            _ = le.event_base_loopexit(self.base, &tv);
        }
        _ = le.event_base_loop(self.base, le.EVLOOP_ONCE);

        if (ws.total_act.off()) ws.total_act.timeout = .on;
        return ws.total_act;
    }
};

fn callback(fd: c_int, what: c_short, arg: ?*anyopaque) callconv(.c) void {
    const ws = g_wait_state orelse return;
    const seq_ptr: *SeqN = @ptrCast(@alignCast(arg.?));
    const tc = ws.map.get(seq_ptr.*) orelse return;
    const act = libevent_triggers.fromMask(what, tc.exp);
    tc.act = tc.act.lor(act);
    ws.total_act = ws.total_act.lor(act);
}
```

This is **structurally identical** to `posixnet_backend.zig`. The `pollExt` +
weak-symbol-override pattern is replaced by libevent's native `void *arg`.

### 7.4 The Skt / SocketCreator question — vendor `bsd.c` or port it to Zig?

Because libevent provides **no** socket I/O (§6.1.1), tofu has to supply the
socket lifecycle itself. Two implementation paths exist, differing in *whether
the BSD-wrapper layer is C or Zig*. **In both paths the existing
`posix_net/wrapper/*.zig` Zig facade is reused** — the question is what sits
underneath it.

#### Path 1 (RECOMMENDED) — Vendor `bsd.c` + `bsd.h` + `pn_utils.c` into tofu

Extract **only** the socket-side files from the uSockets fork and commit them
into tofu's tree as a tofu-owned C module (e.g. `src/platform/libeventnet/csocket/`):

* `bsd.c` (~876 LOC) — the cross-platform BSD wrapper.
* `internal/networking/bsd.h` — declarations.
* `pn_utils.c` (~50 LOC) — tofu's existing additions (`bsd_set_linger_abort`,
  `pn_create_listen_socket`, etc.).
* Tofu's existing patches to `bsd.c`/`bsd.h` (abstract-UDS pathlen,
  `bsd_socket_keepalive`) are **applied directly to the vendored copy** — they
  stop being "fork patches" and become "tofu's version of `bsd.c`".

Drop **everything else** from uSockets:
`loop.c`, `socket.c`, `context.c`, `eventing/epoll_kqueue.c`,
`eventing/libuv.c`, `eventing/gcd.c`, `udp.c`, `quic.c`, `internal/internal.h`,
`internal/loop_data.h`, `internal/eventing/*`.

Use libevent for the polling layer. Keep the existing
`posix_net/wrapper/{ffi,socket,creator,types}.zig` Zig facade verbatim, just
rename the module (`posix_net` → `csocket` or similar) and re-target its FFI
declarations against the vendored `bsd.c` instead of the fork.

**Pros:**

* **Battle-tested.** `bsd.c` has handled production traffic in uWebSockets and
  Bun for years. Edge cases (macOS 104-byte `sun_path` chdir workaround, Linux
  abstract UDS namespace, Windows `SIO_TCP_INITIAL_RTO` loopback fast-fail,
  `MSG_NOSIGNAL` vs `SO_NOSIGPIPE`, EINTR loops, `WSAEWOULDBLOCK` mapping) are
  already encoded and verified.
* **Minimal new Zig.** ~50 LOC of build glue, ~200 LOC libeventnet_backend.zig,
  Zig facade reused as-is.
* **Fork goes away.** The four patched files become a tofu-owned C snapshot.
  No dual-path patching, no fork maintenance, no weak-symbol override.
* **Windows shim layer goes away.** The `sys/epoll.h` / `sys/timerfd.h` /
  `sys/eventfd.h` shims existed for the uSockets *loop* layer
  (`epoll_kqueue.c`), not for `bsd.c`. With libevent owning the loop, `bsd.c`
  compiles on Windows against `winsock2.h` natively.
* **License is fine.** Apache 2.0 is permissive; tofu already links Apache 2.0
  code through the current dependency.
* **Drift is bounded.** Pin to a known-good commit. Re-sync periodically only
  if upstream lands a useful fix. The drift cost is small because the BSD
  surface is mature.

**Cons:**

* Adds ~900 LOC of C source to tofu's tree.
* Tofu now owns this C — bug fixes are tofu's responsibility (but tofu already
  owns `wepoll/` C in its tree, so this is not a new project invariant).
* C/Zig stack traces cross the FFI boundary during debugging.

#### Path 1.5 (alternative) — Write a minimal C adapter from scratch (`pn_socket.c`)

A middle option proposed in the parallel agy evaluation
(`libevent-evaluation-agy.md`): write a tofu-owned C file that implements only
the 13 `bsd_*` / `pn_*` symbols tofu actually uses, calling libc / Winsock2
directly. No uSockets code anywhere.

Symbol set to implement (from `posix_net/wrapper/ffi.zig`):

`bsd_create_socket`, `bsd_accept_socket`, `bsd_send`, `bsd_recv`,
`bsd_close_socket`, `bsd_shutdown_socket`, `bsd_shutdown_socket_read`,
`bsd_socket_nodelay`, `bsd_socket_keepalive`, `bsd_would_block`,
`bsd_local_addr`, `bsd_remote_addr`, `bsd_connect_socket_unix`,
`bsd_create_listen_socket`, `bsd_create_listen_socket_unix`,
plus the tofu `pn_*` helpers already in `pn_utils.c`.

**Pros:**

* No uSockets heritage. The C is tofu's own from line 1.
* No license obligations to track.
* No upstream drift concerns.
* Smaller than vendoring full `bsd.c` (which is 876 LOC).

**Cons:**

* **Honest size estimate is ~250–400 LOC C, not ~120.** The 120 LOC figure
  in agy's report underestimates per-OS quirks:
    - Winsock2 type mismatches (`SOCKET` vs `c_int`, narrowed return types).
    - macOS 104-byte `sun_path` chdir workaround.
    - Linux abstract UDS namespace.
    - Windows `SIO_TCP_INITIAL_RTO` loopback fast-fail.
    - `MSG_NOSIGNAL` (Linux) vs `SO_NOSIGPIPE` (macOS) vs neither (Windows).
    - Three per-OS `addrinfo` struct layouts.
    - EINTR retry loops per syscall.
* All of the above are battle-tested inside the existing `bsd.c`. Reimplementing
  them risks reintroducing bugs that have already been fixed.
* Production verification on three OSes is non-trivial — Path 1 (vendor)
  inherits verified behavior; Path 1.5 (rewrite in C) does not.

**When Path 1.5 makes sense:**

* If tofu wants to avoid any uSockets-origin code for strategic reasons
  (license clarity, "every file is tofu's"), without taking the Zig port hit.
* If `bsd.c`'s 876 LOC is judged too large to vendor.

**When Path 1 wins:**

* Default case. Vendoring proven code is cheaper than rewriting it twice
  (once now, once again later to fix edge cases).

#### Path 2 (OPTIONAL endgame) — Port `bsd.c` to pure Zig

Write `src/platform/libeventnet/sockets/` (~560 LOC Zig) exporting the same
facade as `posix_net` today, implemented via raw `extern fn` against libc
(POSIX) and `ws2_32` (Windows). The existing Skt/SocketCreator code switches
one import.

**Pros:**

* **No C in tofu's tree** for the BSD layer (modulo `wepoll/` which stays).
* tofu owns the full Zig-level surface.

**Cons:**

* **~560 LOC of new Zig** that re-implements battle-tested C.
* Windows portion (~200 LOC, ~40% of the work) re-encodes Winsock2 quirks
  that `bsd.c` already handles.
* Production verification on three OSes is non-trivial — Path 1's behavior
  is guaranteed by re-running tofu's existing contract suite against the same
  C code; Path 2 has to discover its own edge cases.

#### Recommendation

**Adopt Path 1 (vendor `bsd.c`) as the destination, not as a stepping stone.**
Path 1.5 (write minimal C from scratch) and Path 2 (port to Zig) are both
viable alternatives if the author has a strong preference against vendored
third-party C. With libevent as the polling layer plus vendored
`bsd.c`/`bsd.h`/`pn_utils.c`, tofu already captures every headline benefit
attributed earlier to Path 2:

* No fork to maintain ✓
* No dual-path patching ✓
* No weak-symbol override ✓
* No Windows shim layer ✓ (libevent's `wepoll` subsumes it)
* System-distributable (libevent from package manager, `bsd.c` vendored) ✓
* Zig 0.16 safe (no `std.posix` / `std.net` anywhere on the critical path) ✓

The *only* additional gain Path 2 offers is "no vendored C", which is not a
project invariant tofu holds today (`wepoll/` is precedent). Path 2 may still
be desirable in the long term for aesthetic reasons or to fully unify the
language story, but it is **not required** for the migration to deliver its
core value.

**Recommended sequencing:**

1. Ship Path 1 (vendor `bsd.c` + libevent polling). This is the production
   destination.
2. If — and only if — there's a project reason to eliminate all vendored C,
   undertake Path 2 later as a follow-up. Treat it as optional polish.

The remainder of this report assumes Path 1 as the operative plan unless
explicitly stated otherwise.

---

### 7.5 What the tofu Zig sockets module actually looks like

The module is **Zig code that calls C library APIs via FFI** (`extern fn`
declarations). No `std.posix`, no `std.net`. Pure interop with whatever
system socket library the OS provides. This shape is **stable across Zig
versions** — `extern fn` to system libraries is independent of the `std.posix`
/ `std.net` removal in Zig 0.16, because nothing in the Zig stdlib is on the
critical path.

#### 7.5.1 Per-OS C library and primitive types

| Concern | POSIX (Linux/macOS/BSD) | Windows |
| :--- | :--- | :--- |
| C library linked | `libc` (via `linkLibC()`) | `ws2_32.dll` (via `linkSystemLibrary("ws2_32")`) |
| Socket handle type | `c_int` (fd) | `SOCKET` = `uintptr_t` = `usize` |
| Invalid socket sentinel | `-1` | `INVALID_SOCKET` = `~@as(usize, 0)` |
| Error indicator | `-1` return + `errno` | `SOCKET_ERROR` (`-1` cast to int) + `WSAGetLastError()` |
| Lifecycle | none (libc always ready) | `WSAStartup(0x0202, ...)` / `WSACleanup()` |

This per-OS divergence is **already absorbed today** by the `posix_net`
wrapper: `pn.Fd = if (.windows) usize else c_int`, `pn.INVALID_FD`, and
`tofu.initPlatform()` for WSA. The same shape carries over.

#### 7.5.2 Per-OS API mapping

| Operation | POSIX call | Windows call (ws2_32) |
| :--- | :--- | :--- |
| Create | `socket(af, type, proto)` | `socket(af, type, proto)` |
| Bind | `bind(fd, sa, salen)` | `bind(s, sa, salen)` |
| Listen | `listen(fd, backlog)` | `listen(s, backlog)` |
| Accept (nonblock-capable) | `accept4(fd, sa, salen, SOCK_NONBLOCK\|SOCK_CLOEXEC)` on Linux; `accept(fd, sa, salen)` + `fcntl` on macOS | `accept(s, sa, salen)` + `ioctlsocket(FIONBIO)` |
| Connect | `connect(fd, sa, salen)` | `connect(s, sa, salen)` (loopback fast-fail via `WSAIoctl(SIO_TCP_INITIAL_RTO)`) |
| Send | `send(fd, buf, len, MSG_NOSIGNAL)` returning `ssize_t` | `send(s, buf, len, 0)` returning `int` |
| Recv | `recv(fd, buf, len, 0)` returning `ssize_t` | `recv(s, buf, len, 0)` returning `int` |
| Close | `close(fd)` | `closesocket(s)` |
| Shutdown | `shutdown(fd, SHUT_RD\|SHUT_WR\|SHUT_RDWR)` | `shutdown(s, SD_RECEIVE\|SD_SEND\|SD_BOTH)` |
| Non-blocking mode | `fcntl(fd, F_SETFL, O_NONBLOCK)` | `ioctlsocket(s, FIONBIO, &one)` |
| Setsockopt | `setsockopt(fd, level, name, val, len)` | `setsockopt(s, level, name, val, len)` |
| Getsockname | `getsockname(fd, sa, salen)` | `getsockname(s, sa, salen)` |
| DNS | `getaddrinfo()` / `freeaddrinfo()` from libc | `getaddrinfo()` / `freeaddrinfo()` from ws2_32 |
| Errno read | `errno` extern var (via `std.c.errno`) | `WSAGetLastError()` |
| Would-block check | `errno == EAGAIN \|\| EWOULDBLOCK` | `WSAGetLastError() == WSAEWOULDBLOCK` |
| UDS abstract namespace | Linux only: `sun_path[0] = 0` | Not supported (Windows 10 1803+ has `AF_UNIX` but no abstract namespace) |
| UDS path quirks | macOS `sun_path` is 104 bytes (vs 108 on Linux) — handle via `chdir` workaround or short paths | Standard 108-byte path |

#### 7.5.3 Shape of the Zig module

```zig
const builtin = @import("builtin");
const std = @import("std");

pub const Fd = if (builtin.os.tag == .windows) usize else c_int;
pub const INVALID_FD: Fd = if (builtin.os.tag == .windows)
    std.math.maxInt(usize) else -1;

const sys = if (builtin.os.tag == .windows) struct {
    pub extern "ws2_32" fn socket(af: c_int, t: c_int, p: c_int) Fd;
    pub extern "ws2_32" fn send(s: Fd, buf: [*]const u8, len: c_int, flags: c_int) c_int;
    pub extern "ws2_32" fn recv(s: Fd, buf: [*]u8, len: c_int, flags: c_int) c_int;
    pub extern "ws2_32" fn closesocket(s: Fd) c_int;
    pub extern "ws2_32" fn ioctlsocket(s: Fd, cmd: c_long, val: *c_ulong) c_int;
    pub extern "ws2_32" fn WSAGetLastError() c_int;
    pub extern "ws2_32" fn getaddrinfo(...) c_int;
    // bind, listen, accept, connect, setsockopt, getsockname, shutdown,
    // freeaddrinfo, WSAStartup, WSACleanup, ...
} else struct {
    pub extern "c" fn socket(af: c_int, t: c_int, p: c_int) c_int;
    pub extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
    pub extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    pub extern "c" fn getaddrinfo(...) c_int;
    // bind, listen, accept[4], connect, setsockopt, getsockname, shutdown,
    // freeaddrinfo, errno location, ...
};

pub fn sendBuf(fd: Fd, buf: []const u8) !?usize {
    const n = if (builtin.os.tag == .windows)
        sys.send(fd, buf.ptr, @intCast(buf.len), 0)
    else
        sys.send(fd, buf.ptr, buf.len, MSG_NOSIGNAL);
    if (n < 0) {
        const err = if (builtin.os.tag == .windows) sys.WSAGetLastError() else std.c.errno().*;
        if (isWouldBlock(err)) return null;
        return mapError(err);
    }
    return @as(usize, @intCast(n));
}
```

This is **structurally identical** to what `posix_net/wrapper/socket.zig` does
today, except the comptime branches now point at libc/ws2_32 directly instead
of going through uSockets `bsd.c`.

#### 7.5.4 Where the work concentrates

| Sub-area | LOC estimate | Where the difficulty lies |
| :--- | :--- | :--- |
| FFI declarations (POSIX + Windows) | ~150 | Tedious but mechanical |
| Send/recv/accept/connect with EINTR + would-block + errno mapping | ~150 | Three-OS error-code matrix |
| Address creation/parsing (IPv4/IPv6/UDS) | ~100 | Endianness, sockaddr family-byte differences (BSD `sa_len` byte at `mem[0]`) — already solved in `pn.types.zig`, port as-is |
| `getaddrinfo` cross-OS struct layout | ~50 | Three layouts (Linux glibc / BSD / Windows) — already solved in `pn.ffi.zig`, port as-is |
| Setsockopt helpers (REUSEADDR, NODELAY, LINGER=0, KEEPALIVE) | ~80 | Windows-specific quirks (raw `setsockopt` because Zig std treats EINVAL as unreachable on macOS, but with Zig 0.16 this issue disappears anyway) |
| WSAStartup/WSACleanup + abstract-UDS namespace + macOS short-path workaround | ~50 | One-off per-OS code already present in current tofu codebase |

**About half of the ~400–600 LOC already exists** inside
`src/platform/posixnet/wrapper/types.zig` (sockaddr handling, family detection,
port extraction) and `wrapper/ffi.zig` (the `getaddrinfo` per-OS struct
shapes). Path 2 is partly **moving and translating** existing tofu code, not
greenfield work.

#### 7.5.5 Zig 0.16 risk for this module — none from Zig itself

`extern "c" fn` and `extern "ws2_32" fn` are core language features, not
stdlib. They survive every Zig version. The only stdlib touch points are:

* `std.c.errno()` for POSIX errno access — stable.
* `std.math.maxInt`, `@intCast`, `@bitCast` — language built-ins, stable.
* `linkLibC()` / `linkSystemLibrary("ws2_32")` in `build.zig` — stable.

The module does **not** import `std.posix`, does **not** import `std.net`,
does **not** use `std.os.linux` socket APIs. **It is structurally immune to
the Zig 0.16 stdlib changes**, which is the entire reason tofu started this
migration in the first place.

---

## 8. Effort Estimate

### 8.1 Top-level stages

| Scope | Size | LOC (approx) | Risk |
| :--- | :--- | :--- | :--- |
| Prototype (Linux only, Path 1, register/modify/unregister/wait + Notifier wakeup) | **Small** | 250 new + 30 build.zig | Low |
| Production single-OS (Linux, Path 1, full IoSkt flow, all contract tests pass) | **Small–Medium** | 300 new + 50 build.zig | Low |
| Production multi-OS (Linux + macOS + Windows, Path 1) | **Medium** | 350 new + 100 build.zig + per-OS test debug | Medium (Windows libevent + wepoll edge cases) |
| **Path 2 — Port `bsd.c` functionality to Zig for all three OSes** | **Medium–Large** | see §8.2 breakdown | Medium (Winsock2 quirks, per-OS errno mapping) |
| Full sunset of `posixnet` after libeventnet validates | **Small** | −1,200 (delete `posixnet/`) + −fork-maintenance ongoing | Low once libeventnet is proven |

**Aggregate (Path 1 → Path 2 → sunset posixnet):** ~1,100 LOC net new, ~2,100 LOC
deleted. Multi-month effort if done in sequence, but each stage is independently
shippable.

### 8.2 Path 2 per-OS breakdown — porting `bsd.c` to Zig

Path 2 is the **explicit replacement of uSockets `bsd.c` (876 LOC of C) with
Zig code calling system libraries directly**. The work is unevenly distributed
across OSes:

| OS / Concern | New Zig LOC | Sources of difficulty | Re-use from existing tofu |
| :--- | :--- | :--- | :--- |
| **Shared (all OSes)** | ~150 | Address parsing, `Triggers` translation, common error type, `Fd`/`INVALID_FD` constants, EINTR retry loops, `sockaddr_in/in6/un` family-byte handling | `posix_net/wrapper/types.zig` (107 LOC) ports almost verbatim |
| **Linux** | ~80 | `accept4` flag bits, `MSG_NOSIGNAL`, `O_NONBLOCK` via `fcntl`, abstract UDS namespace (`sun_path[0]=0`), `getaddrinfo` POSIX `addrinfo` layout | Linux Skt logic in `stdposix/linux/Skt.zig` + `pn.ffi.zig` `addrinfo_posix` |
| **macOS / BSD** | ~100 | `accept` + manual `fcntl` (no `accept4`), `SO_NOSIGPIPE` instead of `MSG_NOSIGNAL`, 104-byte `sun_path` limit (chdir workaround), `addrinfo_bsd` layout with `ai_canonname` before `ai_addr`, BSD `sa_len` byte at `mem[0]`/family at `mem[1]` | macOS Skt logic in `stdposix/mac/Skt.zig` + `pn.types.zig` BSD branch |
| **Windows (Winsock2)** | ~200 | `WSAStartup`/`WSACleanup`, `SOCKET` = `usize` (not `c_int`), `closesocket` (not `close`), `ioctlsocket(FIONBIO)` (not `fcntl`), `WSAGetLastError` (not `errno`), `addrinfo_win` layout with `ai_addrlen` as `SIZE_T`, loopback-connect fast-fail via `WSAIoctl(SIO_TCP_INITIAL_RTO)`, return-type narrowing (`int` not `ssize_t` for send/recv), `WSAEWOULDBLOCK` instead of `EAGAIN`, no abstract UDS namespace, `AF_UNIX` only since Windows 10 1803 | Windows Skt logic in `stdposix/windows/Skt.zig` (Zig 0.16-fragile), `pn.ffi.zig` `addrinfo_win` |
| **Build-system glue** | ~30 | `linkLibC()` on POSIX, `linkSystemLibrary("ws2_32")` + `linkSystemLibrary("iphlpapi")` on Windows, libevent linking, vendored-libevent build option | New, but small |
| **Testing** | ~0 (no new tests) | `tests/ampe/sockets_tests.zig` + `Notifier_tests.zig` are already the platform-independent contract suite — they validate Path 2 unchanged | Existing |

**Path 2 totals: ~560 LOC new Zig + ~30 LOC build.zig.** Roughly:

* ~25% Linux
* ~25% macOS  
* ~40% Windows
* ~10% shared facade and build glue

**Windows is the dominant cost** because Winsock2 diverges from POSIX in several
non-trivial places (semantic differences in non-blocking mode, return-type
widths, error reporting, loopback connect quirks). The current `posix_net`
backend absorbs all of this via uSockets's `bsd.c`. Porting to pure Zig means
tofu owns these quirks directly — which is *the entire point* of dropping the
uSockets dependency, but is the line item worth budgeting honestly.

**Mitigating factor:** Path 2 is not greenfield. The current codebase already
contains working examples of every Winsock2 quirk:

* `stdposix/windows/Skt.zig` already deals with `ws2_32`, `WSAStartup`, `SOCKET` typing.
* `posix_net/wrapper/types.zig` already encodes the per-OS `sockaddr` byte layouts.
* `posix_net/wrapper/ffi.zig` already declares the three per-OS `addrinfo` struct shapes.

Path 2 is therefore best described as **consolidating and translating** existing
tofu code (currently split between stdposix Skt files and `posix_net/wrapper/`
extern declarations) into a single pure-Zig sockets module — not as inventing
the missing knowledge from scratch.

### 8.3 What Path 2 is *not*

Path 2 does **not** include:

* Rewriting libevent itself (we link the upstream library — vendored or system).
* TLS / SSL — tofu doesn't use this from uSockets or libevent today; out of scope.
* QUIC / UDP / HTTP / async DNS — out of scope; tofu has no consumer.
* Thread-safe loop wakeup — tofu uses its own Notifier socketpair; libevent's
  `event_active` / `evthread_use_*` is not needed.

---

## 9. Long-Term Maintenance Comparison

| Dimension | Forked uSockets | System libevent |
| :--- | :--- | :--- |
| **Dependency ownership** | Single-maintainer fork of a Bun-driven project | Independent OSS library, widely-distributed |
| **Distribution** | Vendored via build.zig.zon, source committed to fork | `apt install libevent-dev`, `brew install libevent`, vcpkg, etc. (or vendor for hermetic builds) |
| **Security updates** | Must rebase fork against upstream; upstream security cadence driven by Bun | Distro packages get security updates automatically |
| **API stability** | Internal symbols (`us_internal_dispatch_ready_poll`, `POLL_TYPE_SOCKET`) — no guarantee | Public `event2/*.h` API stable since 2010 (2.0 release) |
| **Portability** | 3 OS × 2 archs verified by tofu CI; Windows requires shim layer | Same 3 OS × ARM/x86_64, plus FreeBSD/Solaris/OpenBSD natively; no shim layer |
| **Vendor lock-in** | Tofu's dispatch hook depends on weak-symbol semantics — gcc/clang only on Linux/macOS, MSVC has different weak rules | None — `void *arg` is standard C |
| **Maintenance surface inside tofu** | 4 patches in 4 files, applied twice per change until fork is published | One FFI module (~25 extern declarations) |
| **Future Zig version churn** | Risk is **decoupled from Zig** — uSockets is pure C | Risk is **decoupled from Zig** — libevent is pure C |
| **In-tree C code shipped** | ~2,700 LOC of uSockets `.c` + ~250 LOC of tofu `pn_utils` / shims | 0 (system lib) or full libevent (vendored) — but no per-tofu patches |

The strategic advantage of libevent is **not** performance or features. It is the
**elimination of the fork as a maintenance object**. The disadvantage is taking
on an additional system dependency, which can be partially mitigated by vendoring
libevent itself (it builds cleanly with CMake on all three target OSes).

---

## 10. Recommendation

### Q1 — Can libevent implement the current tofu backend contract?

**Yes.** The `register / modify / unregister / wait` contract maps cleanly to
`event_assign + event_add / event_del / event_base_loop(EVLOOP_ONCE)`. The
SeqN→TriggeredChannel dispatch hook is even simpler under libevent: it falls out
of the per-event `void *arg`, with no weak-symbol override required.

### Q2 — Can libevent replace stdposix?

**Yes, and it should.** stdposix relies on `std.posix.*` and `std.net.*` which
are being removed in Zig 0.16. Replacing it with libevent (plus a small
libc-binding shim) is a *better* migration path than rewriting stdposix against
some other interim API.

### Q3 — Can libevent replace posixnet?

**Yes, in two stages.** Stage one: implement libeventnet that reuses the `bsd.c`
+ `pn_utils.c` socket wrappers from the existing fork (Path 1 in §7.4). Stage
two: replace those wrappers with direct libc bindings (Path 2), at which point
the uSockets fork has no consumers.

### Q4 — Would libevent simplify long-term maintenance?

**Yes.** The dual-path patching, weak-symbol override, `LIBUS_USE_EPOLL` Windows
shim headers (`sys/epoll.h`, `sys/timerfd.h`, `sys/eventfd.h`), and the
`us_loop_run_tick` custom patch all go away. The Windows path in particular
becomes dramatically simpler because libevent's `wepoll.c` is integrated and
tested upstream.

### Q5 — Would libevent introduce significant limitations?

**One mild one.** No native `CTL_MOD` — modify requires `event_del + event_add`.
PollerCore's reconciliation already minimizes redundant modifies, so the
syscall-cost impact is negligible. No other limitations were identified.

A second-order consideration: adding libevent as a system dependency complicates
distribution slightly. Mitigations: (a) vendor libevent via `build.zig.zon` like
wepoll is today; (b) use libevent's CMake build under Zig, which has been done
successfully by other Zig projects.

### Q6 — Recommended path

**Option B: Add a `libeventnet` platform alongside `posixnet`.**

Justification:

1. **De-risk by parallel implementation.** posixnet is currently passing 103/103
   tests across all platforms. Removing it before libeventnet has the same
   record would be reckless.

2. **Side-by-side correctness comparison.** Two backends compiled from the same
   source above PollerCore lets the same tests run against both, surfacing any
   subtle semantic divergence early.

3. **Zig 0.16 migration urgency is on stdposix, not posixnet.** stdposix is the
   actively rotting component. libeventnet replaces stdposix's role (Windows
   wepoll, native epoll/kqueue) much more cleanly than posixnet does today,
   because libevent is genuinely cross-platform without per-OS Skt code.

4. **Sunset posixnet, not maintain it forever.** Once libeventnet has six months
   of green CI on all three platforms, posixnet (and the uSockets fork it
   depends on) can be deleted. At that point the net code-line count is
   smaller than today.

5. **No regression risk.** Option C (replace posixnet outright) requires
   completing the entire libeventnet implementation, including IoSkt/Notifier
   integration on Windows, before the first merge. Option B lets each piece
   land independently with the safety net of two working backends.

### Note: agy evaluation recommends Option C

The parallel evaluation in `libevent-evaluation-agy.md` recommends **Option C
(replace posixnet)** rather than Option B. The reasoning given there:

* A single backend reduces platform-specific code and test matrix forever.
* Security updates for the polling layer flow through libevent upstream.
* `stdposix` becomes impractical under Zig 0.16 regardless.

These points are valid and aligned with the long-term destination. The
difference is one of sequencing risk, not direction:

* **Both reports agree** on the end state: libevent + tofu-owned socket layer,
  with `posixnet` and `stdposix` retired.
* **agy** treats the end state as a single step.
* **this report** treats the end state as the result of a validated two-step
  process (add, harden, then sunset).

For projects with strong CI confidence and a high tolerance for big-bang
migrations, Option C is reasonable. For tofu specifically, given that
`posixnet` is currently green at 103/103 and the author explicitly requires
4-mode verification (`RULES.md §0`) plus Windows-Linux sandwich verification
(`RULES.md §4`), the two-step Option B is the safer match for the project's
own quality bar.

**Both options reach the same destination.** The choice is a sequencing
preference, and is properly the author's call.

**Sequence:**

1. Land `libeventnet` backend (Path 1, Linux first). Gate behind
   `-Dnetwork=libeventnet` build option.
2. Extend to macOS, then Windows. Reuse the existing `pn.*` BSD wrappers initially.
3. Run contract tests + integration tests against `libeventnet` for ≥ one CI cycle on all three OSes.
4. Migrate `Skt` / `SocketCreator` to direct libc bindings (Path 2), drop uSockets
   `bsd.c` dependency.
5. Deprecate `posixnet`. Remove from CI matrix.
6. Deprecate `stdposix` once libeventnet has been the default for ≥ one release.

---

## 11. Risks

| Risk | Severity | Mitigation |
| :--- | :--- | :--- |
| libevent on Windows (wepoll backend) edge cases differ from tofu's current wepoll vendor | Medium | Run the existing wepoll contract tests against libeventnet first; libevent's wepoll is the same upstream wepoll, just integrated |
| libevent's `EV_CLOSED` not delivered on all backends (requires `EV_FEATURE_EARLY_CLOSE`) | Low | Fall back to detecting EOF via `recv() == 0` (already done in `pn.recvToBuf`) |
| Building libevent under `build.zig` (CMake-driven upstream) may require manual translation | Medium | Either vendor libevent and write a `build.zig` for it (one-time cost), or use `linkSystemLibrary("event")` for non-hermetic builds |
| Path 2 (drop uSockets bsd.c) — per-OS errno mapping mistakes | Medium | Cover with the existing `tests/ampe/sockets_tests.zig` contract suite — it was designed to be platform-independent for exactly this reason |
| Adding a third backend doubles the test matrix during transition | Low | The Stage 9 partitioning already supports per-network test-gated builds; adding `libeventnet` to the matrix is mechanical |

---

## 11.4 libevent Build Configuration

Strategy for compiling libevent into tofu, distilled in part from the parallel
agy evaluation. These choices keep `build.zig` simple and the binary small.

### 11.4.1 Core-only file list

Compile only the files tofu needs. Do not link the high-level protocol layers.

| Always | `event.c`, `evmap.c`, `evutil.c`, `log.c`, `signal.c`, `evutil_rand.c`, `evutil_time.c` |
| :--- | :--- |
| Linux | + `epoll.c`, `epoll_sub.c` |
| macOS / BSD | + `kqueue.c` |
| Windows | + `wepoll.c`, `evthread_win32.c` (only the no-op portions if threads disabled) |

Excluded (not compiled):

* `evdns.c` — tofu uses libc `getaddrinfo`.
* `evhttp.c`, `evrpc.c`, `http.c`, `evrpc-internal.h` — protocol layers.
* `bufferevent_*.c` — buffered I/O violates pool backpressure (§6.1.1).
* `bufferevent_openssl.c`, `bufferevent_mbedtls.c` — TLS.
* `event_iocp.c`, `buffer_iocp.c` — IOCP not used; tofu uses wepoll on Windows.
* `evrpc*`, `event_tagging.c`, `ws.c` — unused.

This excludes well over half of libevent's `.c` files. Binary size shrinks
correspondingly.

### 11.4.2 Static `event-config.h` instead of `build.zig` flags

libevent expects an `event-config.h` with feature macros (`EVENT__HAVE_EPOLL`,
`EVENT__HAVE_KQUEUE`, `EVENT__SIZEOF_SOCKLEN_T`, etc.). The upstream build
generates this from `event-config.h.cmake` via CMake.

Tofu does not use CMake. The recommended pattern is to **commit one static
`event-config.h`** under `src/platform/libeventnet/event/` with preprocessor
branches:

```c
#if defined(__linux__)
  #define EVENT__HAVE_EPOLL 1
  #define EVENT__HAVE_EVENTFD 1
  /* ... */
#elif defined(__APPLE__) || defined(__FreeBSD__)
  #define EVENT__HAVE_KQUEUE 1
  /* ... */
#elif defined(_WIN32)
  #define EVENT__HAVE_WEPOLL 1
  /* ... */
#endif

#define EVENT__VERSION "2.2.1-tofu"
#define EVENT__DISABLE_THREAD_SUPPORT 1
```

`build.zig` adds the include path. No flag plumbing per platform. The header
is the source of truth for libevent's feature detection.

### 11.4.3 Disable thread support

Tofu runs single-threaded per Reactor (see `transition-2-usockets.md §8`).
libevent's locking infrastructure is dead code in this configuration.

Define `EVENT__DISABLE_THREAD_SUPPORT` in `event-config.h`. Effects:

* No lock acquisition in `event_*` paths.
* No dependency on pthreads / Windows critical sections.
* Smaller binary.
* `evthread_use_*` calls become no-ops or compile errors — fine, tofu does
  not call them.

The Notifier socketpair already handles cross-thread wakeup at the tofu
layer. libevent's `evthread_make_base_notifiable` is not needed.

### 11.4.4 `err` mapping — two options

Both options work. Decide once and document.

**Option α — `EV_CLOSED`.** libevent 2.1+ feature, requires
`EV_FEATURE_EARLY_CLOSE` to be requested via `event_config_require_features`.
Delivered as a flag in the callback's `what` argument. Idiomatic for libevent.

**Option β — `getsockopt(SO_ERROR)`.** Portable across all libevent versions.
Called from the callback when `EV_READ` fires with no data, or proactively
during connect to detect failure. Slightly more work; works everywhere.

Recommendation: start with Option α on backends that support it (epoll,
kqueue), fall back to Option β otherwise. Mirrors the current `pn`
behavior where EOF on `recv` already maps to `PeerDisconnected`.

---

## 11.5 Clone Strategy — `posixnet/` → `libeventnet/`

`libeventnet/` should be **cloned from** `posixnet/`, not built by sharing
files between the two platforms.

### 11.5.1 Why clone instead of share

* **The transition is time-bounded.** After sunset (see §10), only
  `libeventnet/` remains. The duplication exists only during validation.
* **`RULES.md §6` already establishes "same shape, different engine"** as the
  project pattern. Posix uses Zig stdlib; posixnet delegates to uSockets;
  libeventnet delegates to vendored `bsd.c`. Cloning makes the
  line-by-line comparison rule §6 trivial to follow.
* **The wrapper layer diverges.** Posixnet's `wrapper/` keeps `poll.zig`, the
  uSockets dispatch hook, and `adapters/sys/*.h` Windows headers. Libeventnet
  needs none of these. Cloning lets unused parts be deleted in the clone
  without disturbing posixnet.
* **The fork dependency stays isolated.** Posixnet's `wrapper/ffi.zig`
  declares `extern fn` against the uSockets fork (fetched via
  `build.zig.zon`). Libeventnet's `wrapper/ffi.zig` declares `extern fn`
  against the vendored `bsd.c` (in-tree). Same symbol names, different
  compilation unit. Cloning prevents one platform's `build.zig` changes from
  breaking the other.
* **CI safety during edits.** Editing the clone cannot regress posixnet's CI.
  Posixnet stays green throughout libeventnet development.

### 11.5.2 Target folder layout

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

### 11.5.3 File-by-file change classification

| File in `posixnet/wrapper/` | Status in `libeventnet/csocket/facade/` |
| :--- | :--- |
| `poll.zig` | **Removed.** libevent owns the loop. |
| `adapters/us_epoll_win.c` | **Removed.** No `epoll_kqueue.c` to compile on Windows. |
| `adapters/sys/epoll.h` | **Removed.** Not needed for `bsd.c`. |
| `adapters/sys/timerfd.h` | **Removed.** Not needed for `bsd.c`. |
| `adapters/sys/eventfd.h` | **Removed.** Not needed for `bsd.c`. |
| `adapters/win_compat.h` | **Keep** if `bsd.c` includes it on Windows; verify after vendoring. |
| `adapters/pn_utils.c` | **Keep.** Move into `csocket/` as a vendored file. |

### 11.5.4 Per-file edit summary

* `ffi.zig` clone:
    - Keep all `bsd_*` and `pn_*` declarations.
    - Keep the `addrinfo` per-OS struct definitions.
    - Keep `getaddrinfo`, `freeaddrinfo`, `unlink`, `_unlink`.
    - Remove `us_create_loop`, `us_loop_free`, `us_loop_run_tick`.
    - Remove `us_create_poll`, `us_poll_free`, `us_poll_init`, `us_poll_start`,
      `us_poll_change`, `us_poll_stop`, `us_poll_ext`, `us_internal_poll_type`.
* Per-OS `Skt.zig` and `SocketCreator.zig`:
    - No code edits.
    - Change one import: `@import("posix_net")` → `@import("csocket")`.
* `triggers.zig` rewrite:
    - Replace `LIBUS_SOCKET_READABLE` with `EV_READ`.
    - Replace `LIBUS_SOCKET_WRITABLE` with `EV_WRITE`.
    - Add `EV_CLOSED` mapping for `err`.
    - Drop the macOS `EV_ERROR` / `EV_EOF` branch — libevent normalizes those.
* `libeventnet_backend.zig` (new):
    - Same `PollerCore<Backend>` shape as `posixnet_backend.zig`.
    - Replace `pn.poll.*` calls with `event_*` calls.
    - Replace the `us_internal_dispatch_ready_poll` weak override with a
      libevent callback that reads `SeqN` from the event's `void *arg`.

### 11.5.5 Sunset of `posixnet/`

When libeventnet has been the default for one release:

* Delete `src/platform/posixnet/` (entire folder).
* Remove uSockets from `build.zig.zon`.
* Remove the `-Dnetwork=posixnet` build option.
* Remove posixnet from CI matrix.

The vendored `bsd.c` under `libeventnet/csocket/` survives. The dual-path
patching dance disappears with the fork.

### 11.5.6 RULES.md §6 update note (for the author)

`design/RULES.md §6` today covers "posix backends" and "the portable backend".
After libeventnet is added, §6's "same shape, different engine" rule should
explicitly cover three backends:

* `stdposix` — Zig stdlib / syscalls
* `posixnet` — uSockets fork via FFI
* `libeventnet` — libevent + vendored `bsd.c` via FFI

This is a doc update for the author per `RULES.md §0` (architectural approval
required). Not proposed as part of the libeventnet implementation itself.

---

## 12. Final Verdict

> **libevent is a practical and architecturally sound replacement for both
> stdposix and posixnet over the long term, paired with a tofu-owned vendored
> snapshot of `bsd.c`/`bsd.h` from uSockets.**
>
> libevent provides only the polling layer. Every socket operation — `socket`,
> `bind`, `listen`, `accept`, `connect`, `send`, `recv`, `close`, `setsockopt`,
> address parsing, DNS resolution, errno mapping, EINTR retry, UDS path
> handling — is the user's responsibility.
>
> The recommended way to supply those operations is **not** to port `bsd.c`
> to Zig, but to **vendor `bsd.c` + `bsd.h` + `pn_utils.c` directly into
> tofu's tree** (~900 LOC of battle-tested C, tofu-owned, no fork) and keep
> the existing Zig facade (`posix_net/wrapper/*.zig`) on top of it. This is
> **Path 1** in §7.4.
>
> The polling layer is replaced by ~200 LOC of new Zig
> (`libeventnet_backend.zig`). Build glue: ~50 LOC.
>
> This combination already captures every headline maintenance gain — no fork,
> no patched weak symbols, no Windows-shim header layer, no dual-path patching,
> system-package distribution of libevent.
>
> A future Path 2 (port `bsd.c` to pure Zig, ~560 LOC) remains optional polish.
> It is not required for the migration to deliver its value.
>
> **Do not** rip out posixnet first. **Do** add `libeventnet` alongside it,
> harden it, then sunset posixnet and stdposix in sequence.
>
> Investing in `libeventnet` + vendored `bsd.c` is the recommended Zig 0.16
> strategy.
