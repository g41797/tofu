# bun-usockets Backend Implementation Plan

**Status:** Ready for Implementation  
**Date:** 2026-05-05  
**Source of truth:** `design/transition-2-usockets.md` (all section references below point there)

---

## 1. Context

`build.zig` exposes `-Dnetwork=usockets`. When set, `internal.zig` routes to `src/ampe/usockets/` for Skt, SocketCreator, and Poller. `Notifier` is platform-independent (`src/ampe/Notifier.zig`) and is used directly regardless of backend. The posix backends (`linux/`, `mac/`, `windows/`) remain untouched.

**Goal:** implement `src/ampe/usockets/` so all 64 existing tests pass under `-Dnetwork=usockets` on Linux (later Windows and macOS per the sequencing in §15.5).

---

## 2. Files to Implement

Four files in `src/ampe/usockets/` — one unified implementation for all platforms (§16.2):

| File | Status | What it replaces |
| :--- | :--- | :--- |
| `Skt.zig` | stub → full | `linux/Skt.zig`, `mac/Skt.zig`, `windows/Skt.zig` |
| `SocketCreator.zig` | stub → full | `linux/SocketCreator.zig`, etc. |
| `triggers.zig` | partial → full | `linux/triggers.zig`, etc. |
| `usockets_backend.zig` | stub → full | `epoll_backend.zig` / `wepoll_backend.zig` / `kqueue_backend.zig` |

Note: `Notifier.zig` is platform-independent (`src/ampe/Notifier.zig`). No usockets-specific file needed — `internal.zig` now imports it unconditionally.

Plus new build infrastructure:
- `src/ampe/windows/adapters/sys/epoll.h` (new)
- `src/ampe/windows/adapters/sys/timerfd.h` (new)
- `src/ampe/windows/adapters/sys/eventfd.h` (new)

---

## 3. bun-usockets API Used

### 3.1 Public API (from `libusockets.h`)

```c
// Loop
struct us_loop_t *us_create_loop(void *hint,
    void (*wakeup_cb)(us_loop_r),
    void (*pre_cb)(us_loop_r),
    void (*post_cb)(us_loop_r),
    unsigned int ext_size);
void us_loop_free(struct us_loop_t *loop);

// Poll (one per watched fd)
struct us_poll_t *us_create_poll(us_loop_r loop, int fallthrough, unsigned int ext_size);
void us_poll_free(struct us_poll_t *p, struct us_loop_t *loop);
void us_poll_init(us_poll_r p, LIBUS_SOCKET_DESCRIPTOR fd, int poll_type);
void us_poll_start(us_poll_r p, us_loop_r loop, int events);
void us_poll_change(us_poll_r p, us_loop_r loop, int events);
void us_poll_stop(us_poll_r p, struct us_loop_t *loop);
LIBUS_SOCKET_DESCRIPTOR us_poll_fd(us_poll_r p);
void *us_poll_ext(us_poll_r p);         // pointer to ext memory after poll struct

// Port query
void us_socket_local_address(us_socket_r s, char *buf, int *length);
```

### 3.2 Non-public but required (forward-declared in `epoll_kqueue.c`)

```c
void us_loop_run_bun_tick(struct us_loop_t *loop, const struct timespec *timeout);
```

### 3.3 Internal BSD wrappers (from `internal/networking/bsd.h`)

Used by `Skt.zig` and `SocketCreator.zig` (§15.3, §6):

```c
LIBUS_SOCKET_DESCRIPTOR bsd_create_listen_socket(const char *host, int port, int options, int *err);
LIBUS_SOCKET_DESCRIPTOR bsd_create_listen_socket_unix(const char *path, size_t pathlen, int options, int *err);
LIBUS_SOCKET_DESCRIPTOR bsd_create_connect_socket(struct sockaddr_storage *addr, int options);
LIBUS_SOCKET_DESCRIPTOR bsd_create_connect_socket_unix(const char *path, size_t pathlen, int options);
LIBUS_SOCKET_DESCRIPTOR bsd_accept_socket(LIBUS_SOCKET_DESCRIPTOR fd, struct bsd_addr_t *addr);
ssize_t bsd_recv(LIBUS_SOCKET_DESCRIPTOR fd, void *buf, int length, int flags);
ssize_t bsd_send(LIBUS_SOCKET_DESCRIPTOR fd, const char *buf, int length);
void bsd_close_socket(LIBUS_SOCKET_DESCRIPTOR fd);
void bsd_shutdown_socket(LIBUS_SOCKET_DESCRIPTOR fd);
int bsd_addr_get_port(struct bsd_addr_t *addr);
LIBUS_SOCKET_DESCRIPTOR bsd_set_nonblocking(LIBUS_SOCKET_DESCRIPTOR fd);
void bsd_socket_nodelay(LIBUS_SOCKET_DESCRIPTOR fd, int enabled);
int bsd_socket_keepalive(LIBUS_SOCKET_DESCRIPTOR fd, int on, unsigned int delay);
```

### 3.4 Constants (from `internal/internal.h`)

```c
POLL_TYPE_CALLBACK   = 3   // fires stored fn pointer; NO automatic bsd_recv
LIBUS_SOCKET_READABLE = 1
LIBUS_SOCKET_WRITABLE = 2
```

---

## 4. Build Changes (`build.zig`)

### 4.1 C sources and include paths

Add under both `lib` and `lib_unit_tests`, gated on `network == .usockets`:

```zig
if (network == .usockets) {
    const is_kqueue = target.result.os.tag == .macos or
        target.result.os.tag == .freebsd or
        target.result.os.tag == .netbsd or
        target.result.os.tag == .openbsd;
    const is_windows = target.result.os.tag == .windows;

    const backend_define = if (is_kqueue) "-DLIBUS_USE_KQUEUE" else "-DLIBUS_USE_EPOLL";
    const flags = &.{ "-fno-sanitize=undefined", "-DLIBUS_NO_SSL", backend_define };

    const root = "vendor/bun-usockets/src/";
    for ([_][]const u8{ "bsd.c", "context.c", "loop.c", "socket.c", "udp.c" }) |f| {
        artifact.addCSourceFile(.{ .file = b.path(root ++ f), .flags = flags });
    }
    artifact.addCSourceFile(.{
        .file = b.path(root ++ "eventing/epoll_kqueue.c"),
        .flags = flags,
    });
    artifact.addIncludePath(b.path(root));
    artifact.addIncludePath(b.path(root ++ "internal"));
    artifact.addIncludePath(b.path(root ++ "internal/networking"));
    artifact.link_libc = true;

    if (is_windows) {
        // Windows adapters: redirect epoll/timerfd/eventfd to wepoll
        artifact.addIncludePath(b.path("src/ampe/windows/adapters"));
        // wepoll C source (already used by posix backend)
        artifact.addCSourceFile(.{
            .file = b.path("src/ampe/windows/wepoll/wepoll.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });
        artifact.addIncludePath(b.path("src/ampe/windows/wepoll"));
    }
}
```

### 4.2 Windows adapter headers (new files)

`src/ampe/windows/adapters/sys/epoll.h` — redirects `epoll_create1`, `epoll_ctl`, `epoll_wait` to wepoll  
`src/ampe/windows/adapters/sys/timerfd.h` — emulates timerfd (used internally by bun-usockets loop init)  
`src/ampe/windows/adapters/sys/eventfd.h` — emulates eventfd (used internally by bun-usockets loop init)

These are compile-time-only C headers. They make `epoll_kqueue.c` and `bsd.c` compile on Windows without modifying bun-usockets source (§16.4).

---

## 5. Required Zig Exports (C-callable)

In `src/ampe/usockets/usockets_backend.zig`:

```zig
export fn Bun__panic(msg: [*:0]const u8, len: usize) callconv(.C) noreturn {
    _ = len;
    @panic(std.mem.span(msg));
}

export fn Bun__isEpollPwait2SupportedOnLinuxKernel() callconv(.C) i32 {
    return 0;  // disable epoll_pwait2; use epoll_pwait fallback
}

export fn Bun__JSC_onBeforeWait(jsc_vm: *anyopaque) callconv(.C) void {
    _ = jsc_vm;  // no-op; loop.data.jsc_vm is null so never called
}
```

---

## 6. `usockets/triggers.zig`

Maps `Triggers` to `LIBUS_SOCKET_READABLE` / `LIBUS_SOCKET_WRITABLE` (§9.4, §16.5).  
Same mapping on all platforms — no comptime branches needed:

```zig
pub fn toEvents(exp: Triggers) c_int {
    var ev: c_int = 0;
    if (exp.recv == .on or exp.accept == .on or exp.notify == .on)
        ev |= LIBUS_SOCKET_READABLE;
    if (exp.send == .on or exp.connect == .on)
        ev |= LIBUS_SOCKET_WRITABLE;
    return ev;
}

pub fn fromEvents(events: c_int, err: c_int, eof: c_int, exp: Triggers) Triggers {
    var act = Triggers{};
    if (err != 0 or eof != 0) act.err = .on;
    if (events & LIBUS_SOCKET_READABLE != 0) {
        if (exp.recv == .on) act.recv = .on
        else if (exp.notify == .on) act.notify = .on
        else if (exp.accept == .on) act.accept = .on;
    }
    if (events & LIBUS_SOCKET_WRITABLE != 0) {
        if (exp.send == .on) act.send = .on
        else if (exp.connect == .on) act.connect = .on;
    }
    return act;
}

const LIBUS_SOCKET_READABLE: c_int = 1;
const LIBUS_SOCKET_WRITABLE: c_int = 2;
```

---

## 7. `usockets/usockets_backend.zig`

### 7.1 The Hook-Back Pattern (§5.2, §11.4)

Each registered fd gets a `us_poll_t` with `POLL_TYPE_CALLBACK` and `ext_size = @sizeOf(*TriggeredChannel)`. The `*TriggeredChannel` pointer is stored in the poll's ext memory via `us_poll_ext(p)`.

When `us_loop_run_bun_tick` fires, usockets calls `us_internal_dispatch_ready_poll(poll, error, eof, events)`. For `POLL_TYPE_CALLBACK`, this casts the poll to `us_internal_callback_t` and calls `p->cb(p)`. The `cb` field maps to the first 8 bytes of ext (because `us_internal_callback_t.{loop, cb}` vs `us_poll_state.{fd, poll_type}` have different layouts — see §5.2).

**Simplified approach:** Export `us_internal_dispatch_ready_poll` from Zig to override socket.c's definition. This gives us `(poll, error, eof, events)` directly and avoids callback layout complexity.

### 7.2 Module-level wait state

```zig
const WaitState = struct {
    map: *SeqnTrcMap,
    total_act: Triggers,
};
var g_wait_state: ?*WaitState = null;  // safe: wait() is single-threaded
```

### 7.3 Dispatch override

```zig
export fn us_internal_dispatch_ready_poll(
    poll: *anyopaque, err: c_int, eof: c_int, events: c_int,
) callconv(.C) void {
    const ws = g_wait_state orelse return;
    const tc_ptr = @as(**TriggeredChannel, @ptrCast(@alignCast(us_poll_ext(poll))));
    const tc = tc_ptr.*;
    const act = triggers_mod.fromEvents(events, err, eof, tc.exp);
    tc.act = tc.act.lor(act);
    ws.total_act = ws.total_act.lor(act);
}
```

### 7.4 Struct and operations

```zig
const PollMap = std.AutoHashMap(FdType, *anyopaque);

const UsocketsBackend = struct {
    loop: *anyopaque,   // us_loop_t*
    polls: PollMap,
    allocator: Allocator,
};

pub const Poller = core.PollerCore(UsocketsBackend);
```

**init:** `us_create_loop(null, null, null, null, 0)` — no loop-level ext needed

**register:** `us_create_poll(loop, 0, @sizeOf(*TriggeredChannel))` → `us_poll_init(poll, fd, POLL_TYPE_CALLBACK)` → store `tc` ptr in ext → `us_poll_start(poll, loop, toEvents(exp))`

**modify:** look up poll in map → update ext tc ptr if seq changed → `us_poll_change(poll, loop, toEvents(exp))`

**unregister:** `us_poll_stop` → `us_poll_free` → remove from map

**wait:**
```zig
pub fn wait(self: *UsocketsBackend, timeout: i32, seqn_trc_map: *SeqnTrcMap) AmpeError!Triggers {
    var ws = WaitState{ .map = seqn_trc_map, .total_act = Triggers{} };
    g_wait_state = &ws;
    defer g_wait_state = null;

    if (timeout < 0) {
        us_loop_run_bun_tick(self.loop, null);
    } else {
        const ts = std.posix.timespec{
            .tv_sec = @divTrunc(timeout, 1000),
            .tv_nsec = @as(isize, @rem(timeout, 1000)) * std.time.ns_per_ms,
        };
        us_loop_run_bun_tick(self.loop, &ts);
    }

    if (ws.total_act.isZero()) ws.total_act.timeout = .on;
    return ws.total_act;
}
```

### 7.5 C FFI declarations

```zig
const POLL_TYPE_CALLBACK: c_int = 3;

extern fn us_create_loop(...) callconv(.C) ?*anyopaque;
extern fn us_loop_free(loop: *anyopaque) callconv(.C) void;
extern fn us_create_poll(loop: *anyopaque, fallthrough: c_int, ext_size: c_uint) callconv(.C) ?*anyopaque;
extern fn us_poll_free(p: *anyopaque, loop: *anyopaque) callconv(.C) void;
extern fn us_poll_init(p: *anyopaque, fd: c_int, poll_type: c_int) callconv(.C) void;
extern fn us_poll_start(p: *anyopaque, loop: *anyopaque, events: c_int) callconv(.C) void;
extern fn us_poll_change(p: *anyopaque, loop: *anyopaque, events: c_int) callconv(.C) void;
extern fn us_poll_stop(p: *anyopaque, loop: *anyopaque) callconv(.C) void;
extern fn us_poll_ext(p: *anyopaque) callconv(.C) *anyopaque;
extern fn us_loop_run_bun_tick(loop: *anyopaque, timeout: ?*const std.posix.timespec) callconv(.C) void;
```

---

## 8. `usockets/Skt.zig`

Replaces `std.posix.*` calls with `bsd_*` wrappers (§15.3, §9.2). Mostly platform-unified; three small comptime branches for error mapping (§16.3).

**Key mappings:**

| Skt method | bsd_* call |
| :--------- | :--------- |
| `listen` | `bsd_create_listen_socket(host, port, 0, &err)` |
| `accept` | `bsd_accept_socket(fd, &addr)` |
| `connect` | `bsd_create_connect_socket(&sockaddr, 0)` |
| `sendBuf` | `bsd_send(fd, buf.ptr, @intCast(buf.len))` |
| `recvToBuf` | `bsd_recv(fd, buf.ptr, @intCast(buf.len), 0)` |
| `close` | `bsd_close_socket(fd)` |
| `getPort` | `us_socket_local_address` + parse port bytes |
| `disableNagle` | `bsd_socket_nodelay(fd, 1)` |
| `setLingerAbort` | `bsd_shutdown_socket` or close with reset |

`sendBufFd` / `recvToBufFd` are static helpers called by `sendBuf` / `recvToBuf`.

Error mapping:
```zig
fn mapErrno() AmpeError {
    if (comptime builtin.os.tag == .windows) {
        return switch (std.os.windows.ws2_32.WSAGetLastError()) {
            .WSAEWOULDBLOCK => ...,
            else => AmpeError.CommunicationFailed,
        };
    } else {
        return switch (std.posix.errno(-1)) {
            .AGAIN, .WOULDBLOCK => ...,
            else => AmpeError.CommunicationFailed,
        };
    }
}
```

---

## 9. `usockets/SocketCreator.zig`

Replaces `std.net.Address.resolveIp` / `getAddressList` / `posix.socket` with `bsd_create_*` (§9.3, §15.3):

| SocketCreator method | bsd_* call |
| :------------------- | :--------- |
| `createTcpServer` | `bsd_create_listen_socket(host, port, 0, &err)` |
| `createTcpClient` | `bsd_create_connect_socket(addr, 0)` (after resolving IP) |
| `createUdsServer` | `bsd_create_listen_socket_unix(path, pathlen, 0, &err)` |
| `createUdsClient` | `bsd_create_connect_socket_unix(path, pathlen, 0)` |

`bsd_create_listen_socket` and `bsd_create_connect_socket` handle `getaddrinfo` internally — no Zig-side DNS calls needed (§11.3).

Abstract UDS namespace (Linux only): prepend `\x00` to path before passing to `bsd_create_listen_socket_unix` (comptime branch, same as existing `Notifier.zig`).

---

## 10. Notifier

`src/ampe/Notifier.zig` is platform-independent and shared by all backends. `internal.zig` imports it unconditionally. No `usockets/Notifier.zig` file exists or is needed. Once `usockets/Skt.zig` and `usockets/SocketCreator.zig` are implemented, Notifier works unchanged under `-Dnetwork=usockets`.

---

## 11. VSCode Debug Config Change

File: `.vscode/launch.json`

Add `"c"` to `sourceLanguages` for C source stepping:
```json
"sourceLanguages": ["zig", "c"]
```

---

## 12. CI Changes

File: `.github/workflows/linux.yml` — add after existing 4-mode block:
```yaml
- run: zig build test -freference-trace --summary all -Doptimize=Debug -Dnetwork=usockets
- run: rm -rf ./.zig-cache/
- run: zig build test -freference-trace --summary all -Doptimize=ReleaseSafe -Dnetwork=usockets
```

File: `.github/workflows/mac.yml` — same addition.

`windows.yml`: defer to Stage 2 (Windows platform).

---

## 13. Implementation Sequence

| Stage | Content | Acceptance |
| :---- | :------ | :--------- |
| **0** | Update `.vscode/` config for Zig+C mixed debugging | Debug session with C source stepping works |
| **1** | `build.zig` C sources + `Skt.zig` + `SocketCreator.zig` | `sockets_tests.zig` pass on Linux |
| **2** | Notifier already complete — run `Notifier_tests.zig` | `Notifier_tests.zig` pass on Linux |
| **3** | `triggers.zig` + `usockets_backend.zig` | All 64 tests pass on Linux (4-mode sandwich) |
| **4** | Windows: adapter headers + `build.zig` include path | `zig build -Dtarget=x86_64-windows-gnu -Dnetwork=usockets` compiles |
| **5** | macOS: verify | `zig build -Dtarget=x86_64-macos -Dnetwork=usockets` compiles |
| **6** | CI + docs | `linux.yml` / `mac.yml` updated; `AGENT_STATE.md` bumped |

**Linux 4-mode sandwich (end of Stage 3):**
```sh
zig build test -Doptimize=Debug -Dnetwork=usockets        # 64/64
zig build test -Doptimize=ReleaseSafe -Dnetwork=usockets  # 64/64
zig build test -Doptimize=ReleaseFast -Dnetwork=usockets  # 64/64
zig build test -Doptimize=ReleaseSmall -Dnetwork=usockets # 64/64
```

---

## 14. Critical Files Summary

| File | Action |
| :--- | :----- |
| `build.zig` | Add usockets C source block (lines ~112, ~158) |
| `src/ampe/usockets/Skt.zig` | Implement using `bsd_*` wrappers |
| `src/ampe/usockets/SocketCreator.zig` | Implement using `bsd_create_*` |
| `src/ampe/usockets/triggers.zig` | Add `toEvents` / `fromEvents` |
| `src/ampe/usockets/usockets_backend.zig` | Full implementation |
| `src/ampe/windows/adapters/sys/epoll.h` | New — wepoll redirect |
| `src/ampe/windows/adapters/sys/timerfd.h` | New — timerfd emulation |
| `src/ampe/windows/adapters/sys/eventfd.h` | New — eventfd emulation |
| `.vscode/` config files | Stage 0 — Zig+C mixed debugging setup |
| `.github/workflows/linux.yml` | Add `-Dnetwork=usockets` test steps |
| `.github/workflows/mac.yml` | Add `-Dnetwork=usockets` test steps |

---

## 15. Verification

Acceptance: all 64 tests pass with `-Dnetwork=usockets` on Linux (all 4 optimize modes). Cross-compile to Windows and macOS succeeds.

The 8 backend contract tests (`tests/ampe/poller_tests.zig`) and 2 PollerCore integration tests (`tests/pollercore_tests.zig`) run unchanged — no test code changes needed.

---

## Addendum — Open Questions (2026-05-05)

The following issues remain unresolved. They must be addressed before or during implementation.

*Resolved and applied: A1 (Notifier platform-independent), A5 (initPlatform added to tests), A6+A7 (stage sequence corrected).*

---

### A2. POLL_TYPE_CALLBACK is ruled out — dispatch approach TBD

User clarified: callbacks will NOT be used. The plan's POLL_TYPE_CALLBACK approach (sections 7.1–7.3) is off the table.

The proposed alternative (export `us_internal_dispatch_ready_poll` from Zig to override socket.c's C definition) was also questioned: tofu uses only vendored C, not Bun's Zig code. The user suggested "extracting" relevant lines from Bun's Zig source as reference — but no Bun Zig files exist in `vendor/bun-usockets/` (C only).

**Open questions:**
- What poll type replaces POLL_TYPE_CALLBACK?
- How does event dispatch reach Zig without callbacks?
- Which Bun Zig source lines are worth extracting as reference?
- Where is Bun's Zig source for usockets integration found?

**Impact on plan:** Sections 7.1–7.3 must be rewritten once the dispatch approach is decided.

---

### A3. Windows adapter headers — source unknown

The plan specifies three new header files:
- `src/ampe/windows/adapters/sys/epoll.h`
- `src/ampe/windows/adapters/sys/timerfd.h`
- `src/ampe/windows/adapters/sys/eventfd.h`

**Open question:** Where do these come from? Options not yet decided:
- Already exist somewhere in the repo or a vendor tree?
- Taken from an upstream project (Bun, libuv, wepoll, etc.)?
- Written from scratch?

**Impact on plan:** Stage 3 cannot start until source is identified.

---

### A4. Hostname-to-IP resolution missing in SocketCreator

`bsd_create_connect_socket` takes an already-resolved `struct sockaddr_storage *addr` — it does NOT do DNS resolution internally. The linux `SocketCreator.zig` uses `std.net.getAddressList` which is unavailable under usockets (removed in Zig 0.16+).

`transition-2-usockets.md` §9.3 mentions `Bun__addrinfo_get` but this is a Bun-specific extension not present in vendored bun-usockets C.

**Open questions:**
- How does `usockets/SocketCreator.zig` resolve a hostname to `sockaddr_storage`?
- Is there a bsd.h function that accepts host+port strings for connect (like `bsd_create_listen_socket` does for listen)?
- Should `getaddrinfo` be called directly via C extern?

**Impact on plan:** Section 9 (`SocketCreator.zig`) is incomplete until this is resolved.

---

### A5. sockets_tests.zig and Notifier_tests.zig missing initPlatform/deinitPlatform

Both test files predate `tofu.initPlatform`/`tofu.deinitPlatform`. On Windows they will fail because WSAStartup is never called.

**Fix needed:** Add `try tofu.initPlatform(); defer tofu.deinitPlatform();` to each test in both files — same pattern used in `poller_tests.zig` and `pollercore_tests.zig`.

**Status:** Deferred — fix during Windows verification pass.

---

### A6. Implementation sequence is wrong — corrected order

The plan's staged sequence (backend first, then Skt/SocketCreator) is inverted. The backend's poller contract tests create TCP pairs using SocketCreator/Skt — the backend cannot be tested before those work.

**Corrected sequence:**

| Stage | Content | Acceptance |
| :---- | :------ | :--------- |
| **0** | VSCode `.vscode/` config updated for Zig+C mixed debugging | Debug session works with C source stepping |
| **1** | `build.zig` C sources + `Skt.zig` + `SocketCreator.zig` | `sockets_tests.zig` pass on Linux |
| **2** | Notifier already done — run `Notifier_tests.zig` | `Notifier_tests.zig` pass on Linux |
| **3** | `triggers.zig` + `usockets_backend.zig` | All 64 tests pass on Linux (4-mode sandwich) |
| **4** | Windows: adapter headers + compile | Cross-compile succeeds |
| **5** | macOS: verify | Cross-compile succeeds |
| **6** | CI + docs | linux.yml / mac.yml updated |

**Impact on plan:** Section 13 (Implementation Sequence) must be rewritten.

---

### A7. Stage 0 — VSCode configuration is a prerequisite

`.vscode/` configuration files must be updated for mixed Zig+C debugging before any implementation begins. This is Stage 0 (not Stage 5 as currently placed in the plan).

Files to review and update: `launch.json`, `tasks.json`, `settings.json`.
Minimum change known: add `"c"` to `sourceLanguages` in `launch.json`.
Other changes (build tasks for `-Dnetwork=usockets`, C include paths for IntelliSense) TBD.

**Impact on plan:** Move VSCode changes from Section 11/Stage 5 to Stage 0.
