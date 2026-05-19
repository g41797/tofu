# Transition to bun-usockets — Final Implementation Plan

**Status:** Authoritative  
**Date:** 2026-05-05  
**Based on:** source-level analysis of `vendor/bun-usockets/src/` and `src/ampe/linux/`

---

## 0. For the Implementing Agent

### Start Here

Read these files before writing any code:

1. `design/AGENT_STATE.md` — current status, hard constraints, session history template
2. This plan — architecture (§1), dispatch mechanism (§4), implementation sequence (§12)
3. `design/RULES.md` — doc and code style rules (§5 is mandatory)

### Stage Sequence

Follow §12 (Implementation Sequence) one stage at a time.
Run the acceptance criterion for each stage before starting the next.
Do not skip stages.

### Hard Constraints

- **No git commands.** The author manages version control manually.
- **No architectural changes** without explicit author approval.
- **GitHub workflows exist** — add the CI network matrix per §14 at the correct stage only.
- **Doc and comments style** — `design/RULES.md` §5. Short sentences. No marketing language.
- **"allows to verb"** is a grammar error. Restructure if found.
- **Use linux/ as reference.** For every stub in `usockets/`, use the corresponding `linux/` (or `mac/` / `windows/`) subfolder file as the primary reference for logic and structure.
- **NO POSIX.** Never use `std.posix` or raw POSIX APIs and structs in new code. Use `bsd_*` wrappers from bun-usockets. If you cannot find a `bsd_*` replacement for a specific struct or API, raise it as a blocking question before proceeding.

### Recording Your Work

After completing each stage:

1. Open `design/AGENT_STATE.md`.
2. Bump the version number and update the date in the file header.
3. Update the `Current Status` section — what was done, what is next.
4. Add a session history entry using the template in `design/AGENT_STATE.md` (Session History → Template).

---

# Reactor Shutdown & Thread Affinity Constraints

The Reactor maintains strict thread affinity for its event loop (e.g., kqueue, epoll). Resource initialization (`initPollEnv`) and deinitialization (`deleteAll`, `chnlsGroup_map.deinit`) must occur on the same thread (the I/O thread).

**Required Shutdown Protocol:**
1. **Signal Shutdown**: Main thread sets `shutdownFlag` to `true`.
2. **Best-Effort Notification**: Main thread sends an alert if the notifier is healthy, but the `shutdownFlag` handles the case where the notifier is already broken.
3. **Synchronize**: Main thread calls `waitFinish()` (join).
4. **Thread-Local Cleanup**: The I/O thread, upon seeing `shutdownFlag`, exits `loop()`. The `defer` blocks in `loop()` are then executed *on the I/O thread*, ensuring clean teardown of event loop resources.
5. **Final Destruction**: Only after the I/O thread has finished (thread join) does the main thread proceed to `gpa.destroy(rtr)`.


```zig
fn init(allocator: Allocator) AmpeError!Backend
fn deinit(self: *Backend) void
fn register(self: *Backend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void
fn modify(self: *Backend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void
fn unregister(self: *Backend, fd: FdType) void
fn wait(self: *Backend, timeout: i32, seqn_trc_map: *SeqnTrcMap) AmpeError!Triggers
```

Types:
- `FdType` — `c_int` on POSIX, `usize` on Windows
- `SeqN` — `u64` monotonic sequence (ABA protection)
- `Triggers` — packed struct with 8 trigger bits (recv, send, accept, connect, notify, err, timeout, oob)
- `SeqnTrcMap` — `std.AutoArrayHashMap(SeqN, *TriggeredChannel)`

**Reference implementation:** `src/ampe/linux/epoll_backend.zig`. It calls `epoll_create1`, `epoll_ctl`, `epoll_wait` directly via `std.posix`. The usockets backend replaces these with bun-usockets primitives but keeps the same reactor contract.

No callbacks. No threads. One `wait()` call blocks; events accumulate into `total_act`; control returns to caller.

### Why Manual Pull, Not High-Level uSockets

| | **This plan (Manual Pull)** | **High-Level uSockets** |
| :--- | :--- | :--- |
| **I/O control** | Zig calls `bsd_recv` / `bsd_send` directly | C calls Zig `on_data` / `on_writable` callbacks |
| **Backpressure** | Managed by Tofu `Pool` | Managed by uSockets internal buffer |
| **Integration cost** | Override 1 function (`us_internal_dispatch_ready_poll`) | Implement full VTable (`us_socket_context_options_t`) |
| **Reactor inversion** | None — pull model preserved | Yes — C drives the I/O loop |
| **Portability** | High (uses uSockets event loop only) | High |

---

## 2. Files to Implement

Four files in `src/ampe/usockets/`, unified across all platforms:

| File | Current state | Replaces |
| :--- | :--- | :--- |
| `Skt.zig` | stub | `linux/Skt.zig`, `mac/Skt.zig`, `windows/Skt.zig` |
| `SocketCreator.zig` | stub | `linux/SocketCreator.zig`, etc. |
| `triggers.zig` | partial | `linux/triggers.zig`, etc. |
| `usockets_backend.zig` | stub | `epoll_backend.zig` / `kqueue_backend.zig` / `wepoll_backend.zig` |
| `posix_net` module (`src/ampe/posix_net/`) | new | inline `extern fn` blocks in `Skt.zig` / `SocketCreator.zig` / `usockets_backend.zig` |

**`posix_net` module:** Standalone Zig module at `src/ampe/posix_net/`. No dependency on tofu types. Registered in `build.zig` as a named module. Consumers import: `const pn = @import("posix_net");` See §2.5 for details.

**Notifier:** `src/ampe/Notifier.zig` is platform-independent. `internal.zig` already imports it unconditionally. No usockets-specific file is needed or exists.

New files (Windows only, Stage 4):
- `posix_net/adapters/sys/epoll.h` — wepoll redirect with HANDLE↔int cast wrappers; `EPOLL_CLOEXEC` guard
- `posix_net/adapters/sys/timerfd.h` — Windows Waitable Timer adapter
- `posix_net/adapters/sys/eventfd.h` — Windows Event adapter
- `posix_net/adapters/win_compat.h` — `EINPROGRESS`, `ENAMETOOLONG`, `EAFNOSUPPORT` defines
- `posix_net/adapters/us_epoll_win.c` — all `us_*` epoll-path functions for Windows (replaces `epoll_kqueue.c`)

---

## 2.5 `src/ampe/posix_net/` — Standalone Module (Our std.posix + std.net)

`posix_net` is a standalone Zig module. It has no dependency on tofu types (`AmpeError`, `SeqN`, `Triggers`). It uses `c_int` as fd type and its own `PnError`. Registered in `build.zig` as a named module; consumers import it by name, not by path. Create these files first in Stage 0.5.

### File structure

```
src/ampe/posix_net/
├── posix_net.zig         # module root + facade: re-exports from subfiles
├── ffi.zig               # ALL extern fn (bsd_* + us_*) — never imported directly by consumers
├── types.zig             # Fd (c_int), Addr (bsd_addr_t wrapper), PnError, addrinfo, constants
├── socket.zig            # sendBuf, recvToBuf, acceptSocket, closeSocket, nodelay, keepalive, wouldBlock
│                         # addrFamily, addrPort, addrUnixPath, deleteUnixPath
├── creator.zig           # createListenSocket (TCP+UDS), createConnectSocket (TCP+UDS)
└── poll.zig              # us_loop + us_poll wrappers
```

### posix_net.zig content

```zig
// src/ampe/posix_net/posix_net.zig — module root
// build.zig: b.addModule("posix_net", .{ .root_source_file = b.path("src/ampe/posix_net/posix_net.zig") })
// Import in consumers: const pn = @import("posix_net");

pub usingnamespace @import("types.zig");
pub usingnamespace @import("socket.zig");
pub usingnamespace @import("creator.zig");
pub const poll = @import("poll.zig");
```

`ffi.zig` is never imported directly by consumers. Only `types.zig`, `socket.zig`, `creator.zig`, and `poll.zig` import it.

### Comment requirement

Every file in `src/ampe/posix_net/` must follow `design/RULES.md §5`:
- Short sentences. No marketing language. No AI filler.
- Each file starts with a one-line comment stating its role. Example: `// All bsd_* and us_* C externs. Never import this file directly.`
- Public functions have a one-line comment only when the purpose is not obvious from the name.
- Bullet lists for multi-step flows in comments.
- Plain English. Tech terms (`bsd_addr_t`, `LIBUS_SOCKET_READABLE`) are fine as-is.

### Naming convention

Zig wrapper functions use plain camelCase — no prefix. The `pn` module alias serves as the namespace prefix at call sites.

| Call site | Source in posix_net/ |
| :--- | :--- |
| `pn.sendBuf(fd, buf)` | `socket.zig` |
| `pn.recvToBuf(fd, buf)` | `socket.zig` |
| `pn.acceptSocket(fd, &addr)` | `socket.zig` |
| `pn.closeSocket(fd)` | `socket.zig` |
| `pn.nodelay(fd)` | `socket.zig` |
| `pn.wouldBlock()` | `socket.zig` |
| `pn.Addr` | `types.zig` |
| `pn.FdType` | `types.zig` |
| `pn.POLL_TYPE_SOCKET` | `types.zig` |
| `pn.LIBUS_SOCKET_READABLE` | `types.zig` |
| `pn.LIBUS_SOCKET_WRITABLE` | `types.zig` |
| `pn.createListenSocket(host, port, options)` | `creator.zig` |
| `pn.createListenSocketUnix(path, pathlen, options)` | `creator.zig` |
| `pn.createConnectSocket(addr, options)` | `creator.zig` |
| `pn.createConnectSocketUnix(path, pathlen, options)` | `creator.zig` |
| `pn.poll.createLoop()` | `poll.zig` |
| `pn.poll.freeLoop(loop)` | `poll.zig` |
| `pn.poll.createPoll(loop, ext_size)` | `poll.zig` |
| `pn.poll.freePoll(p, loop)` | `poll.zig` |
| `pn.poll.initPoll(p, fd, poll_type)` | `poll.zig` |
| `pn.poll.startPoll(p, loop, events)` | `poll.zig` |
| `pn.poll.changePoll(p, loop, events)` | `poll.zig` |
| `pn.poll.stopPoll(p, loop)` | `poll.zig` |
| `pn.poll.pollExt(p)` | `poll.zig` |
| `pn.poll.tick(loop, timeout)` | `poll.zig` |
| `pn.addrFamily(&addr)` | `socket.zig` — returns `u16` (`AF_INET`, `AF_UNIX`, …) |
| `pn.addrPort(&addr)` | `socket.zig` — returns `?u16`; null for Unix sockets |
| `pn.addrUnixPath(&addr)` | `socket.zig` — returns `[]const u8` path slice |
| `pn.deleteUnixPath(path)` | `socket.zig` — wraps `unlink()` via `ffi.zig` |
| `pn.PnError` | `types.zig` — posix_net's own error union (no `AmpeError`) |
| `pn.Fd` | `types.zig` — `c_int` alias |

The underlying C functions keep the `bsd_` prefix in `ffi.zig` — fixed by bun-usockets.

### Two-layer pattern (example from posix_net/socket.zig)

```zig
const ffi = @import("ffi.zig");

pub fn sendBuf(fd: Fd, buf: []const u8) PnError!?usize {
    const n = ffi.bsd_send(fd, buf.ptr, @intCast(buf.len));
    if (n < 0) {
        if (ffi.bsd_would_block() != 0) return null;
        return PnError.CommunicationFailed;
    }
    if (n == 0) return null;
    return @intCast(n);
}

pub fn wouldBlock() bool {
    return ffi.bsd_would_block() != 0;
}
```

`bsd_create_connect_socket` takes a pre-resolved `sockaddr_storage*` — see §9 for hostname resolution via `getaddrinfo`.

---

## 3. bun-usockets API Reference

### 3.1 Public API (`libusockets.h`)

```c
struct us_loop_t *us_create_loop(void *hint,
    void (*wakeup_cb)(us_loop_r),
    void (*pre_cb)(us_loop_r),
    void (*post_cb)(us_loop_r),
    unsigned int ext_size);
void us_loop_free(struct us_loop_t *loop);

struct us_poll_t *us_create_poll(us_loop_r loop, int fallthrough, unsigned int ext_size);
void us_poll_free(struct us_poll_t *p, struct us_loop_t *loop);
void us_poll_init(us_poll_r p, LIBUS_SOCKET_DESCRIPTOR fd, int poll_type);
void us_poll_start(us_poll_r p, us_loop_r loop, int events);
void us_poll_change(us_poll_r p, us_loop_r loop, int events);
void us_poll_stop(us_poll_r p, struct us_loop_t *loop);
LIBUS_SOCKET_DESCRIPTOR us_poll_fd(us_poll_r p);
void *us_poll_ext(us_poll_r p);  // returns p + 1; 16-byte aligned
void us_socket_local_address(us_socket_r s, char *buf, int *length);
```

### 3.2 Non-public required function (`epoll_kqueue.c`, line 35)

```c
void us_loop_run_bun_tick(struct us_loop_t *loop, const struct timespec *timeout);
```

Not in `libusockets.h`. Zig must `extern` it.

### 3.3 BSD wrappers (`internal/networking/bsd.h`)

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

**Windows note (portable backend):** `bsd_set_nonblocking` was originally a no-op on `_WIN32` (comment said "Libuv will set windows sockets as non-blocking"). This project does not use Libuv. Fixed in the `g41797/uSockets` fork (2026-05-12): the `_WIN32` branch now calls `ioctlsocket((SOCKET)fd, FIONBIO, &mode)`. Affects the portable backend only — all `bsd_create_*` and `bsd_accept_socket` paths in the portable backend are now non-blocking on Windows. The native Windows backend (`windows/SocketCreator.zig`) uses `std.posix.socket()` + explicit `ioctlsocket` and is unaffected.

### 3.4 POLL_TYPE constants (`internal/internal.h`)

```c
enum {
    POLL_TYPE_SOCKET        = 0,  // connected/listening socket — we use this
    POLL_TYPE_SOCKET_SHUT_DOWN = 1,
    POLL_TYPE_SEMI_SOCKET   = 2,
    POLL_TYPE_CALLBACK      = 3,  // fires fn pointer — NOT used
    POLL_TYPE_UDP           = 4,
    POLL_TYPE_POLLING_OUT   = 8,  // flag: registered for WRITE
    POLL_TYPE_POLLING_IN    = 16, // flag: registered for READ
};
```

---

## 4. Dispatch Mechanism (the core design decision)

### 4.1 How bun-usockets dispatches events

`epoll_kqueue.c` runs `epoll_wait` (or `kevent64`) and then calls:

```c
us_internal_dispatch_ready_poll(poll, error, eof, events);
```

where `events` is already masked by registered interests:
```c
events &= us_poll_events(poll);  // filter by what we registered for
```

### 4.2 Where the function lives

`us_internal_dispatch_ready_poll` is defined in **`loop.c`** (lines 369–550). For `POLL_TYPE_SOCKET` it casts the poll to `us_socket_t*` and calls high-level socket callbacks — machinery we are not using.

### 4.3 The override approach

We define `us_internal_dispatch_ready_poll` in Zig and supply our own dispatch logic. This is the exact pattern Bun's Zig runtime uses with this C library.

**The linker conflict:** `loop.c` defines the function as a regular C symbol. Our Zig `export fn` also defines it. This creates a duplicate symbol. Resolution:

**Apply a one-line patch to `vendor/bun-usockets/src/loop.c`:** add `__attribute__((weak))` to the function definition:

```c
// Before (loop.c line 369):
void us_internal_dispatch_ready_poll(struct us_poll_t *p, int error, int eof, int events) {

// After:
/* weak: overridden by Zig export in usockets_backend.zig */
__attribute__((weak)) void us_internal_dispatch_ready_poll(struct us_poll_t *p, int error, int eof, int events) {
```

With a weak definition in C, the linker uses our strong Zig-exported symbol. This is a minimal, targeted vendor patch — one annotation on one line.

**License:** `loop.c` is Apache License 2.0 (Alex Hultman, 2018–2021). Apache 2.0 explicitly permits modification. Requirements: retain the original license header (unchanged) and mark the modified file. The comment `/* weak: overridden by Zig export in usockets_backend.zig */` satisfies the marking requirement.

**Alternative if patching is unacceptable:** add `-Wl,--allow-multiple-definition` to the link flags and rely on link order (Zig objects appear before C objects in LLD). This is fragile and not recommended.

### 4.4 g_wait_state — lifecycle, thread safety, and misuse detection

`us_internal_dispatch_ready_poll` has a fixed C signature — we cannot add parameters to it. Yet after `us_loop_run_bun_tick` returns, `wait()` must know the aggregate of all triggers that fired. `g_wait_state` bridges the gap: it is a pointer to a `WaitState` allocated on `wait()`'s own stack frame, published before the C call and unpublished after.

**Lifecycle within a single `wait()` call:**

```
wait() enters
  │
  ├─ assert g_wait_state == null        ← detect nested/concurrent misuse, panic if violated
  ├─ var ws = WaitState{...}            ← allocate on wait()'s stack frame
  ├─ g_wait_state = &ws                 ← publish: dispatch fn can now find the context
  │
  ├─ us_loop_run_bun_tick(loop, &ts)    ← C code runs synchronously on this thread
  │     │
  │     └─ (zero or more times, same thread, same call stack):
  │         us_internal_dispatch_ready_poll(poll, err, eof, events)
  │              reads  g_wait_state    ← finds wait()'s stack frame
  │              reads  us_poll_ext(p)  ← finds *TriggeredChannel for this fd
  │              writes ws.total_act    ← accumulates into wait()'s local
  │              writes tc.act          ← updates the channel directly
  │
  ├─ us_loop_run_bun_tick returns       ← all dispatch calls done; no C callbacks pending
  ├─ g_wait_state = null                ← unpublish (via defer — runs even on error return)
  └─ return ws.total_act
```

**Why `threadlocal`:**
Each OS thread that runs a reactor calls `wait()` independently. A process-wide `var` would be a data race between threads. `threadlocal var` gives each thread its own slot — multiple reactors on separate threads work correctly without locking.

**Nested call detection:**
If `g_wait_state != null` on entry to `wait()`, a second `wait()` is already active on this thread. This is a programming error (e.g. calling `wait()` from inside a dispatch callback). Detect and panic:

```zig
// Thread-local: one slot per thread; isolates concurrent reactor instances.
threadlocal var g_wait_state: ?*WaitState = null;

const WaitState = struct {
    map: *SeqnTrcMap,
    total_act: Triggers,
};
```

**Initial value:**
Zig zero-initializes all module-level variables, including `threadlocal` ones. `?*WaitState` zero is `null`. When a thread starts, its slot is already `null` before `wait()` is ever called — no explicit initialization needed. The full per-thread lifecycle is:

```
thread starts  → g_wait_state = null   (Zig runtime, automatic zero-init)
wait() call 1  → set → used → null     (defer)
wait() call 2  → set → used → null     (defer)
...
thread exits   → slot destroyed
```

**Cleanup:**
`defer g_wait_state = null` in `wait()` guarantees the slot is cleared on every exit path — normal return, error return, or (in debug builds) a trapped assertion. After `wait()` returns, the stack frame holding `WaitState` is gone; the null ensures the dispatch fn cannot access freed memory if called outside a `wait()` context (the `orelse return` guard in dispatch handles any residual call).

### 4.5 Our dispatch implementation

```zig
export fn us_internal_dispatch_ready_poll(
    poll: *anyopaque,
    err: c_int,
    eof: c_int,
    events: c_int,
) callconv(.C) void {
    const ws = g_wait_state orelse return;  // called outside wait() — ignore
    const tc_ptr = @as(**TriggeredChannel, @ptrCast(@alignCast(pn.poll.pollExt(poll))));
    const tc = tc_ptr.*;
    const act = triggers_mod.fromEvents(events, err, eof, tc.exp);
    tc.act = tc.act.lor(act);
    ws.total_act = ws.total_act.lor(act);
}
```

**Why the dispatcher does not check SeqN:**  
ABA protection is handled at the `SeqnTrcMap` level (the caller maps `SeqN → *TriggeredChannel` before each `wait()`). By the time the dispatcher fires, the poll is guaranteed live: `unregister()` calls `us_poll_stop()` before `us_poll_free()`, which removes the fd from epoll. The kernel cannot deliver an event for a stopped poll, so stale dispatch calls after unregistration are impossible. Checking SeqN inside the dispatcher would be redundant — the epoll kernel guarantee is stronger.

And in `wait()`:

```zig
pub fn wait(self: *UsocketsBackend, timeout: i32, seqn_trc_map: *SeqnTrcMap) AmpeError!Triggers {
    if (g_wait_state != null) @panic("wait() called recursively or from two reactors on the same thread");
    // ... wire ext pointers ...
    var ws = WaitState{ .map = seqn_trc_map, .total_act = Triggers{} };
    g_wait_state = &ws;
    defer g_wait_state = null;
    // ... call us_loop_run_bun_tick ...
}
```

### 4.6 ext memory layout

`us_poll_ext(p)` returns `p + 1` (pointer arithmetic on `us_poll_t*`), i.e. the address immediately after the struct. Memory is allocated as `sizeof(us_poll_t) + ext_size`. The ext region is 16-byte aligned (`LIBUS_EXT_ALIGNMENT`).

We use `ext_size = @sizeOf(*TriggeredChannel)` (8 bytes on 64-bit). The `*TriggeredChannel` pointer is written at registration and read in dispatch.

---

## 5. `build.zig` Changes

### 5.1 C sources (Linux and macOS)

Add under both `lib` and `lib_unit_tests`, gated on `network == .usockets`:

```zig
if (network == .usockets) {
    const is_kqueue = target.result.os.tag == .macos or
        target.result.os.tag == .freebsd or
        target.result.os.tag == .netbsd or
        target.result.os.tag == .openbsd;
    const is_windows = target.result.os.tag == .windows;

    const backend_flag = if (is_kqueue) "-DLIBUS_USE_KQUEUE" else "-DLIBUS_USE_EPOLL";
    const flags = &.{ "-fno-sanitize=undefined", "-DLIBUS_NO_SSL", backend_flag };

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
        // Windows: shim epoll/timerfd/eventfd (see §11 for contents)
        artifact.addIncludePath(b.path("src/ampe/windows/adapters"));
        artifact.addCSourceFile(.{
            .file = b.path("src/ampe/windows/wepoll/wepoll.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });
        artifact.addIncludePath(b.path("src/ampe/windows/wepoll"));
    }
}
```

### 5.2 Required Zig exports (C-callable)

In `usockets_backend.zig`:

```zig
export fn Bun__panic(msg: [*:0]const u8, len: usize) callconv(.C) noreturn {
    _ = len;
    @panic(std.mem.span(msg));
}

export fn Bun__isEpollPwait2SupportedOnLinuxKernel() callconv(.C) i32 {
    return 0; // disable epoll_pwait2; fall back to epoll_pwait
}

export fn Bun__JSC_onBeforeWait(jsc_vm: *anyopaque) callconv(.C) void {
    _ = jsc_vm; // loop.data.jsc_vm is null — never called
}
```

---

## 6. `usockets/triggers.zig`

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

### 7.1 Imports

```zig
const pn = @import("posix_net");
// pn.poll.* wraps all us_create_loop, us_create_poll, us_poll_*, us_loop_run_bun_tick externs
// pn.POLL_TYPE_SOCKET, pn.LIBUS_SOCKET_READABLE, pn.LIBUS_SOCKET_WRITABLE — from posix_net/types.zig
```

All `us_*` C functions are declared in `posix_net/ffi.zig` and wrapped in `posix_net/poll.zig`. Use `pn.poll.*` at call sites. Use `pn.POLL_TYPE_SOCKET` wherever the poll type constant is needed.

### 7.2 Struct

```zig
const PollMap = std.AutoHashMap(FdType, *anyopaque);

const UsocketsBackend = struct {
    loop: *anyopaque,  // us_loop_t*
    polls: PollMap,    // fd → us_poll_t*
    allocator: Allocator,
};

pub const Poller = core.PollerCore(UsocketsBackend);
```

### 7.3 init / deinit

```zig
pub fn init(allocator: Allocator) AmpeError!UsocketsBackend {
    const loop = pn.poll.createLoop()
        orelse return AmpeError.AllocationFailed;
    return .{
        .loop = loop,
        .polls = PollMap.init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *UsocketsBackend) void {
    var it = self.polls.iterator();
    while (it.next()) |entry| {
        const poll = entry.value_ptr.*;
        pn.poll.stopPoll(poll, self.loop);
        pn.poll.freePoll(poll, self.loop);
    }
    self.polls.deinit();
    pn.poll.freeLoop(self.loop);
}
```

### 7.4 register / modify / unregister

```zig
pub fn register(self: *UsocketsBackend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void {
    _ = seq; // SeqN managed by PollerCore via SeqnTrcMap; not stored in poll
    const poll = pn.poll.createPoll(self.loop, @sizeOf(*TriggeredChannel))
        orelse return AmpeError.AllocationFailed;
    pn.poll.initPoll(poll, @intCast(fd), pn.POLL_TYPE_SOCKET);
    // ext (*TriggeredChannel) is wired by wait() on every call via seqn_trc_map iteration
    pn.poll.startPoll(poll, self.loop, triggers_mod.toEvents(exp));
    try self.polls.put(fd, poll);
}

pub fn modify(self: *UsocketsBackend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void {
    _ = seq;
    const poll = self.polls.get(fd) orelse return AmpeError.CommunicationFailed;
    pn.poll.changePoll(poll, self.loop, triggers_mod.toEvents(exp));
}

pub fn unregister(self: *UsocketsBackend, fd: FdType) void {
    if (self.polls.fetchRemove(fd)) |entry| {
        const poll = entry.value;
        pn.poll.stopPoll(poll, self.loop);
        pn.poll.freePoll(poll, self.loop);
    }
}
```

**SeqN / TriggeredChannel wiring:** `wait()` iterates `seqn_trc_map` and writes the `*TriggeredChannel` into each poll's ext memory before calling `us_loop_run_bun_tick`. No PollerCore hook is needed. See §7.5.

### 7.5 wait

```zig
pub fn wait(self: *UsocketsBackend, timeout: i32, seqn_trc_map: *SeqnTrcMap) AmpeError!Triggers {
    if (g_wait_state != null) @panic("wait() called recursively or from two reactors on the same thread");
    // Wire ext pointers before polling
    var it = seqn_trc_map.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        if (self.polls.get(tc.fd)) |poll| {
            const ptr = @as(**TriggeredChannel, @ptrCast(@alignCast(pn.poll.pollExt(poll))));
            ptr.* = tc;
        }
    }

    var ws = WaitState{ .map = seqn_trc_map, .total_act = Triggers{} };
    g_wait_state = &ws;
    defer g_wait_state = null;

    if (timeout < 0) {
        pn.poll.tick(self.loop, null);
    } else {
        const ts = std.c.timespec{
            .tv_sec = @divTrunc(timeout, 1000),
            .tv_nsec = @as(isize, @rem(timeout, 1000)) * std.time.ns_per_ms,
        };
        pn.poll.tick(self.loop, &ts);
    }

    if (ws.total_act.isZero()) ws.total_act.timeout = .on;
    return ws.total_act;
}
```

---

## 8. `usockets/Skt.zig`

Replaces `std.posix.*` with `pn.*` wrappers. Translates `pn.PnError` → `AmpeError` at each method boundary.

```zig
const pn = @import("posix_net");
```

All socket operations use `pn.sendBuf(...)`, `pn.recvToBuf(...)`, etc. No inline `extern fn` blocks.

**Struct layout:**

```zig
pub const Skt = @This();

fd: pn.Fd = -1,
uds_server_path: ?[108]u8 = null,  // non-null only for UDS server sockets
```

`std.net.Address` is removed entirely. `uds_server_path` is set by `SocketCreator.createUdsServer` after a successful `pn.createListenSocketUnix`. Address info is retrieved on demand via `pn.localAddr` / `pn.remoteAddr`.

**Method mapping:**

| Skt method | pn.* call | Notes |
| :--------- | :-------- | :---- |
| `isSet()` | `skt.fd >= 0` | field check |
| `getPort()` | `pn.localAddr(fd, &addr)` + `pn.addrPort(&addr)` | returns null for UDS |
| `listen(host, port)` | `pn.createListenSocket(host, port, 0)` | |
| `listenUnix(path, pathlen)` | `pn.createListenSocketUnix(path, pathlen, 0)` | caller sets `uds_server_path` |
| `accept(server_fd)` | `pn.acceptSocket(server_fd, &addr)` | |
| `connect(addr)` | `pn.createConnectSocket(&sockaddr_storage, 0)` — addr pre-resolved | |
| `sendBuf(buf)` | `pn.sendBuf(fd, buf)` | |
| `recvToBuf(buf)` | `pn.recvToBuf(fd, buf)` | |
| `close()` | `pn.closeSocket(fd)` + `pn.deleteUnixPath(path)` if `uds_server_path != null` and `path[0] != 0` | skip abstract namespace |
| `disableNagle()` | `pn.nodelay(fd)` | |

**Error translation (PnError → AmpeError at method boundary):**

```zig
fn toAmpe(e: pn.PnError) AmpeError {
    return switch (e) {
        pn.PnError.WouldBlock        => AmpeError.WouldBlock,
        pn.PnError.PeerDisconnected  => AmpeError.PeerDisconnected,
        pn.PnError.InvalidAddress    => AmpeError.InvalidAddress,
        else                         => AmpeError.CommunicationFailed,
    };
}
```

One `catch |e| return toAmpe(e)` per method. No `mapErrno()` — error identity comes from `pn.*` return values.

**`connect()` return value:** `bsd_create_connect_socket` / `bsd_create_connect_socket_unix` returns a valid fd or -1. It does not separately signal "immediate success" vs "EINPROGRESS pending". Always return `true` for any non-negative fd:

```zig
pub fn connect(skt: *Skt) AmpeError!bool {
    // bsd_create_connect_socket already performed connect() during Skt creation.
    // A valid fd means connected (UDS: typically immediate) or EINPROGRESS (TCP).
    // The reactor handles both correctly: WRITE event arrives immediately for EINPROGRESS.
    _ = skt;
    return true;
}
```

Error cases (fd == -1) are handled by `SocketCreator` before `connect()` is called.

---

## 9. `usockets/SocketCreator.zig`

### 9.1 Listen side

`bsd_create_listen_socket(host, port, 0, &err)` handles DNS internally — no Zig-side resolution needed.

`bsd_create_listen_socket_unix(path, pathlen, 0, &err)` — for UDS. On Linux, prepend `\x00` for abstract namespace (comptime branch, same pattern as `Notifier.zig`).

### 9.2 UDS — Linux abstract namespace

Pass the full path including the leading `\x00` byte, with `pathlen` = full length including `\x00`. `bsd_create_listen_socket_unix` calls `bsd_create_unix_socket_address` internally, which checks `path[0] == '\0'` and handles abstract namespace correctly. No Zig-side workaround needed — bsd.c has it. Pattern (same as existing `Notifier.zig`):

```zig
// Abstract UDS path on Linux: prepend \x00
var buf: [108]u8 = undefined;
buf[0] = 0;
@memcpy(buf[1..][0..name.len], name);
const pathlen = name.len + 1;
const fd = pn.createListenSocketUnix(&buf, pathlen, 0);  // pn = @import("posix_net")
```

### 9.3 Connect side — hostname resolution

`bsd_create_connect_socket` takes a **pre-resolved `sockaddr_storage*`**. Resolution uses `getaddrinfo` via C extern (libc is already linked by `artifact.link_libc = true`). See also §9.2 for UDS abstract namespace handling.

```zig
const addrinfo = extern struct {
    ai_flags: c_int,
    ai_family: c_int,
    ai_socktype: c_int,
    ai_protocol: c_int,
    ai_addrlen: std.c.socklen_t,
    ai_addr: ?*std.c.sockaddr,
    ai_canonname: ?[*:0]u8,
    ai_next: ?*addrinfo,
};

extern fn getaddrinfo(
    node: ?[*:0]const u8,
    service: ?[*:0]const u8,
    hints: ?*const addrinfo,
    res: *?*addrinfo,
) c_int;
extern fn freeaddrinfo(res: *addrinfo) void;

fn resolveConnect(host: [:0]const u8, port: u16) AmpeError!FdType {
    const hints = addrinfo{
        .ai_flags = 0,
        .ai_family = 0,   // AF_UNSPEC: try IPv4 and IPv6
        .ai_socktype = 1, // SOCK_STREAM
        .ai_protocol = 0,
        .ai_addrlen = 0,
        .ai_addr = null,
        .ai_canonname = null,
        .ai_next = null,
    };
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port})
        catch return AmpeError.InvalidAddress;

    var res: ?*addrinfo = null;
    if (getaddrinfo(host.ptr, port_str.ptr, &hints, &res) != 0)
        return AmpeError.InvalidAddress;
    defer if (res) |r| freeaddrinfo(r);

    var cur = res;
    while (cur) |ai| : (cur = ai.ai_next) {
        const fd = pn.createConnectSocket(
            @ptrCast(ai.ai_addr), 0);
        if (fd >= 0) return @intCast(fd);
    }
    return AmpeError.InvalidAddress;
}
```

`getaddrinfo` is available on both Linux (libc) and Windows (`ws2_32.dll`). No platform-specific code needed here.

---

## 10. Notifier

`src/ampe/Notifier.zig` is platform-independent. `internal.zig` imports it unconditionally:

```zig
pub const Notifier = @import("Notifier.zig");  // line 9 of internal.zig — already done
```

No `usockets/Notifier.zig` exists or is needed. Notifier uses `Skt` + `SocketCreator` internally — once those are implemented, Notifier works unchanged under `-Dnetwork=portable`.

**No `bsd_socketpair` needed.** `Notifier.zig` uses the "Manual Pair" approach — it calls `SocketCreator.createUdsListener` + `createUdsSocket`, not `std.posix.socketpair`. Once `usockets/SocketCreator.zig` is implemented with `bsd_*`, Notifier works under `-Dnetwork=portable` without modification.

---

## 11. Windows Adapter Headers (Stage 4)

All adapter files live under `posix_net/adapters/`. They are included only when compiling `us_epoll_win.c` and the usockets C files on Windows.

### wepoll location

wepoll (`wepoll.c` + `wepoll.h`) is vendored at `src/ampe/windows/wepoll/`. It is shared by both the posix and portable backends on Windows. No separate copy is needed under `posix_net/`.

### `epoll_kqueue.c` on Windows

Upstream uSockets does NOT compile `epoll_kqueue.c` on Windows. Our build follows the same rule:
- When `!is_windows`: compile `epoll_kqueue.c` from the usockets dependency.
- When `is_windows`: compile `posix_net/adapters/us_epoll_win.c` instead.

`us_epoll_win.c` contains all `us_*` epoll-path functions extracted from `epoll_kqueue.c` plus our added `us_loop_run_tick`. The kqueue path is omitted — not applicable on Windows.

### `posix_net/adapters/sys/epoll.h`

Redirects `epoll_create1`, `epoll_ctl`, `epoll_wait` to wepoll via HANDLE↔int cast wrappers. wepoll uses `HANDLE` for its epoll descriptor; usockets stores it as `int`. Windows kernel handles fit in the lower 32 bits — the cast is safe.

Also defines `EPOLL_CLOEXEC 0` if not already defined (wepoll does not define it).

### `posix_net/adapters/sys/timerfd.h`

Emulates `timerfd_create` / `timerfd_settime` via Windows Waitable Timers. The timer handle is cast to `int` for storage in `us_poll_t.state.fd`.

### `posix_net/adapters/sys/eventfd.h`

Emulates `eventfd` / `eventfd_write` via a Windows manual-reset event. The event handle is cast to `int`.

### `posix_net/adapters/win_compat.h`

Defines errno constants missing from MinGW headers:
- `EINPROGRESS 115` — non-blocking connect in progress
- `ENAMETOOLONG 36`
- `EAFNOSUPPORT 47`

### `posix_net/adapters/us_epoll_win.c`

Contains all `us_*` epoll-path functions for Windows (replaces `epoll_kqueue.c`). Includes `libusockets.h` and `internal/internal.h`. All epoll calls go through `posix_net/adapters/sys/epoll.h` (which redirects to wepoll). Uses `closesocket()` instead of `close()` for timer and async fds. Uses `eventfd_write()` for async wakeup.

### `build.zig` portable block (both `libMod` and `lib_unit_tests`)

```zig
if (!is_windows) {
    mod.addCSourceFile(.{ .file = usockets_dep.path("src/eventing/epoll_kqueue.c"), .flags = flags });
} else {
    mod.addCSourceFile(.{ .file = b.path("posix_net/adapters/us_epoll_win.c"), .flags = flags });
}
mod.addIncludePath(usockets_dep.path("src/"));
mod.addIncludePath(usockets_dep.path("src/internal"));
mod.addIncludePath(usockets_dep.path("src/internal/networking"));
mod.link_libc = true;

if (is_windows) {
    mod.addIncludePath(b.path("posix_net/adapters"));
    mod.addIncludePath(b.path("src/ampe/windows/wepoll"));
}
```

The unconditional Windows block (both backends share wepoll):
```zig
if (target.result.os.tag == .windows) {
    lib.addCSourceFile(.{ .file = b.path("src/ampe/windows/wepoll/wepoll.c"), .flags = &.{"-fno-sanitize=undefined"} });
    lib.addIncludePath(b.path("src/ampe/windows/wepoll"));
}
```

---

## 12. Implementation Sequence

| Stage | Work | Acceptance criterion |
| :---- | :--- | :------------------- |
| **-1** | Scan `linux/*.zig` for all `std.posix` / `std.net` usage; verify each has a `bsd_*` replacer (see §12.5) | All usages accounted for; no blockers remain — **DONE** |
| **0** | VSCode config (launch.json + tasks.json) | C source stepping works in debugger — **DONE** |
| **0.5** | `build.zig` (posix_net module + C sources) + `src/ampe/posix_net/` (6 files) + `tests/posix_net/posix_net_tests.zig` (27 tests) | `zig build test -Dnetwork=portable` runs all 27 `posix_net_tests`; pass on Linux — **DONE** |
| **1** | `Skt.zig` + `SocketCreator.zig` (using `pn.*`) | `sockets_tests.zig` pass on Linux — **DONE** |
| **2** | Notifier already done — run tests | `Notifier_tests.zig` pass on Linux — **DONE** |
| **3** | `triggers.zig` + `usockets_backend.zig` | All 99 tests pass, 4-mode sandwich on Linux — **DONE** |
| **4** | Windows adapter headers (`posix_net/adapters/`), `us_epoll_win.c`, `build.zig` split for epoll_kqueue.c/us_epoll_win.c, windows.yml CI matrix | Cross-compile `x86_64-windows-gnu -Dnetwork=portable` succeeds — **DONE** |
| **5** | macOS verify | Cross-compile `x86_64-macos -Dnetwork=portable` and `aarch64-macos -Dnetwork=portable` succeed — **DONE** |
| **6** | Native hardware testing + CI network matrix live | Full sandwich passes on Linux; `AGENT_STATE.md` bumped |
| **7** | Documentation — fix and complete all docs affected by migration | All changed modules have accurate doc comments per §5; no stale references remain |
| **8** | Transition `wepoll` from git submodule to `build.zig.zon` managed dependency | `wepoll` listed in `.zon`; `src/ampe/windows/wepoll/` removed; all `build.zig` references use `b.dependency("wepoll", .{})`; Windows CI passes — **DONE** |
| **9** | Source Partitioning — introduce `src/platform/stdposix/` and `src/platform/posixnet/`; move `posix_net/` root into `src/platform/posixnet/wrapper/` | All tests pass 4-mode sandwich on Linux; cross-compiles clean — see §23 — **DONE** |
| **Polish** | Refactor `build.zig` portable C setup into a helper (eliminate duplication between `libMod` and `lib_unit_tests`). Create `posix_net/adapters/us_epoll_linux.c` and `posix_net/adapters/us_kqueue_mac.c` as per-platform replacements for `epoll_kqueue.c`. Revert `epoll_kqueue.c` to upstream (remove 4→3 arg patch, `us_loop_run_tick`, `#ifndef _WIN32` guard). Eliminates all dual-path patching of `epoll_kqueue.c`. | `zig build test` passes; cross-compiles pass; `epoll_kqueue.c` matches upstream |

**Stage 3 — Linux 4-mode sandwich (DONE — 99/99):**
```sh
zig build test -Doptimize=Debug        -Dnetwork=portable  # 99/99
zig build test -Doptimize=ReleaseSafe  -Dnetwork=portable  # 99/99
zig build test -Doptimize=ReleaseFast  -Dnetwork=portable  # 99/99
zig build test -Doptimize=ReleaseSmall -Dnetwork=portable  # 99/99
```

**Stage 4 — Windows cross-compile (DONE):**
```sh
zig build -Dtarget=x86_64-windows-gnu -Dnetwork=portable  # ✅
```

**Stage 5 — macOS cross-compile (DONE):**
```sh
zig build -Dtarget=x86_64-macos  -Dnetwork=portable  # ✅
zig build -Dtarget=aarch64-macos -Dnetwork=portable  # ✅
```

**Stage 6 — Windows native testing (IN PROGRESS):**
- Bug found (2026-05-12): `bsd_set_nonblocking` no-op on Windows → all C-layer sockets blocking. Fixed in `g41797/uSockets/src/bsd.c`. Author must push and update `build.zig.zon`.
- Secondary bugs fixed (2026-05-12): `setLingerAbort` no-op → TIME_WAIT accumulation; backlog 512 vs 1024. Both fixed via `posix_net/adapters/pn_utils.c`.
- **Linux result (2026-05-12):** 101/101 tests pass.
- **Windows UDS fix (2026-05-12):** `bsd_create_connect_socket_unix` in usockets `bsd.c` uses `errno != EINPROGRESS` to detect connect-in-progress. On Windows, non-blocking connect sets `WSAGetLastError() == WSAEWOULDBLOCK` — usockets treated it as fatal. Fixed by adding `pn_create_connect_socket_unix` to `pn_utils.c` (Windows: check `WSAEWOULDBLOCK`; Linux: delegate to `bsd_create_connect_socket_unix`). Wired through `ffi.zig` and `creator.zig`.
- **macOS CI fixes — Second Round (2026-05-13):** Four critical bugs fixed. (1) `LIBUS_SOCKET_WRITABLE` corrected to `2` for kqueue. (2) `triggers.zig` updated to treat `EV_EOF` on a `READ` filter as read-ready, matching native macOS logic. (3) `accept()` in all portable backends fixed to correctly initialize client address (was reusing listener address). (4) `addrinfo` layout corrected for BSD systems. See §15.2.
- Pending: full Windows 4-mode verification (`zbta_win.cmd`) + portable 4-mode on Windows after `build.zig.zon` update; macOS CI run.

---

## 12.5 std.posix / std.net → bsd_* Mapping (Stage -1 result)

Scanned from `linux/Skt.zig` and `linux/SocketCreator.zig` on 2026-05-06. **No blockers found.**

| std.posix / std.net usage | Source file | bsd_* replacement | Notes |
| :--- | :--- | :--- | :--- |
| `std.posix.socket_t` | Skt.zig | `c_int` (POSIX) / `usize` (Windows) — `LIBUS_SOCKET_DESCRIPTOR` | Use `FdType` from `internal.zig` |
| `std.net.Address` | Skt.zig, SocketCreator.zig | Not needed — `bsd_*` take host string or `sockaddr*` | Remove from usockets/Skt.zig struct |
| `std.posix.AF.INET`, `AF.INET6` | Skt.zig | Not needed — `bsd_create_listen_socket` handles all families internally | |
| `std.posix.AF.UNIX` | Skt.zig | `bsd.bsd_create_listen_socket_unix` / `bsd.bsd_create_connect_socket_unix` | |
| `std.posix.SOCK.NONBLOCK`, `SOCK.CLOEXEC` | Skt.zig, SocketCreator.zig | `bsd_set_nonblocking(fd)` — called inside `bsd_create_*` already | `bsd_create_*` always sets NONBLOCK (fixed for Windows in fork 2026-05-12) |
| `std.posix.setsockopt` (REUSEADDR, REUSEPORT) | Skt.zig | `bsd_create_listen_socket` calls `bsd_set_reuse` internally | No Zig call needed |
| `std.posix.SO.LINGER`, `posix.SOL.SOCKET` | Skt.zig | `bsd_close_socket` handles linger-on-close internally | No `setLingerAbort` needed |
| `std.posix.IPPROTO.TCP`, `std.posix.TCP.NODELAY` | Skt.zig | `pn.nodelay(fd)` | Direct replacement |
| `std.posix.send` | Skt.zig | `pn.sendBuf(fd, buf)` | Returns `isize`; negative = error |
| `std.posix.recv` | Skt.zig | `pn.recvToBuf(fd, buf)` | Returns `isize`; 0 = EOF |
| `std.posix.SendError.WouldBlock` | Skt.zig | `pn.wouldBlock()` | Check after negative return |
| `std.posix.RecvFromError.WouldBlock` | Skt.zig | `pn.wouldBlock()` | Check after negative return |
| `posix.bind`, `posix.listen` | Skt.zig | `pn.createListenSocket(host, port, 0)` | |
| `posix.getsockname` | Skt.zig | `pn.localAddr(fd, &addr)` + `pn.addrPort(&addr)` | `bsd_addr_t` is opaque |
| `posix.socket` | SocketCreator.zig | Replaced by `bsd_create_listen_socket` / `bsd_create_connect_socket` | No raw socket() call |
| `posix.close` | Skt.zig | `pn.closeSocket(fd)` | Cross-platform including WIN32 |
| `posix.system.connect` (connectOs) | Skt.zig | `pn.createConnectSocket(&sockaddr_storage, 0)` | Returns fd; negative = error |
| `posix.fcntl` (F.GETFL/SETFL/GETFD/SETFD) (acceptOs) | Skt.zig | Not needed — `bsd_accept_socket` sets NONBLOCK internally | Remove acceptOs; use bsd_accept_socket |
| `posix.AcceptError.WouldBlock` | Skt.zig | `bsd.bsd_would_block() != 0` after `bsd_accept_socket` returns -1 | |
| `posix.ConnectError` | Skt.zig | Map via `bsd_would_block()` | EINPROGRESS = WouldBlock |
| `posix.sockaddr.in`, `posix.socklen_t` | Skt.zig | Not needed — `bsd_*` use `bsd_addr_t` / `sockaddr_storage` internally | |
| `std.net.Address.resolveIp` | SocketCreator.zig | `getaddrinfo` extern — see §9.2 | |
| `std.net.getAddressList` | SocketCreator.zig | `getaddrinfo` extern — see §9.2 | |
| `std.net.Address.initUnix` | SocketCreator.zig | Pass path directly to `bsd_create_listen_socket_unix` / `bsd_create_connect_socket_unix` | |
| `std.os.windows.ws2_32.ioctlsocket` | SocketCreator.zig | Not needed — `bsd_set_nonblocking` handles Windows | |
| `std.os.linux.EPOLL.IN/OUT/ERR/HUP/RDHUP/PRI` | triggers.zig | `bsd.LIBUS_SOCKET_READABLE` (1), `bsd.LIBUS_SOCKET_WRITABLE` (2) | bun-usockets masks epoll internally |
| `posix.errno(-1)` in `mapErrno` | Skt.zig | `pn.wouldBlock()` | Cross-platform EAGAIN check |

**One open question for Stage 1:** `findFreeTcpPort()` in `linux/Skt.zig` uses raw `posix.socket` + `posix.bind` + `posix.getsockname`. Verify whether any test running under `-Dnetwork=portable` calls this function. If yes: rewrite using `bsd_create_listen_socket("0.0.0.0", 0, 0, &err)` + `bsd_local_addr` + `bsd_addr_get_port`. If only called from posix-backend tests: no action needed.

---

## 13. VSCode Debug Config (Stage 0)

### `launch.json`

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug Tests",
            "type": "lldb",
            "request": "launch",
            "program": "${workspaceFolder}/zig-out/bin/test",
            "args": [],
            "cwd": "${workspaceFolder}",
            "preLaunchTask": "zig build install",
            "sourceLanguages": ["zig", "c"]
        },
        {
            "name": "Debug Tests (usockets)",
            "type": "lldb",
            "request": "launch",
            "program": "${workspaceFolder}/zig-out/bin/test",
            "args": [],
            "cwd": "${workspaceFolder}",
            "preLaunchTask": "zig build install usockets",
            "sourceLanguages": ["zig", "c"]
        }
    ]
}
```

### `tasks.json` — additions

```json
{
    "label": "zig build install usockets",
    "type": "shell",
    "command": "zig",
    "args": ["build", "install", "-Dnetwork=portable", "--summary", "all"],
    "options": { "cwd": "${workspaceFolder}" },
    "presentation": { "echo": true, "reveal": "always", "focus": false, "panel": "shared", "clear": true },
    "problemMatcher": {
        "owner": "zig",
        "fileLocation": ["relative", "${workspaceFolder}"],
        "pattern": {
            "regexp": "^(.+):(\\d+):(\\d+):\\s+(error|warning|note):\\s+(.*)$",
            "file": 1, "line": 2, "column": 3, "severity": 4, "message": 5
        }
    },
    "group": "build"
},
{
    "label": "zig build test usockets",
    "type": "shell",
    "command": "zig",
    "args": ["build", "test", "-Dnetwork=portable", "--summary", "all"],
    "options": { "cwd": "${workspaceFolder}" },
    "presentation": { "echo": true, "reveal": "always", "focus": false, "panel": "shared", "clear": true },
    "problemMatcher": {
        "owner": "zig",
        "fileLocation": ["relative", "${workspaceFolder}"],
        "pattern": {
            "regexp": "^(.+):(\\d+):(\\d+):\\s+(error|warning|note):\\s+(.*)$",
            "file": 1, "line": 2, "column": 3, "severity": 4, "message": 5
        }
    },
    "group": "test"
}
```

`settings.json`: no changes needed.

---

## 14. CI Network Matrix

Run both `-Dnetwork=posix` and `-Dnetwork=portable` in CI for the duration of the porting work (Stages 1–6), so neither backend regresses on any push. The `NetworkBackend` enum in `build.zig` declares `posix` and `portable` as valid values — `-Dnetwork=${{ matrix.network }}` works for both.

### When to add (per platform)

| Workflow | Add at | Reason |
| :--- | :--- | :--- |
| `linux.yml` | Stage 3 | All 99 tests pass with portable on Linux |
| `windows.yml` | Stage 4 | Windows adapter headers complete |
| `mac.yml` | Stage 5 | macOS portable verified |

### `linux.yml` after Stage 3

Replace the existing `strategy.matrix` block and all four `zig build test` steps:

```yaml
strategy:
  fail-fast: false
  matrix:
    os: [ubuntu]
    network: [posix, portable]

steps:
  - uses: actions/checkout@v5
    with:
      submodules: recursive

  - uses: mlugg/setup-zig@v2
    with:
      version: 0.15.2
      use-cache: false

  - run: rm -rf ./.zig-cache/

  - run: zig build test -freference-trace --summary all -Doptimize=Debug        -Dnetwork=${{ matrix.network }}

  - run: rm -rf ./.zig-cache/

  - run: zig build test -freference-trace --summary all -Doptimize=ReleaseSafe  -Dnetwork=${{ matrix.network }}

  - run: rm -rf ./.zig-cache/

  - run: zig build test -freference-trace --summary all -Doptimize=ReleaseFast  -Dnetwork=${{ matrix.network }}

  - run: rm -rf ./.zig-cache/

  - run: zig build test -freference-trace --summary all -Doptimize=ReleaseSmall -Dnetwork=${{ matrix.network }}
```

This produces 2 parallel jobs per push: `build (ubuntu, posix)` and `build (ubuntu, portable)`, each running all 4 optimize modes. GitHub labels the jobs by matrix values automatically.

### `mac.yml` after Stage 5

Same change — replace `matrix.os: [macos]` with the two-dimension form and add `-Dnetwork=${{ matrix.network }}` to all four test steps. No other difference from linux.yml.

### `windows.yml` after Stage 4

Add `network: [posix, portable]` to the matrix. Job name: `Build and test (${{ matrix.network }})`. All four `zig build test` steps gain `-Dnetwork=${{ matrix.network }}`.

`deleteUnixPath` ABI resolution (Stage 4 decision): declare both `unlink` and `_unlink` in `ffi.zig` without OS guard. MinGW provides `unlink`; MSVC CRT provides `_unlink`. Both are declared; the linker resolves whichever is present.

```yaml
jobs:
  build:
    name: Build and test (${{ matrix.network }})
    runs-on: ${{ matrix.os }}-latest
    strategy:
      fail-fast: false
      matrix:
        os: [windows]
        network: [posix, portable]

    steps:
      - run: git config --global core.autocrlf false
      - uses: actions/checkout@v5
        with:
          submodules: recursive
      - uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2
          use-cache: false
      - run: zig build test -freference-trace --summary all -Doptimize=Debug        -Dnetwork=${{ matrix.network }}
      - run: rm -rf ./.zig-cache/
        shell: bash
      - run: zig build test -freference-trace --summary all -Doptimize=ReleaseSafe  -Dnetwork=${{ matrix.network }}
      - run: rm -rf ./.zig-cache/
        shell: bash
      - run: zig build test -freference-trace --summary all -Doptimize=ReleaseFast  -Dnetwork=${{ matrix.network }}
      - run: rm -rf ./.zig-cache/
        shell: bash
      - run: zig build test -freference-trace --summary all -Doptimize=ReleaseSmall -Dnetwork=${{ matrix.network }}
```

This produces 2 parallel jobs per push: `Build and test (posix)` and `Build and test (portable)`.

### Cost

2× CI minutes per platform during the transition (8 jobs on Linux instead of 4). Acceptable trade-off for continuous dual-backend verification. After porting is complete (Stage 6), keep the matrix permanently — both backends remain supported.

---

## 15. Native Hardware Testing (Stage 6)

Run the full 4-mode sandwich on native Linux hardware. Cross-compile to verify Windows and macOS do not regress:

```sh
# Native Linux — all four optimize modes
zig build test -Doptimize=Debug        -Dnetwork=portable  # 64/64
zig build test -Doptimize=ReleaseSafe  -Dnetwork=portable  # 64/64
zig build test -Doptimize=ReleaseFast  -Dnetwork=portable  # 64/64
zig build test -Doptimize=ReleaseSmall -Dnetwork=portable  # 64/64

# Cross-compile (no native macOS or Windows machine needed for compile check)
zig build -Dtarget=x86_64-windows-gnu -Dnetwork=portable
zig build -Dtarget=x86_64-macos      -Dnetwork=portable
zig build -Dtarget=aarch64-macos     -Dnetwork=portable
```

Native macOS and Windows hardware testing follows the same sandwich pattern once the cross-compile passes.

---

## 15.1 Stage 6 — Linux Portable Test Failure Analysis (2026-05-12)

After the `bsd_set_nonblocking` Windows fix was pushed and `build.zig.zon` updated,
`zig build test -Dnetwork=portable -Doptimize=Debug` on Linux failed:

```
handleReConnnectOfTcpClientServerST error.ListenFailed
thread panic: attempt to unwrap error: ListenFailed
```

`bsd_create_listen_socket` returns `LIBUS_SOCKET_ERROR` only if `bind()` or `listen()` fails.
The port was freshly allocated by `FindFreeTcpPort()`.

### What is definitely wrong — fix regardless

`portable/Skt.zig:setLingerAbort` (line 77) is a no-op. The comment "Already handled by
pn.closeSocket in bun-usockets" is **wrong**: `bsd_close_socket` just calls `close(fd)` with no
`SO_LINGER`. Native backends (linux, windows, mac) all set `SO_LINGER l_onoff=1 l_linger=0`
before close → RST instead of FIN → immediate socket release, no TIME_WAIT.

Fix required:
- Add `bsd_set_linger_abort(fd)` to new file `posix_net/adapters/pn_utils.c` (our own C file, not vendored uSockets). `bsd_set_linger_abort` is not called from any `bsd_*` internal path — it is called only from the Zig side, so it can live in any C file we own.
- Declare `pub extern fn bsd_set_linger_abort(fd: LIBUS_SOCKET_DESCRIPTOR) void;` in `posix_net/ffi.zig`.
- Add `pub fn setLingerAbort(fd: Fd) void` wrapper in `posix_net/socket.zig` and re-export from `posix_net/posix_net.zig`.
- Implement `setLingerAbort` in `src/ampe/portable/Skt.zig` to call `pn.setLingerAbort(skt.fd)`. Fix the wrong comment.
- Wire `posix_net/adapters/pn_utils.c` into `build.zig` (add as C source for both `libMod` and `lib_unit_tests` when `network == .portable`).

### What needs to be checked before knowing the cause of ListenFailed

Three candidates:

**1. Port race between concurrent tests.**
`FindFreeTcpPort()` allocates a port then releases it. Another concurrent test thread can grab
the same port in the gap. The test log shows multiple threads active simultaneously. If two
threads get the same port from `FindFreeTcpPort()`, one `bind()` fails. Check: is
`handleReConnnectOfTcpClientServerST` running concurrently with other listener-creating tests?

**2. File descriptor exhaustion.**
The reconnect test makes 1000 connect attempts. If each attempt in the portable backend leaves
a socket open (not properly closed before the next attempt), `socket()` inside
`bsd_create_listen_socket` may fail with `EMFILE`. Check: does each failed connect attempt close
its socket before the Reactor processes the next HelloRequest?

**3. Pre-existing flakiness.**
The `_WIN32` branch change cannot affect Linux. The failure may be a timing-sensitive race that
was always possible but rarely triggered. Check: does the test fail consistently or
intermittently across multiple runs?

**4. Listener backlog discrepancy.**
`bsd_create_listen_socket` hardcodes `listen(fd, 512)`. The native Linux backend uses
`posix.listen(fd, 1024)`. This is not a `ListenFailed` cause, but it is an inconsistency.
Fix in our code (not in vendored `bsd.c`): add `pn_create_listen_socket(host, port, options, backlog)`
and `pn_create_listen_socket_unix(path, pathlen, options, backlog)` to
`posix_net/adapters/pn_utils.c`. Each calls the corresponding `bsd_create_listen_socket*` then
re-calls `listen(fd, backlog)` to set the correct value. Replace the `bsd_create_listen_socket`
calls in `posix_net/creator.zig` with these wrappers, passing `backlog=1024`.

### Summary table

| Issue | Action |
| :---- | :----- |
| `setLingerAbort` no-op in portable | **FIXED (2026-05-12)** — `bsd_set_linger_abort` in `posix_net/adapters/pn_utils.c`; wired through ffi/socket/posix_net/Skt |
| Listener backlog 512 vs native 1024 | **FIXED (2026-05-12)** — `pn_create_listen_socket` and `pn_create_listen_socket_unix` in `pn_utils.c`; `creator.zig` uses them with `backlog=1024` |
| `ListenFailed` root cause | TIME_WAIT accumulation from `setLingerAbort` no-op — eliminated by the fix above |
| `bsd_set_nonblocking` fix causing Linux failure | Not the cause — Linux path unchanged |

---

## 15.2 Stage 6 — macOS CI Failure Analysis (2026-05-12)

macOS CI failed 6/54 portable tests. Two independent root causes.

### Bug 1 — `addrFamily` reads wrong bytes on macOS/BSD

`posix_net/socket.zig:addrFamily` read `sockaddr.mem[0..2]` as a `u16`. On Linux/Windows, `sa_family` is a `u16` at offset 0 — correct. On macOS/BSD, `sockaddr` has:
- `sa_len` (u8) at offset 0
- `sa_family` (u8) at offset 1

The u16 read returned `sa_family * 256 + sa_len`. For AF_INET (family=2, sa_len=16): `2*256+16 = 528`. For AF_UNIX (family=1, sa_len=80): `1*256+80 = 336`. Both wrong.

**Fix:** comptime branch in `addrFamily`:
```zig
if (comptime (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD())) {
    return addr.mem[1]; // sa_family is at offset 1 on macOS/BSD
}
```

`addrUnixPath` was unaffected by this change — `sun_path` starts at offset 2 on both Linux and macOS. Once `addrFamily` returns the correct value, `addrUnixPath`'s guard passes and the path is read correctly.

**Posix backend (`network=posix`) not affected.** The mac posix backend uses `std.net.Address.any.family` — Zig's standard library correctly abstracts the `sa_len` prefix. It never calls `pn.addrFamily`.

### Bug 2 — TCP connect-in-progress on macOS

Three TCP tests called `send()`/`getpeername()` immediately after `resolveConnect`:
- `bsd TCP send+recv roundtrip`
- `bsd_send returns null (WouldBlock) when send buffer full`
- `bsd_remote_addr returns peer address after TCP connect`

On Linux, non-blocking connect to localhost completes immediately (connect() returns 0). On macOS, it may return EINPROGRESS. A subsequent `send()` on an in-progress socket returns ENOTCONN (errno 57), not EAGAIN — so `bsd_would_block()` returns false and `sendBuf` returns `CommunicationFailed`.

**Fix:** added `pn_wait_writable` to `pn_utils.c`:
```c
int pn_wait_writable(LIBUS_SOCKET_DESCRIPTOR fd, int timeout_ms) {
    // select() on write set, then getsockopt(SO_ERROR)
}
```
`resolveConnect` in `creator.zig` calls `pn_wait_writable(fd, 5000)` after `bsd_create_connect_socket`. On Linux, the connected socket is immediately writable — select returns at once. On macOS, select waits for EINPROGRESS to complete.

**Impact on portable SocketCreator:** `createTcpClient` calls `resolveConnect`. The returned fd is now guaranteed connected. The event loop will find it immediately writable (connect already done) — correct behaviour.

### Summary

| Failure | Cause | Fix |
| :------ | :---- | :-- |
| `addrFamily` returns 528/336 | `sa_len` byte at offset 0 on macOS/BSD | `mem[1]` on Darwin/BSD; u16 at `mem[0]` on Linux |
| 3 TCP tests: `CommunicationFailed` | EINPROGRESS not waited; `send` → ENOTCONN | `pn_wait_writable` in `pn_utils.c`; called from `resolveConnect` |
| `addrUnixPath` returns empty | `addrFamily` guard failed (528 ≠ 1) | Fixed by Bug 1 fix |

## 15.3 Stage 6 — Portable Backend Structural Alignment (2026-05-12)

After adding `poller_tests` to macOS CI, two new failures appeared: `writable immediately` and `modify recv to send`. Root cause is an architectural mismatch between the portable backend and posix backends.

**Root cause:** portable `createTcpClient` calls `resolveConnect` which does socket+connect+blocking `pn_wait_writable` in one step. Posix backends (linux, mac, windows) all use two-step: `createConnectSocket` creates socket only → upper layer calls `Skt.connect()` (non-blocking, returns false on EINPROGRESS) → poller waits for WRITABLE → `Skt.connect()` returns true.

`pn_wait_writable` in `resolveConnect` is architecturally wrong — it blocks in a non-blocking system.

**Additional gaps found (cross-backend comparison, Addendum A):**
- `accept()` — portable missing `setLingerAbort` on accepted socket
- `disableNagle()` — portable calls `pn.nodelay` unconditionally; must check address family
- `createListenerSocket` — portable returns `NotImplementedYet`; posix has full implementation
- `Skt` state — portable stores `fd` only; posix backends store `address: std.net.Address` (needed for `connect()`, `setREUSE`, `disableNagle`, `deleteUDSPath`)

**Fix approach:** iterative per-OS subfolders. Add `portable/linux/` first. `portable/Skt.zig` and `portable/SocketCreator.zig` become redirect files dispatching to OS subfolders with legacy fallback. New C function `pn_connect_socket(fd, sockaddr*, addrlen)` added to `pn_utils.c` as TCP equivalent of `bsd_connect_socket_unix`.

See implementation plan in plan file for full details.

---

## 16. Critical Files

| File | Action |
| :--- | :----- |
| `vendor/bun-usockets/src/loop.c` (line 369) | Add `__attribute__((weak))` to `us_internal_dispatch_ready_poll` |
| `build.zig` | Add usockets C source + include blocks (both `lib` and `lib_unit_tests`) |
| `src/ampe/posix_net/posix_net.zig` | New — module root + facade |
| `src/ampe/posix_net/ffi.zig` | New — all `bsd_*` and `us_*` C extern declarations |
| `src/ampe/posix_net/types.zig` | New — `Fd`, `Addr`, `PnError`, constants |
| `src/ampe/posix_net/socket.zig` | New — `sendBuf`, `recvToBuf`, `acceptSocket`, `closeSocket`, `wouldBlock`, `addrFamily`, `addrPort`, `addrUnixPath`, `deleteUnixPath` |
| `src/ampe/posix_net/creator.zig` | New — `createListenSocket`, `createConnectSocket`, UDS variants |
| `src/ampe/posix_net/poll.zig` | New — `createLoop`, `createPoll`, `startPoll`, `tick`, etc. |
| `tests/posix_net/posix_net_tests.zig` | New — 27 tests (7 groups); gated on `-Dnetwork=portable` |
| `src/ampe/usockets/Skt.zig` | Implement using `pn.*` (via `@import("posix_net")`); `fd: pn.Fd` + `uds_server_path` |
| `src/ampe/usockets/SocketCreator.zig` | Implement using `pn.create*` + `getaddrinfo` extern |
| `src/ampe/usockets/triggers.zig` | Add `toEvents` / `fromEvents` |
| `src/ampe/usockets/usockets_backend.zig` | Full implementation + export `us_internal_dispatch_ready_poll` |
| `posix_net/adapters/sys/epoll.h` | New — wepoll redirect (HANDLE↔int cast wrappers, EPOLL_CLOEXEC guard) |
| `posix_net/adapters/sys/timerfd.h` | New — Windows Waitable Timer adapter |
| `posix_net/adapters/sys/eventfd.h` | New — Windows Event adapter |
| `posix_net/adapters/win_compat.h` | New — EINPROGRESS, ENAMETOOLONG, EAFNOSUPPORT defines |
| `posix_net/adapters/us_epoll_win.c` | New — all `us_*` epoll-path functions for Windows (replaces `epoll_kqueue.c`) |
| `.vscode/launch.json` | Add `"c"` to sourceLanguages, add usockets config |
| `.vscode/tasks.json` | Add usockets build and test tasks |

---

## 17. Open Items (minor, resolved during implementation)

- **`bsd_create_connect_socket` second parameter:** The `options` field in `bsd.h` — verify whether `0` is the correct default (non-blocking, no delay) or if a flag must be set. Read `bsd.c` implementation at Stage 1.

- **Abstract UDS namespace prefix on Linux:** `Notifier.zig` already handles this pattern. Copy the same `\x00` prefix logic to `SocketCreator.createUdsServer` for consistency.

- **Vendored bun-usockets commit pin:** Record the exact git commit hash of `vendor/bun-usockets` in `AGENT_STATE.md` when Stage 1 begins. This allows future vendor updates to be evaluated against the specific known-good revision that all implementation choices are based on.

- **DONE (Stage 2) — Notifier test SIGABRT fixed:** `initPlatform` now creates a thread-local loop (`threadlocal var g_loop`) via `us_loop_create`; `deinitPlatform` frees it. WSAStartup still runs first on Windows. Nesting guard: `@panic` if `initPlatform` called twice on same thread. `getLoop()` accessor added for the backend. `Notifier_tests.zig` updated to use only `initPlatform`/`deinitPlatform` (explicit `createLoop`/`freeLoop` calls removed). 92/92 tests pass; SIGABRT eliminated from Notifier test binary.

- **RESOLVED (Stage 4) — `deleteUnixPath` Windows ABI:** Both `unlink` and `_unlink` declared in `ffi.zig` without OS guard. `deleteUnixPath` in `posix_net/socket.zig` uses a comptime branch to call `_unlink` on Windows and `unlink` on POSIX. MinGW provides `unlink`; MSVC CRT provides `_unlink`; both declarations coexist without conflict.

- **RESOLVED (Stage 4) — Windows CI matrix:** Single dimension: `network: [posix, portable]` on a single Windows runner. No ABI variants — `x86_64-windows-gnu` only for CI. See §14 for the final `windows.yml` form.

- **Polish — `build.zig` refactor:** The portable C source setup block is duplicated between `libMod` and `lib_unit_tests`. Extract into a helper function after Stage 6.

- **WelcomeResponse port header (deferred):** After TCP listener creation, the Reactor adds the assigned listener port to `WelcomeResponse` text headers. Client reads the port from the response instead of calling `getPort()` out-of-band. Current tests use `listener.getPort()` directly (works because both sides are in the same process). This proposal makes the protocol self-describing. Implement at Stage 7 (protocol stabilisation) or earlier if cross-platform test coordination requires it. UDS listeners: no port header (not applicable).

- **std.net.Address migration — audit required before Zig 0.16 upgrade:** `std.net.Address` is defined in `std/net.zig` in Zig 0.15.x. In Zig 0.16 it moves into `std.Io`. Any file that imports `std.net.Address` directly will fail to compile. The portable backend (`portable/linux/Skt.zig`, `portable/mac/Skt.zig`, `portable/win/Skt.zig`) uses `std.net.Address` as its primary address type — as a field, for construction (`initIp4`, `initIp6`, `initUnix`), and for querying (`getPort`, `getOsSockLen`, `.any`). The posix backends (`linux/`, `mac/`, `windows/`) also use `std.net.Address`. Before the Zig 0.16 upgrade: audit all `std.net` usage in `src/ampe/` and `tests/`; replace with own definitions built on the stable `std.c.sockaddr*` types. The pattern is already established in `posix_net/ffi.zig` (custom `addrinfo` struct). `posix_net` itself is already `std.net`-free.

- **FIX APPLIED (2026-05-11):** Root cause of echo hang identified and fixed. `posix_net_backend.zig` was pre-wiring `*TriggeredChannel` pointers into `pollExt` before each tick — architecturally different from `epoll_backend.zig` and fragile under map changes. Fix: store `SeqN` in `pollExt` at register time (one write, never changes); dispatch reads `SeqN` from `pollExt` and calls `ws.map.get(seq)` — identical shape to epoll's `ev.data.u64` approach. Pre-wiring loop in `wait()` eliminated. `PollMap` simplified to `fd → *anyopaque`. Full test suite running to confirm fix.

---

## 18. Addendum — AI Review Record

**Verdict: Overall Solid, Production-Ready Plan with Minor Risks & Refinements**

**Summary Rating: 8.5/10** — Excellent technical depth, strong alignment with tofu's callback-less single-threaded reactor architecture, and pragmatic choice of **bun-usockets**. The plan is authoritative, well-structured for staged implementation, and preserves tofu's core invariants (PollerCore, ABA protection, backpressure via manual I/O, no callbacks/threads). It correctly prioritizes Linux verification with "sandwich" testing.

### Key Strengths (Pros)
- **Architectural Fidelity**: Perfect preservation of `PollerCore` contract (exactly 6 functions) and "pull" model. Using `us_poll_t` + `POLL_TYPE_SOCKET` + `ext` memory for `*TriggeredChannel` + `g_wait_state`/`us_internal_dispatch_ready_poll` override is clever and matches Bun's own Zig integration patterns.
- **bun-usockets Choice**: Correct final decision over upstream uSockets. `us_loop_run_bun_tick` + public `us_poll_*` APIs + `us_socket_local_address` eliminate major pain points. Bun's fork is battle-tested in a high-performance Zig context.
- **Unified Backend**: `src/ampe/usockets/` as single cross-platform folder (with minimal comptime branches) is elegant and reduces maintenance vs. per-OS folders.
- **Minimal Vendor Patch**: One-line `__attribute__((weak))` on `us_internal_dispatch_ready_poll` in `loop.c` is low-risk, license-compliant (Apache 2.0), and standard weak-symbol override technique.
- **Testing Strategy**: Contract tests (`sockets_tests.zig`, `Notifier_tests.zig`, poller core tests) + 4-mode sandwich (Debug/ReleaseSafe/Fast/Small) + cross-compile + native verification is rigorous.
- **Windows Handling**: Forced `LIBUS_USE_EPOLL` + thin shims (`epoll.h`, `timerfd.h`, `eventfd.h`) reusing wepoll is smart and keeps dependency surface small.
- **Notifier & Platform Init**: Retaining socket-pair Notifier and promoting `initPlatform`/`deinitPlatform` (WSAStartup) is clean.

### Potential Issues / Risks (status at time of review)
- ~~**Poll Type Inconsistency**~~: **RESOLVED.** `POLL_TYPE_SOCKET` is correct. Weak override means `loop.c`'s implementation never runs regardless of poll type. `POLL_TYPE_CALLBACK` ruled out — see §4.
- **g_wait_state Thread Safety**: `threadlocal` is correct. Nested `wait()` panic guard added to §7.5.
- **Ext Memory Wiring**: Re-wiring on every `wait()` is necessary and correct — see §4.5 / §7.5.
- **Error Mapping & Edge Cases**: `mapErrno()` in `Skt.zig` handles Windows `WSA*` vs. POSIX `errno`. `EINTR` retries are in `bsd.c` — `Skt.zig` does not need to handle them.
- **Build Complexity**: Linker order for weak symbols and `Bun__*` exports — verify at Stage 1.
- **No Major Wrong Decisions**: Pivot from upstream uSockets to bun-usockets was correct.

### Recommended Refinements
1. ~~**Consolidate Poll Type**~~: **SUPERSEDED.** `POLL_TYPE_SOCKET` is correct. No change needed.
2. ~~**SeqN/TriggeredChannel Wiring hook**~~: **RESOLVED.** `wait()` wires ext directly — no PollerCore hook. See §7.4 / §7.5.
3. **Add Defensive Checks**: Validate ext alignment and dispatch guard (`g_wait_state orelse return`) — both already in §4.5 / §7.5.
4. **Version Pin**: Record vendored bun-usockets commit hash — added to §17 Open Items.
5. **Performance**: Monitor vs. original epoll after Stage 3 passes.
6. **Fallback**: Keep POSIX backends fully functional under `-Dnetwork=posix`.

**Overall Verdict**: High-quality, low-regret migration plan. Proceed with Stage 0–3 on Linux first.

---

## Historical Notes

*Content moved here because it is superseded by or absorbed into the main plan body.*

### Minor Documentation Drift (from original AI review)

> Slight mismatches between the two MDs (e.g., poll type, `POLL_TYPE_CALLBACK` emphasis) — expected in iterative planning, but consolidate before coding.

Context: "the two MDs" referred to `transition-2-usockets-plan.md` and `bun-usockets-implementation.md`, both since deleted. The consolidation is complete — this plan is the single authoritative document.

### Analysis of Raised Points (planning-phase counter-arguments)

These were written as counter-arguments to the original AI review during planning. Their conclusions are now directly incorporated into the main plan sections.

**Poll Type Inconsistency — not a real risk.**
The concern was that `POLL_TYPE_SOCKET` triggers high-level socket callbacks. This is only true if `loop.c`'s `us_internal_dispatch_ready_poll` runs. With `__attribute__((weak))`, our Zig export replaces that function entirely. `POLL_TYPE_CALLBACK` is ruled out — its ext layout requires the first 8 bytes to hold a C fn pointer, displacing our `*TriggeredChannel`. (Now in §4.3.)

**Ext memory wiring in every `wait()` — necessary, not an optimization target.**
`seqn_trc_map` is passed fresh each `wait()`. `*TriggeredChannel` cannot be known at `register()` time. Since PollerCore heap-allocates channels for pointer stability, the pointers are stable across calls — only the mapping needs applying each `wait()`. (Now in §7.5.)

**`EINTR` in `Skt.zig` — already handled.**
`bsd.c` retries on `EINTR` internally. (Now in §18 Potential Issues.)

**`POLL_TYPE_CALLBACK` recommendation — superseded.**
Based on the old approach before the dispatch override was confirmed. With the Zig override, `POLL_TYPE_SOCKET` is correct and simpler. (Now in §4.3.)

---

## Addendum A: Skt and SocketCreator — cross-backend public API comparison

These tables document the behavioral differences between the native posix backends (linux, mac, windows) and the portable (posix_net) backend. They drive the portable backend alignment fix.

**Status legend:** `OK` = no meaningful difference across all targets. `OK (linux, mac)` = fixed for Linux and macOS; Windows still needs verification. `OK (linux, mac, win)` = fixed for all three targets. `FIX` = still differs (pending).

**Last updated:** 2026-05-13 after `portable/linux/`, `portable/mac/`, `portable/win/` all complete.

### A.1 `Skt` — linux/mac vs portable

| Function | linux/mac native | portable (all targets) | Status |
|---|---|---|---|
| `isSet` | `socket != null` | `fd != INVALID_FD` | OK |
| `rawFd` | `socket orelse -1` | bitcasts `fd` (handles Windows `usize`) | OK |
| `socketHandle` | `?std.posix.socket_t` | `?pn.Fd` | OK |
| `getPort` | `address.getPort()` | `pn.localAddr(fd)` + `pn.addrPort` | OK |
| `listen` | full: setREUSE, bind, listen, getsockname | no-op — done inside `pn_create_listen_socket` | OK |
| `accept` | syscall; `setLingerAbort` on accepted fd | `pn.acceptSocket` + `pn.setLingerAbort` on accepted fd | OK (linux, mac, win) |
| **`connect`** | calls `connectOs()` against stored `address`; returns `false` on EINPROGRESS | calls `pn.connectSocket`/`pn.connectSocketUnix`; returns `false` on WouldBlock | OK (linux, mac, win) |

| `setREUSE` | `setsockopt(SO_REUSEPORT/SO_REUSEADDR)` | no-op — set inside `pn_create_listen_socket` | OK |
| `setLingerAbort` | `setsockopt(SO_LINGER)` | `pn.setLingerAbort` → `bsd_set_linger_abort` | OK |
| `disableNagle` | `setsockopt(TCP_NODELAY)` — TCP only | checks `address.any.family` (or `uds_path` on win); calls `pn.nodelay` for INET/INET6 | OK (linux, mac, win) |
| `findFreeTcpPort` | `posix.socket` + bind 0 + getsockname | `pn.findFreeTcpPort` | OK |
| `sendBuf/recvToBuf` | `std.posix.send/recv` | `pn.sendBuf/recvToBuf` | OK |
| `close` | `setLingerAbort` + `posix.close` + UDS unlink | `pn.closeSocket` + UDS unlink (via `address.any.family` on linux/mac; via `uds_path` on win) | OK |
| **State** | `socket: ?socket_t` + `address: std.net.Address` | linux/mac: `fd + address`; win: `fd + address + uds_path` | OK (linux, mac, win) |

### A.2 `SocketCreator` — linux/mac vs portable

| Function | linux/mac native | portable (all targets) | Status |
|---|---|---|---|
| `createTcpServer` | `resolveIp` → `createListenerSocket` (socket+bind+listen) | `resolveIp` → `createListenerSocket` via `pn_create_listen_socket_from_sockaddr` | OK (linux, mac, win) |
| **`createTcpClient`** | `getAddressList` → `createConnectSocket` (socket only, no connect) | `getAddressList` → `createConnectSocket` (socket only, no connect) | OK (linux, mac, win) |
| `createUdsServer` | `initUnix` → `createListenerSocket` | linux/mac: `initUnix` → `pn.createListenSocketUnix`; win: `pn.createListenSocketUnix` + `uds_path` | OK (linux, mac, win) |
| `createUdsClient` | `initUnix` → `createConnectSocket` (socket only) | linux/mac: `initUnix` → `createConnectSocket`; win: `pn.createClientSocket(AF_UNIX)` + `uds_path` | OK (linux, mac, win) |
| **`createConnectSocket`** | socket only + `setLingerAbort`; stores `address` in Skt | `pn.createClientSocket` + `pn.setLingerAbort`; stores `address` in Skt | OK (linux, mac, win) |
| `createListenerSocket` | socket + bind + listen | `pn.createListenSocketFromSockaddr` (SO_REUSEADDR + SO_REUSEPORT + bind + listen) | OK (linux, mac, win) |

### A.3 `Skt` — windows vs portable

| Function | windows native | portable/win | Status |
|---|---|---|---|
| `isSet` | `socket != null` | `fd != INVALID_FD` | OK |
| `rawFd` | truncates `SOCKET` ptr to i32 | bitcasts `fd` (usize→u32→i32) | OK |
| `socketHandle` | `?ws2_32.SOCKET` | `?pn.Fd` | OK |
| `getPort` | `address.getPort()` from stored `address` | `pn.localAddr(fd)` + `pn.addrPort` | OK |
| `listen` | full: setREUSE, `ws2_32.bind`, `ws2_32.listen`, `ws2_32.getsockname` | no-op — done inside `pn_create_listen_socket` | OK |
| `accept` | `ws2_32.accept`; WSAEWOULDBLOCK→null; `setLingerAbort` | `pn.acceptSocket` + `pn.setLingerAbort` | OK |
| **`connect`** | `ws2_32.connect`; returns `false` on WSAEWOULDBLOCK, `true` on WSAEISCONN | `pn.connectSocket`/`pn.connectSocketUnix`; returns `false` on WouldBlock | OK |
| `setREUSE` | `ws2_32.setsockopt(SO_REUSEADDR)` | no-op — set inside C layer | OK |
| `setLingerAbort` | `ws2_32.setsockopt(SO_LINGER)` | `pn.setLingerAbort` → `bsd_set_linger_abort` | OK |
| `disableNagle` | `ws2_32.setsockopt(IPPROTO.TCP, TCP.NODELAY)` | checks `uds_path == null`; then `address.any.family` for INET/INET6 | OK |
| `findFreeTcpPort` | `std.posix.socket` + `ws2_32.bind` + `ws2_32.getsockname` | `pn.findFreeTcpPort` | OK |
| `sendBuf/recvToBuf` | `ws2_32.send/recv` | `pn.sendBuf/recvToBuf` | OK |
| `close` | `setLingerAbort` + `ws2_32.closesocket` | `pn.closeSocket` + `deleteUDSPath` via `uds_path` | OK |
| **State** | `socket: ?ws2_32.SOCKET` + `address` + `base_handle` | `fd: pn.Fd` + `address: std.net.Address` + `uds_path: ?[UDS_PATH_SIZE]u8` | OK |

### A.4 `SocketCreator` — windows vs portable

| Function | windows native | portable/win | Status |
|---|---|---|---|
| `createTcpServer` | `resolveIp` → `createListenerSocket` (socket+bind+listen) | `resolveIp` → `pn_create_listen_socket_from_sockaddr` | OK |
| **`createTcpClient`** | `getAddressList` → `createConnectSocket` (socket only) | `getAddressList` → `createConnectSocket` (socket only, no connect) | OK |
| `createUdsServer` | `initUnix` → `createListenerSocket` | `pn.createListenSocketUnix` + stores path in `uds_path` | OK |
| `createUdsClient` | `initUnix` → `createConnectSocket` (socket only) | `pn.createClientSocket(AF_UNIX)` + stores path in `uds_path` | OK |
| **`createConnectSocket`** | `posix.socket` + `ioctlsocket(FIONBIO)` + `setLingerAbort`; stores `address` | `pn.createClientSocket` + `pn.setLingerAbort`; stores `address` | OK |
| `createListenerSocket` | `posix.socket` + `ioctlsocket(FIONBIO)` + `setLingerAbort` + `listen()` | `pn.createListenSocketFromSockaddr` (SO_REUSEADDR + SO_REUSEPORT + bind + listen) | OK |

### A.5 Cross-backend pattern summary

All native backends (linux, mac, windows) share the same two-step flow: `createConnectSocket` creates a non-blocking socket only (no connect), stores the resolved `address` in `Skt`; then `Skt.connect()` issues the real connect syscall and returns `false` while EINPROGRESS/WSAEWOULDBLOCK, allowing the poller to wait for WRITABLE before confirming.

The portable backend now implements this two-step flow for all three OS targets:
- **Linux** (`portable/linux/`): stores `std.net.Address`; `connect()` uses `pn.connectSocket`/`pn.connectSocketUnix`. UDS path read from `address.un.path`.
- **macOS** (`portable/mac/`): identical to linux — `std.net.Address.un` is available on macOS. `pn.AF_INET6 = 30` (corrected from 10).
- **Windows** (`portable/win/`): `std.net.Address.un = void` on Windows, so UDS path stored in a separate `uds_path: ?[UDS_PATH_SIZE]u8` field. TCP path uses `std.net.Address`. `pn.AF_INET6 = 23` (Windows value).

The legacy fallback (`Skt_legacy.zig`, `SocketCreator_legacy.zig`) remains for any other OS targets that may appear in the future.

---

## 19. Stage 6 Stability — Reactor `_destroy` Mailbox Drain Fix (2026-05-17)

**Problem.**
`_destroy` returned `AmpeError.ShutdownStarted` immediately when `shtdwnStrt` was true,
skipping `grp.destroy()`.
Messages left in `grp.msgs[0]` (createCG success-ack) and `grp.msgs[1]`
(buildStatusSignal pool_empty) were never returned to the pool or freed.
GPA reported 3 leaked addresses in ReleaseSafe mode on macOS aarch64.
All leak stacks pointed to `createCG` → `send_channels_cmd` → `Pool.get` → `Message.create`.

**Fix.**
When `shtdwnStrt` is true, `_destroy` now calls `grp.destroy()` on the calling thread
before returning `ShutdownStarted`.
`destroy()` calls `deinit()` → `cleanMboxes()` internally, draining both mailboxes.
File: `src/ampe/Reactor.zig`, function `_destroy`.

**Why safe.**
When `shtdwnStrt` is true, the reactor thread has already exited (joined via `waitFinish`).
No concurrent access to `grp` exists.
`pool.put()` inside `cleanMboxes` handles a closed pool by freeing the message immediately.
`grp.destroy()` calls `allocator.destroy(grp)` — no double-free risk.

**Verification.**
All 4 optimization modes passed on Linux x86_64.
Cross-compile targets (x86_64-macos, aarch64-macos, x86_64-windows-gnu) built clean.

---

## 20. Stage 6 Stability — IoSkt.tryRecv Completed-Message Drop Fix (2026-05-18)

**Problem.**
On Mac (kqueue/portable backend), `EV_EOF` on the READ filter maps to `act.recv = .on`
rather than `act.err = .on`. Linux epoll maps peer disconnect to `act.err`, so `tryRecv`
is never called on disconnect there. On Mac, `tryRecv` is called.

Inside `IoSkt.tryRecv`, each call to `recv()` that completes a message enqueues it in
the local `ret` queue. On the next `recv()` call, `getFromPool()` obtains a new buffer
and `recvToBuf()` returns 0 bytes (EOF) → `PeerDisconnected` error. The `else => return e`
branch propagated the error, silently dropping `ret`. The completed pool message inside
was never freed or returned to the pool. GPA reported `Pool.init:48` allocation leaked.

`_freeAll()` assertion still passed: `currMsgs` was decremented when the message left
the pool; the assertion only counts messages currently in the linked list.

**Fix.**
In `IoSkt.tryRecv()`, changed `else => return e` to:
```
else => { if (!ret.empty()) return ret; return e; }
```
Completed received messages are application data — they belong to the caller.
Returning them lets `processTriggeredChannels` deliver via `sendToCtx` normally.
When `ret` is empty, the error propagates as before.

**Why safe.**
After returning a non-empty `ret`, the channel is not immediately marked for delete.
On the next reactor loop, `triggers()` sees `mr.msg != null` → `recv = .on` → `tryRecv`
called again → `PeerDisconnected` with empty `ret` → error propagates → channel deleted.
No message data is lost. Cleanup is delayed by at most one reactor loop iteration.

File: `src/ampe/triggeredSkts.zig`, function `IoSkt.tryRecv`.

**Verification.**
All 4 optimization modes passed on Linux x86_64 (62/62 tests each).
Mac CI pending.

---

## Mac kqueue Behavior Analysis — Low-Level Operation Paths

### Key difference between backends

| Backend | Peer disconnect event | Mapped to |
|---|---|---|
| Linux epoll | `EPOLLHUP` / `EPOLLERR` | `act.err = .on` |
| Mac kqueue (portable) | `EV_EOF` on READ filter | `act.recv = .on` |
| Mac kqueue (portable) | `EV_EOF` on WRITE filter | `act.err = .on` |

Source: `src/ampe/portable/triggers.zig`.

### Operation path analysis

| Operation | Mac kqueue EV_EOF effect | Safe? | Notes |
|---|---|---|---|
| `tryRecv` | EV_EOF on READ → `act.recv = .on` → `tryRecv` called | ✅ Fixed (§20) | Was leaking completed messages in `ret` |
| `trySend` | EV_EOF on WRITE → `act.err = .on` → channel marked for delete | ✅ Safe | `trySend` not called on write-side EOF |
| `tryConnect` | Connect failure → `act.err = .on` via connect filter | ✅ Safe | EV_EOF not relevant here |
| `tryAccept` | EV_EOF on listener not expected in normal operation | ✅ Safe | Listener failure goes via `act.err` |
| Pool trigger | `act.pool` set internally, not by kqueue | ✅ Safe | Independent of EV_EOF |
| Notify trigger | `act.notify` set by notifier socket | ✅ Safe | Independent of EV_EOF |
| Error trigger | EV_EOF on WRITE → `act.err = .on` | ✅ Safe | Correct path for write-side failures |

---

## Proposed Fix: IoSkt.trySend drops already-sent messages on send error

**Problem.**
In `trySend()`, messages fully sent to the OS are enqueued in `ret`. If a subsequent
`send()` returns an error (broken pipe, network failure), `try` propagates it. The caller
catches the error and marks the channel for delete — but `ret` is dropped. Already-sent
pool messages are never returned to the pool. Potential GPA leak on any platform.

Not triggered by Mac kqueue EV_EOF (write-side EOF → `act.err`, `trySend` not called).

**Proposed fix.**
Add before the `while` loop in `IoSkt.trySend()`:
```zig
errdefer {
    var leak = ret.dequeue();
    while (leak != null) {
        ioskt.pool.put(leak.?);
        leak = ret.dequeue();
    }
}
```

**Why different from §20 recv fix.**
- Recv fix: completed messages are received application data → return to CALLER for delivery.
- Send fix: already-sent messages have data on the wire → return buffer to POOL.

**Status: implemented 2026-05-18.**

**Changes.**
- `src/ampe/triggeredSkts.zig` — `IoSkt.trySend`: removed `ret` queue; `ret.enqueue(wasSend.?)` → `ioskt.pool.put(wasSend.?)`; return type `AmpeError!MessageQueue` → `AmpeError!void`.
- `src/ampe/triggeredSkts.zig` — `TriggeredSkt.trySend`: return type updated to `!void`.
- `src/ampe/Reactor.zig` — `TriggeredChannel.trySend`: return type updated to `!void`.
- `src/ampe/Reactor.zig` — `processTriggeredChannels`: removed `wereSend` dequeue loop.

**Verification.**
All 4 optimization modes passed on Linux x86_64 (62/62 tests each).
Mac CI pending.

---

## 21. Remove std.net — Replace with pn.Addr

**Why.**
Zig 0.16 removes `std.net` (moved into `std.Io`). All `std.net.*` usage must be replaced
before the upgrade. The replacement uses types and helpers already in `posix_net/`.

**Scope.**
15 files contain `std.net` references. Two categories:
- `std.net.Address` as a storage type in Skt.zig (all backends).
- `std.net.getAddressList`, `std.net.Address.resolveIp`, `std.net.Address.initUnix`,
  `std.net.Address.initIp4` in SocketCreator.zig (all backends).
- `toStdAddress` conversion helper in `posix_net/socket.zig`.

**Status: implemented 2026-05-18.**

**Verification.**
Linux: 8 test runs (4 posix + 4 portable, all optimization modes, 62/62 each).
Cross-compile: x86_64-macos, aarch64-macos, x86_64-windows-gnu all pass.
`grep -r "std\.net" src/ posix_net/` returns 0 results.

---

### NON-REMOVABLE — Permanent Design Reference

This section documents the std.net removal design. It must not be deleted in future revisions.
Future contributors must be able to understand what was replaced and why without reading session history.

#### Complete usage table (before removal)

| File | Line(s) | Usage | Category |
|---|---|---|---|
| `posix_net/posix_net.zig` | 38 | `pub const toStdAddress = socket.toStdAddress` | re-export |
| `posix_net/socket.zig` | 129–136 | `toStdAddress(addr: *const Addr) std.net.Address` | conversion fn |
| `posix_net/socket.zig` | 139–143 | `addrPort` calls `ffi.bsd_addr_get_port` (C, portable-only) | C-dependent helper |
| `src/ampe/linux/Skt.zig` | 7, 48 | `address: std.net.Address` field + local var in `accept()` | type storage |
| `src/ampe/linux/SocketCreator.zig` | 37,54,88,105,117,137 | resolveIp, getAddressList, initUnix, fn signatures | all |
| `src/ampe/mac/Skt.zig` | 7, 48 | same as linux | type storage |
| `src/ampe/mac/SocketCreator.zig` | 37,54,88,105,117,137 | same as linux | all |
| `src/ampe/windows/Skt.zig` | 7, 66, 179 | field + local + initIp4 | type + addr build |
| `src/ampe/windows/SocketCreator.zig` | 37,54,88,105,117,137 | same as linux | all |
| `src/ampe/portable/linux/Skt.zig` | 9, 44 | field + `pn.toStdAddress` call in `accept()` | type + call |
| `src/ampe/portable/mac/Skt.zig` | 9, 44 | same as portable/linux | type + call |
| `src/ampe/portable/windows/Skt.zig` | 12 | field only (uds path in separate `uds_path` field) | type storage |
| `src/ampe/portable/linux/SocketCreator.zig` | 43,52,80,89,94,100 | same pattern | all |
| `src/ampe/portable/mac/SocketCreator.zig` | 43,52,80,89,94,100 | same pattern | all |
| `src/ampe/portable/windows/SocketCreator.zig` | 48,50,59,108,114 | resolveIp + getAddressList + initIp4 | all |

#### D1 — Address type: std.net.Address → pn.Addr

`std.net.Address` is an `extern union` where `.any` IS `posix.sockaddr`.
It is replaced with `pn.Addr` from `posix_net/types.zig`:

```zig
pub const Addr = extern struct {
    mem: [128]u8,    // sockaddr_storage — holds any address type
    len: u32,        // actual socklen_t for this address
    ip: ?[*]u8,      // C library internal — null when built manually
    ip_length: c_int,
    port: c_int,     // port in native byte order
};
```

`pn.Addr.mem` is 128-byte sockaddr_storage. All `std.net.Address` patterns map:

| Old pattern | Replacement |
|---|---|
| `&addr.any` → `*posix.sockaddr` | `@ptrCast(&addr.mem[0])` |
| `addr.getOsSockLen()` | `addr.len` |
| `addr.getPort()` | `pn.addrPort(&addr)` |
| `addr.any.family` | `pn.addrFamily(&addr)` |
| `addr.un.path` | `pn.addrUnixPath(&addr)` |

`ip` and `ip_length` are null/0 when addresses are built manually (not via getaddrinfo). Safe:
`addrFamily` and `addrUnixPath` read from `mem` directly and never touch `ip`/`ip_length`.

#### D2 — addrPort made pure-Zig

Old `addrPort` in `posix_net/socket.zig` called `ffi.bsd_addr_get_port` — a C function from
bun-usockets, only linked in portable builds. Unusable from native backends.

Replaced with pure-Zig implementation that reads bytes [2..4] of `addr.mem` (network byte
order port field, same position in both `sockaddr_in` and `sockaddr_in6`):

```zig
pub fn addrPort(addr: *const Addr) ?u16 {
    const fam = addrFamily(addr);
    if (fam != types.AF_INET and fam != types.AF_INET6) return null;
    const raw: *const u16 = @ptrCast(@alignCast(&addr.mem[2]));
    return std.mem.bigToNative(u16, raw.*);
}
```

Works in both native and portable builds. `bsd_addr_get_port` no longer called from Zig.

#### D3 — Windows uds_path field removed

`portable/windows/Skt.zig` had a separate `uds_path: ?[pn.UDS_PATH_SIZE]u8` field because
`std.net.Address.un` was void on Windows (before RS4 min version was enforced in build.zig).

With `pn.Addr` (128-byte `mem` = sockaddr_storage), UDS path stores in `mem` uniformly
on all platforms. The separate field was removed. Windows UDS handling is now identical
to Linux/macOS in the portable backend.

#### D4 — Sockaddr overlay structs added to posix_net/types.zig

`posix_net/types.zig` is the authoritative home for all network address types.
New extern structs added for manually constructing `pn.Addr` without `std.net`:

- `SockaddrIn` — IPv4 socket address (family, port, addr, zero padding)
- `SockaddrIn6` — IPv6 socket address (family, port, flowinfo, addr[16], scope_id)
- `SockaddrUn` — Unix domain socket address (family, path[UDS_PATH_SIZE])

Helper functions:
- `initAddrUnix(path: []const u8) error{NameTooLong}!Addr` — builds `pn.Addr` for a UDS path
- `initAddrIp4(ip: [4]u8, port: u16) Addr` — builds `pn.Addr` for an IPv4 address

These replace `std.net.Address.initUnix` and `std.net.Address.initIp4` respectively.

#### D5 — getaddrinfo exported from posix_net for native backends

`std.net.getAddressList` and `std.net.Address.resolveIp` wrap libc `getaddrinfo`.
`posix_net/ffi.zig` already declares `getaddrinfo`/`freeaddrinfo` as `extern "c"` (libc).
These are now exported from `posix_net/posix_net.zig` so all backends can use them.

Native backends import `posix_net` (already wired in `build.zig`) and call
`pn.getaddrinfo`/`pn.freeaddrinfo` to resolve hostnames — no extra C compilation needed.
Bun-usockets C symbols in `ffi.zig` cause no linker error in native builds because
Zig only reports undefined symbols that are actually called, not merely declared.

#### D6 — toStdAddress deleted

`posix_net/socket.zig:toStdAddress` converted `pn.Addr` → `std.net.Address` by memcpy.
Used only in `portable/linux/Skt.zig:44` and `portable/mac/Skt.zig:44` in `accept()`.
After the address field changed to `pn.Addr`, `accept()` returns `Skt{ .address = addr }`
directly — no conversion needed. `toStdAddress` deleted from `socket.zig` and `posix_net.zig`.

#### Part 2 — Address field elimination (future task)

Investigation: after connect/listen, the stored `address: pn.Addr` (128 bytes) is read for:
1. Port — `getPort()` (TCP only)
2. Family — `setREUSE()`, `disableNagle()`, `deleteUDSPath()`
3. UDS path — `deleteUDSPath()` (server side only)

Portable backends fetch port from kernel via `pn.localAddr()` — no stored port needed there.

A minimal alternative `{ family: u16, port: u16, uds_path: ?[UDS_PATH_SIZE]u8 }` is possible
but requires bind/getsockname/accept to use a temporary local `pn.Addr` for the syscall,
then extract family/port/path. Non-trivial refactor — deferred to a separate task.

---

## Proposal — Simm Test Isolation

### Problem

`reactor_tests.zig::simm test` runs 8 task functions concurrently via `RunTasks`:

```zig
const tests = &[_]*const fn () void{
    &try_ampe_just_create_destroy,
    &try_connect_disconnect,       // ← includes TCP + UDS scenarios
    &try_handle_reconnect_single_threaded,
    &try_handle_reconnect_multithreaded,
    // repeated once more
};
tofu.RunTasks(gpa, tests) catch unreachable;
```

Each `try_connect_disconnect` runs `handleStartOfUdsListeners`, `handleConnnectOfTcpClientServer`,
and `handleConnnectOfUdsClientServer` in sequence. With 8 concurrent tasks this creates heavy
overlapping I/O. Under CI scheduler conditions a `waitReceive` in the TCP path occasionally
dequeues a stray engine message (e.g. `uds_path_not_found` from a concurrent UDS scenario)
instead of the expected `channel_closed`, triggering the `assert` at `cookbook.zig:618`.

Observed: passes consistently locally (4/4 runs); failed once on Linux debug portable CI.

### Root Cause

`handleConnect` (`cookbook.zig`) uses `waitReceive(INFINITE_TIMEOUT)` to collect close
responses. It asserts exact status without logging the actual value. Any message delivered
out of expected order (or belonging to a different context) causes an unrecoverable panic
instead of a diagnosable test failure.

Two contributing factors:
1. `assert` (hard panic) instead of `try testing.expectEqual` (soft, diagnosable).
2. No per-scenario timeout — an unexpected message can silently consume an expected slot.

### Proposed Fix

**File:** `recipes/cookbook.zig`, function `handleConnect`, lines 597–619.

Replace bare `assert` calls on `closeListenerResp` and `closeClientResp` with
`testing.expectEqual` (or equivalent error-returning checks):

```zig
// Before
assert(closeListenerResp.?.*.bhdr.status == status.status_to_raw(AmpeStatus.channel_closed));
// ...
assert(closeClientResp.?.*.bhdr.status == status.status_to_raw(AmpeStatus.channel_closed));

// After
const expected: u8 = status.status_to_raw(AmpeStatus.channel_closed);
if (closeListenerResp.?.*.bhdr.status != expected) {
    log.err("closeListenerResp: expected channel_closed, got {d}", .{closeListenerResp.?.*.bhdr.status});
    return error.UnexpectedStatus;
}
---

## 22. Wepoll — Transition to Managed Dependency

### Why
To simplify dependency management and follow the same pattern as `usockets`, the `wepoll` submodule is replaced by a `build.zig.zon` dependency. This eliminates manual submodule management and ensures consistent fetching via the Zig package manager.

### Key Changes
- **`build.zig.zon`**: Added `wepoll` to the `.dependencies` section.
- **`build.zig`**:
    - Retrieve the `wepoll` dependency when targeting Windows.
    - Update all C source and include paths to use `wepoll.path("")`.
    - Ensure both `libMod` and `lib_unit_tests` are updated.
- **Submodule Removal**: The physical directory `src/ampe/windows/wepoll/` is removed from the repository.

### Verification
- **Linux host**: Run 4-mode verification (`zbta_linux.sh`) to ensure no regressions.
- **Windows cross-compile**:
    - `zig build -Dtarget=x86_64-windows-gnu` (posix backend).
    - `zig build -Dtarget=x86_64-windows-gnu -Dnetwork=portable` (portable backend).

### Non-Removable Design Reference
This transition centralizes all C-layer dependencies in `build.zig.zon`. Future updates to `wepoll` only require updating the commit hash in `build.zig.zon`.

---

## 23. Source Partitioning — Stage 9

### Why

The current source tree mixes two distinct network backends with the reactor infrastructure,
and leaves the `posix_net/` module floating at the repo root. Problems a first-time visitor sees:

- `posix_net/` at repo root with no indication it belongs to the portable backend.
- `src/ampe/linux/`, `mac/`, `windows/` and `portable/` sit beside reactor files with no grouping.
- The two backends are not identifiable as such from the directory listing.

Stage 9 introduces `src/platform/` to group both backends clearly. No functional change.
Only file moves and the path updates that follow.

### Commit

`Partition src: introduce platform/ backends`

### Target Layout

```
src/
├── tofu.zig
├── ampe.zig
├── address.zig
├── message.zig
├── status.zig
│
├── platform/
│   ├── stdposix/              ← was src/ampe/linux|mac|windows/
│   │   ├── linux/
│   │   │   ├── epoll_backend.zig
│   │   │   ├── Skt.zig
│   │   │   ├── SocketCreator.zig
│   │   │   └── triggers.zig
│   │   ├── mac/
│   │   │   ├── kqueue_backend.zig
│   │   │   ├── Skt.zig
│   │   │   ├── SocketCreator.zig
│   │   │   └── triggers.zig
│   │   └── windows/
│   │       ├── wepoll_backend.zig
│   │       ├── Skt.zig
│   │       ├── SocketCreator.zig
│   │       └── triggers.zig
│   │
│   └── posixnet/              ← was src/ampe/portable/ + posix_net/ (repo root)
│       ├── posixnet_backend.zig   ← was portable/posix_net_backend.zig (renamed)
│       ├── triggers.zig
│       ├── linux/
│       │   ├── Skt.zig
│       │   └── SocketCreator.zig
│       ├── mac/
│       │   ├── Skt.zig
│       │   └── SocketCreator.zig
│       ├── windows/
│       │   ├── Skt.zig
│       │   └── SocketCreator.zig
│       └── wrapper/           ← was posix_net/ at repo root
│           ├── posix_net.zig  ← module root; import alias "posix_net" unchanged
│           ├── ffi.zig
│           ├── poll.zig
│           ├── socket.zig
│           ├── creator.zig
│           ├── types.zig
│           └── adapters/
│               ├── pn_utils.c
│               ├── us_epoll_win.c
│               ├── win_compat.h
│               └── sys/
│                   ├── epoll.h
│                   ├── eventfd.h
│                   └── timerfd.h
│
└── ampe/                      (unchanged — reactor infrastructure)
    ├── core.zig
    ├── common.zig
    ├── internal.zig
    ├── poller.zig
    ├── Notifier.zig
    ├── Reactor.zig
    ├── triggeredSkts.zig
    ├── channels.zig
    ├── Pool.zig
    ├── MchnGroup.zig
    ├── Appendable.zig
    ├── IntrusiveQueue.zig
    ├── vtables.zig
    └── testHelpers.zig
```

### Naming conflict resolution

`src/ampe/core.zig` (PollerCore generic) and `posixnet/core/` (C wrapper module folder)
would both carry the name "core". Decision: name the C wrapper folder `wrapper/` instead.

- `ampe/core.zig` is established throughout session history and docs as "PollerCore".
  Renaming it ripples into all `@import("core")` call sites in `src/ampe/`.
- Renaming the folder only affects path strings in `build.zig`.
- `wrapper/` describes the role: wraps bun-usockets C for Zig consumers.

### File moves

#### stdposix backend

| From | To |
| :--- | :- |
| `src/ampe/linux/` | `src/platform/stdposix/linux/` |
| `src/ampe/mac/` | `src/platform/stdposix/mac/` |
| `src/ampe/windows/` | `src/platform/stdposix/windows/` |

All 4 files per OS move unchanged.

#### posixnet backend

| From | To |
| :--- | :- |
| `src/ampe/portable/posix_net_backend.zig` | `src/platform/posixnet/posixnet_backend.zig` |
| `src/ampe/portable/triggers.zig` | `src/platform/posixnet/triggers.zig` |
| `src/ampe/portable/linux/` | `src/platform/posixnet/linux/` |
| `src/ampe/portable/mac/` | `src/platform/posixnet/mac/` |
| `src/ampe/portable/windows/` | `src/platform/posixnet/windows/` |

`posix_net_backend.zig` is renamed to `posixnet_backend.zig` (matches folder name convention).

#### posixnet C wrapper module

| From | To |
| :--- | :- |
| `posix_net/` (repo root) | `src/platform/posixnet/wrapper/` |

All 6 Zig files and the entire `adapters/` subtree move unchanged.

### Network option rename

The `-Dnetwork` enum values are renamed to match the new folder names:

| Old flag | New flag | Folder |
| :------- | :------- | :----- |
| `-Dnetwork=posix` | `-Dnetwork=stdposix` | `src/platform/stdposix/` |
| `-Dnetwork=portable` | `-Dnetwork=posixnet` | `src/platform/posixnet/` |

### Source changes (import path updates)

#### `src/ampe/internal.zig`

All `@import` calls to OS backend files change relative paths:

- `@import("linux/Skt.zig")` → `@import("../platform/stdposix/linux/Skt.zig")`
- `@import("mac/Skt.zig")` → `@import("../platform/stdposix/mac/Skt.zig")`
- `@import("windows/Skt.zig")` → `@import("../platform/stdposix/windows/Skt.zig")`
- `@import("portable/posix_net_backend.zig")` → `@import("../platform/posixnet/posixnet_backend.zig")`
- Same pattern for `SocketCreator.zig` imports.
- All `build_options.network == .portable` comparisons → `.posixnet`.

#### `src/ampe/poller.zig`

- `linux/epoll_backend.zig` → `../platform/stdposix/linux/epoll_backend.zig`
- `mac/kqueue_backend.zig` → `../platform/stdposix/mac/kqueue_backend.zig`
- `windows/wepoll_backend.zig` → `../platform/stdposix/windows/wepoll_backend.zig`
- `portable/posix_net_backend.zig` → `../platform/posixnet/posixnet_backend.zig`
- All `build_options.network == .portable` comparisons → `.posixnet`.

#### `src/ampe/common.zig` and `src/ampe/testHelpers.zig`

Both contain `build_options.network == .portable` comparisons → rename to `.posixnet`.

#### `src/platform/posixnet/posixnet_backend.zig` (moved file — internal imports)

This file uses relative paths into `src/ampe/` that change depth after the move:

| Import | Old resolution | New import |
| :----- | :------------- | :--------- |
| `@import("../core.zig")` | `src/ampe/core.zig` | `@import("../../ampe/core.zig")` |
| `@import("../internal.zig")` | `src/ampe/internal.zig` | `@import("../../ampe/internal.zig")` |
| `@import("../common.zig")` | `src/ampe/common.zig` | `@import("../../ampe/common.zig")` |
| `@import("../../tofu.zig")` | `src/tofu.zig` | unchanged (same depth) |

#### `src/platform/posixnet/triggers.zig` (moved file — internal imports)

| Import | Old resolution | New import |
| :----- | :------------- | :--------- |
| `@import("../internal.zig")` | `src/ampe/internal.zig` | `@import("../../ampe/internal.zig")` |

#### OS subfolder files (`posixnet/linux|mac|windows/Skt.zig`, `SocketCreator.zig`)

No changes. Old location `src/ampe/portable/linux/` and new location `src/platform/posixnet/linux/`
are both 4 levels deep — `@import("../../../tofu.zig")` resolves to `src/tofu.zig` in both cases.
All other imports use the named module `"posix_net"` or sibling `"Skt.zig"` — both unchanged.

#### Native backend files (`src/ampe/linux|mac|windows/` — 12 files)

These files move from depth 3 (`src/ampe/linux/`) to depth 4 (`src/platform/stdposix/linux/`).
Four categories of relative imports break.

**`@import("../../tofu.zig")` → `@import("../../../tofu.zig")`**

| File |
| :--- |
| `linux/Skt.zig` |
| `linux/SocketCreator.zig` |
| `linux/epoll_backend.zig` |
| `mac/Skt.zig` |
| `mac/SocketCreator.zig` |
| `mac/kqueue_backend.zig` |
| `windows/Skt.zig` |
| `windows/SocketCreator.zig` |
| `windows/wepoll_backend.zig` |

**`@import("../internal.zig")` → `@import("../../ampe/internal.zig")`**

| File |
| :--- |
| `linux/Skt.zig` |
| `linux/SocketCreator.zig` |
| `linux/epoll_backend.zig` |
| `linux/triggers.zig` |
| `mac/Skt.zig` |
| `mac/SocketCreator.zig` |
| `mac/kqueue_backend.zig` |
| `mac/triggers.zig` |
| `windows/SocketCreator.zig` |
| `windows/triggers.zig` |
| `windows/wepoll_backend.zig` |

**`@import("../common.zig")` → `@import("../../ampe/common.zig")`**

| File |
| :--- |
| `linux/epoll_backend.zig` |
| `linux/triggers.zig` |
| `mac/kqueue_backend.zig` |
| `mac/triggers.zig` |
| `windows/triggers.zig` |
| `windows/wepoll_backend.zig` |

**`@import("../core.zig")` → `@import("../../ampe/core.zig")`**

| File |
| :--- |
| `linux/epoll_backend.zig` |
| `mac/kqueue_backend.zig` |
| `windows/wepoll_backend.zig` |

Note: `windows/Skt.zig` does not import `internal.zig` — not in the second table.

#### `build.zig`

Network enum rename (line 33):
```zig
// Before
const NetworkBackend = enum { posix, portable };
// After
const NetworkBackend = enum { stdposix, posixnet };
```

`test_gate_options` flag (line 168) — rename for consistency:
```zig
// Before
test_gate_options.addOption(bool, "portable", network == .portable);
// After
test_gate_options.addOption(bool, "posixnet", network == .posixnet);
```

Path strings (7 occurrences — 4 unique, each adapters string appears twice):

| Line(s) | Before | After |
| :------ | :----- | :---- |
| 52 | `"posix_net/posix_net.zig"` | `"src/platform/posixnet/wrapper/posix_net.zig"` |
| 109, 210 | `"posix_net/adapters/us_epoll_win.c"` | `"src/platform/posixnet/wrapper/adapters/us_epoll_win.c"` |
| 116, 217 | `"posix_net/adapters/pn_utils.c"` | `"src/platform/posixnet/wrapper/adapters/pn_utils.c"` |
| 118, 219 | `"posix_net/adapters"` | `"src/platform/posixnet/wrapper/adapters"` |

The named module alias `"posix_net"` in `b.addModule("posix_net", ...)` stays unchanged.
All `@import("posix_net")` call sites require no changes.

#### CI workflow files

| File | Line | Before | After |
| :--- | :--- | :----- | :---- |
| `linux.yml` | 13 | `network: [posix, portable]` | `network: [stdposix, posixnet]` |
| `windows.yml` | 16 | `network: [posix, portable]` | `network: [stdposix, posixnet]` |
| `mac.yml` | 27 | `-Dnetwork=posix` | `-Dnetwork=stdposix` |
| `mac.yml` | 28 | `-Dnetwork=portable` | `-Dnetwork=posixnet` |

#### `.vscode/tasks.json`

| Line | Before | After |
| :--- | :----- | :---- |
| 61 | `-Dnetwork=portable` | `-Dnetwork=posixnet` |
| 103 | `-Dnetwork=portable` | `-Dnetwork=posixnet` |

#### `tests/tofu_tests.zig`

`test_gate_options.portable` → `test_gate_options.posixnet` (matches the renamed flag).

### What does not change

- All files in `src/ampe/` except the enum comparisons noted above.
- All `@import("posix_net")` call sites everywhere — the module alias is unchanged.
- `recipes/`, `build.zig.zon` — unchanged.

### Implementation sequence

1. Create `src/platform/stdposix/` and move the 3 OS backend folders.
2. Create `src/platform/posixnet/` and move the 5 portable backend items. Rename `posix_net_backend.zig` → `posixnet_backend.zig`.
3. Move `posix_net/` (root) → `src/platform/posixnet/wrapper/`.
4. Update `build.zig`: enum rename, path strings, `test_gate_options` flag name.
5. Update `src/ampe/internal.zig`: backend import paths + `.portable` → `.posixnet`.
6. Update `src/ampe/poller.zig`: backend import paths + `.portable` → `.posixnet`.
7. Update `src/ampe/common.zig` and `src/ampe/testHelpers.zig`: `.portable` → `.posixnet`.
8. Update `src/platform/posixnet/posixnet_backend.zig`: 3 relative imports into `src/ampe/`.
9. Update `src/platform/posixnet/triggers.zig`: 1 relative import into `src/ampe/`.
10. Update all 12 native backend files in `src/platform/stdposix/linux|mac|windows/`: apply all 4 import categories from the table above.
11. Update CI files: `linux.yml`, `windows.yml`, `mac.yml`.
12. Update `.vscode/tasks.json`.
13. Update `tests/tofu_tests.zig`: `test_gate_options.portable` → `.posixnet`.
14. `zig build -Dnetwork=stdposix` and `zig build -Dnetwork=posixnet` — compile check, catches any missed rename or broken import.
15. Full 4-mode sandwich on Linux (both backends).
16. Cross-compile: `x86_64-windows-gnu`, `x86_64-macos`, `aarch64-macos`.
17. Update `design/AGENT_STATE.md`.

### Design decisions (Q&A)

**Q: Why does `posix_net.zig` keep the underscore when the folder is `wrapper/` (no underscore)?**

Folder-level naming follows a no-underscore convention (`posixnet`, `stdposix`, `wrapper`).
File-level naming follows its own convention. `posix_net.zig` keeps the underscore because
changing it would also require changing the `b.addModule("posix_net", ...)` alias — and every
`@import("posix_net")` call site throughout the codebase. The rename gain is zero; the churn
is large. Folder and file naming levels are independent.

**Q: Why is `wrapper/` nested inside `src/platform/posixnet/` rather than at `src/wrapper/`?**

The C wrapper (`posix_net.zig` + adapters) is the implementation of the posixnet backend only.
It is not shared between backends. Placing it at `src/wrapper/` would imply it is shared
infrastructure — architecturally misleading. Keeping it inside `src/platform/posixnet/wrapper/`
correctly communicates ownership.

**Q: Are backward-compatibility aliases needed for the `-Dnetwork=` flag rename?**

No. This is an internal repo. No external consumers depend on the build flag. CI files are
updated as part of Stage 9. There is no deprecation period.

**Q: Does `recipes/` need any changes?**

No. `grep` over `recipes/` finds no `.portable` or `.posix` comparisons. The recipes module
uses only the public `tofu` named module import — unaffected by the reorganization.

**Q: Which file uses `test_gate_options`?**

Only `tests/tofu_tests.zig` — verified by `grep`. Two references:
- Line 40: `test_gate_options.portable` → `test_gate_options.posixnet`
- Line 67: `const test_gate_options = @import("test_gate_options");` — unchanged (import alias)

### Verification

```sh
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSmall

zig build test -Dnetwork=posixnet -Doptimize=Debug
zig build test -Dnetwork=posixnet -Doptimize=ReleaseSafe
zig build test -Dnetwork=posixnet -Doptimize=ReleaseFast
zig build test -Dnetwork=posixnet -Doptimize=ReleaseSmall

zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=x86_64-windows-gnu -Dnetwork=posixnet
zig build -Dtarget=x86_64-macos       -Dnetwork=posixnet
zig build -Dtarget=aarch64-macos      -Dnetwork=posixnet
```

Zero functional change. All test counts must match pre-refactor numbers.

---

## 24. Doc Site — Stage 10a: Structural Alignment

### Goal

Make the existing docs accurate after Stage 9. No new content. Stale references only.

### What is stale

#### `docs_site/docs/mds/platform-support.md`

The "Comptime Backend Selection" code snippet shows illustrative paths
(`poller/wepoll_backend.zig`, `poller/epoll_backend.zig`, etc.) that predate Stage 9.
Update the snippet to reflect the real post-Stage-9 paths under `src/platform/stdposix/`
and `src/platform/posixnet/`.

The page describes only the three OS-native backends (epoll, kqueue, wepoll). It has
no mention of the posixnet/bun-usockets backend option. Add a short callout — one paragraph
or admonition — noting that a second backend exists and is selected with `-Dnetwork=posixnet`.
Full explanation deferred to Stage 10b.

#### `docs_site/docs/mds/overview.md`

States: "use only the _standard library_". This was true before posixnet. Add a qualifier:
the posixnet backend uses the bun-usockets C library; the default stdposix backend uses
only the standard library.

#### `docs_site/docs/mds/poller-design.md`

Lines ~151–153: "Linux (epoll): `std.posix.fd_t`" and "BSD/macOS (kqueue): `std.posix.fd_t`".
These are accurate for stdposix but do not apply to posixnet. Add a note that these types
are stdposix-specific; posixnet uses the bun-usockets handle abstraction.

#### Autodoc regeneration

`docs_site/docs/apidocs/` and `docs_site/docs/recipes/` contain pre-generated Zig autodoc
output from before Stage 9. The source paths embedded in those artifacts are stale.
Regenerate by running `zig build docs` after Stage 9. This is a build artifact update,
not a hand-edit.

### Local helper scripts

No scripts for doc generation currently exist. Add two at the repo root, following the
`zbta_linux.sh` / `zbta_win.cmd` naming convention.

**`docs_zig.sh`** (Linux/macOS) — regenerates Zig autodoc only:
```sh
#!/bin/bash
# Regenerate Zig autodoc into docs_site/docs/apidocs/ and docs_site/docs/recipes/
# Usage: ./docs_zig.sh
date
zig build docs
date
```

**`docs_zig.cmd`** (Windows) — same, Windows cmd syntax:
```bat
@echo off
REM Regenerate Zig autodoc into docs_site/docs/apidocs/ and docs_site/docs/recipes/
REM Usage: docs_zig.cmd
echo %date% %time%
zig build docs
echo %date% %time%
```

**`docs_site.sh`** (Linux/macOS) — full pipeline: Zig autodoc + MkDocs site build:
```sh
#!/bin/bash
# Full doc site build: Zig autodoc + MkDocs
# Usage: ./docs_site.sh
# Requires: mkdocs-material and plugins installed (pip install mkdocs-material
#           mkdocs-awesome-pages-plugin mkdocs-minify-plugin mkdocs-open-in-new-tab)
date
zig build docs
cd docs_site && mkdocs build
date
```

Windows equivalent for the full pipeline is not provided — mkdocs is a Python tool and
runs identically on Windows; use `docs_zig.cmd` then run `mkdocs build` from `docs_site\`
manually, or add `docs_site.cmd` if needed.

### Files to change

| File | Change |
| :--- | :----- |
| `docs_site/docs/mds/platform-support.md` | Update backend snippet paths; add posixnet callout |
| `docs_site/docs/mds/overview.md` | Qualify "standard library only" claim |
| `docs_site/docs/mds/poller-design.md` | Note stdposix-specific handle types |
| `docs_site/docs/apidocs/` | Regenerate via `zig build docs` |
| `docs_site/docs/recipes/` | Regenerate via `zig build docs` |
| `docs_zig.sh` | New script — Zig autodoc only (Linux/macOS) |
| `docs_zig.cmd` | New script — Zig autodoc only (Windows) |
| `docs_site.sh` | New script — full pipeline (Linux/macOS) |

### Verification

```sh
# Step 1: regenerate Zig autodoc
./docs_zig.sh

# Step 2: build full site
./docs_site.sh

# Step 3: check locally
cd docs && python3 -m http.server 8011
# open http://127.0.0.1:8011 — check platform-support, overview, poller-design pages
```

---

## 25. Doc Site — Stage 10b: Backend Content

### Goal

Add content explaining the two network backends and the Zig 0.16 roadmap.
Depends on Stage 10a being complete (terminology already updated).

### New content

#### New section in `platform-support.md` — "Two Network Backends"

Explain both options:

- **`stdposix`** (default) — uses Zig stdlib + POSIX syscalls. Per-OS implementation:
  Linux/epoll, macOS/kqueue, Windows/wepoll. Select with `-Dnetwork=stdposix` or omit the flag.

- **`posixnet`** — uses the bun-usockets C wrapper. One cross-platform implementation.
  Select with `-Dnetwork=posixnet`.

When to prefer posixnet:
- Environments where Zig stdlib socket API is evolving (Zig 0.16 transition — see below).
- When targeting Windows with a single backend that matches Linux behavior closely.
- When a C FFI layer is acceptable in exchange for stdlib stability.

#### Zig 0.16 roadmap note (same section)

- In Zig 0.16, `std.net.Address` moves into `std.Io`. The stdposix backend depends on
  Zig stdlib socket and address types.
- When Zig 0.16 lands, the stdposix backend will require updates or will be gated/removed.
- The posixnet backend uses bun-usockets types, not `std.net`. It is the forward-compatible choice.
- Users on Zig 0.16+ should use `-Dnetwork=posixnet`.

#### Update `installation.md`

Add the two `-Dnetwork=` options after the existing install snippet:

```sh
zig build                        # stdposix backend (default)
zig build -Dnetwork=posixnet     # posixnet backend (bun-usockets)
```

Short explanation of when each is appropriate.

### Files to change

| File | Change |
| :--- | :----- |
| `docs_site/docs/mds/platform-support.md` | New "Two Network Backends" section with Zig 0.16 note |
| `docs_site/docs/mds/installation.md` | Add `-Dnetwork=` option description |
| `docs_site/mkdocs.yml` | Only if a new page is added; not expected for this stage |

### Verification

```sh
cd docs_site
mkdocs build
cd ../docs
python3 -m http.server 8011
# check platform-support (new section) and installation pages
```

---

## 26. Doc Site — Stage 10c: CI Deployment

### Goal

Automate doc deployment via GitHub Actions. Remove the manual build-and-push step.

### Current manual process

1. `zig build docs` — writes autodoc to `docs_site/docs/apidocs/` and `docs_site/docs/recipes/`.
2. `mkdocs build` from `docs_site/` — writes rendered site to `docs/` (via `site_dir: ../docs` in `mkdocs.yml`).
3. Commit and push `docs/`. GitHub Pages serves from `docs/` on `main`.

### Proposed workflow

New file: `.github/workflows/docs.yml`

Trigger: push to `main` with changes in `docs_site/`, `src/`, `recipes/`, or `build.zig`.
Routine CI pushes (test runs) that touch only test or non-doc files do not trigger doc builds.

Steps:
1. Checkout repo.
2. Install Zig (same version as build CI).
3. Run `zig build docs` — regenerates autodoc artifacts.
4. Install Python + mkdocs-material + required plugins.
5. Run `mkdocs build` from `docs_site/`.
6. Commit changed `docs/` and push to `main`.

The commit-back approach matches the current manual flow and requires no change to the
GitHub Pages source setting (already configured to serve `docs/` on `main`).

### Deployment decision

GitHub Pages is configured to serve from `/docs` on `main`. This matches the current
manual flow. CI will commit the generated `docs/` back to `main` — no settings change,
no `.gitignore` change. `docs/` stays in git as it is now.

### Files to change

| File | Change |
| :--- | :----- |
| `.github/workflows/docs.yml` | New workflow |

### Verification

Push a trivial change to `docs_site/docs/mds/overview.md`.
Confirm the Actions run completes and the live site at `https://g41797.github.io/tofu/` reflects the change.

