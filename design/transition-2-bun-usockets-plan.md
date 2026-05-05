# Transition to bun-usockets — Final Implementation Plan

**Status:** Authoritative  
**Date:** 2026-05-05  
**Based on:** source-level analysis of `vendor/bun-usockets/src/` and `src/ampe/linux/`

---

## 1. Architecture: What We Are Implementing

Tofu's `ampe` layer is a single-threaded reactor. The backend interface is defined by `PollerCore` (comptime generic). The backend must implement exactly six functions:

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

---

## 2. Files to Implement

Four files in `src/ampe/usockets/`, unified across all platforms:

| File | Current state | Replaces |
| :--- | :--- | :--- |
| `Skt.zig` | stub | `linux/Skt.zig`, `mac/Skt.zig`, `windows/Skt.zig` |
| `SocketCreator.zig` | stub | `linux/SocketCreator.zig`, etc. |
| `triggers.zig` | partial | `linux/triggers.zig`, etc. |
| `usockets_backend.zig` | stub | `epoll_backend.zig` / `kqueue_backend.zig` / `wepoll_backend.zig` |

**Notifier:** `src/ampe/Notifier.zig` is platform-independent. `internal.zig` already imports it unconditionally. No usockets-specific file is needed or exists.

New files (Windows only, Stage 4):
- `src/ampe/windows/adapters/sys/epoll.h`
- `src/ampe/windows/adapters/sys/timerfd.h`
- `src/ampe/windows/adapters/sys/eventfd.h`

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
__attribute__((weak)) void us_internal_dispatch_ready_poll(struct us_poll_t *p, int error, int eof, int events) {
```

With a weak definition in C, the linker uses our strong Zig-exported symbol. This is a minimal, targeted vendor patch — one annotation on one line.

**Alternative if patching is unacceptable:** add `-Wl,--allow-multiple-definition` to the link flags and rely on link order (Zig objects appear before C objects in LLD). This is fragile and not recommended.

### 4.4 Our dispatch implementation

```zig
// Module-level, safe because wait() is single-threaded
var g_wait_state: ?*WaitState = null;

const WaitState = struct {
    map: *SeqnTrcMap,
    total_act: Triggers,
};

export fn us_internal_dispatch_ready_poll(
    poll: *anyopaque,
    err: c_int,
    eof: c_int,
    events: c_int,
) callconv(.C) void {
    const ws = g_wait_state orelse return;
    // ext memory holds *TriggeredChannel (stored during register/modify)
    const tc_ptr = @as(**TriggeredChannel, @ptrCast(@alignCast(us_poll_ext(poll))));
    const tc = tc_ptr.*;
    const act = triggers_mod.fromEvents(events, err, eof, tc.exp);
    tc.act = tc.act.lor(act);
    ws.total_act = ws.total_act.lor(act);
}
```

### 4.5 ext memory layout

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
        // Windows: shim epoll/timerfd/eventfd (see §9 for contents)
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

### 7.1 C FFI declarations

```zig
extern fn us_create_loop(
    hint: ?*anyopaque,
    wakeup_cb: ?*anyopaque,
    pre_cb: ?*anyopaque,
    post_cb: ?*anyopaque,
    ext_size: c_uint,
) callconv(.C) ?*anyopaque;
extern fn us_loop_free(loop: *anyopaque) callconv(.C) void;
extern fn us_create_poll(loop: *anyopaque, fallthrough: c_int, ext_size: c_uint) callconv(.C) ?*anyopaque;
extern fn us_poll_free(p: *anyopaque, loop: *anyopaque) callconv(.C) void;
extern fn us_poll_init(p: *anyopaque, fd: c_int, poll_type: c_int) callconv(.C) void;
extern fn us_poll_start(p: *anyopaque, loop: *anyopaque, events: c_int) callconv(.C) void;
extern fn us_poll_change(p: *anyopaque, loop: *anyopaque, events: c_int) callconv(.C) void;
extern fn us_poll_stop(p: *anyopaque, loop: *anyopaque) callconv(.C) void;
extern fn us_poll_ext(p: *anyopaque) callconv(.C) *anyopaque;
extern fn us_loop_run_bun_tick(loop: *anyopaque, timeout: ?*const std.posix.timespec) callconv(.C) void;

const POLL_TYPE_SOCKET: c_int = 0;
```

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
    const loop = us_create_loop(null, null, null, null, 0)
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
        us_poll_stop(poll, self.loop);
        us_poll_free(poll, self.loop);
    }
    self.polls.deinit();
    us_loop_free(self.loop);
}
```

### 7.4 register / modify / unregister

```zig
pub fn register(self: *UsocketsBackend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void {
    _ = seq; // SeqN is stored in SeqnTrcMap; we store *TriggeredChannel directly via ext
    // Caller ensures tc is in seqn_trc_map before calling wait()
    const poll = us_create_poll(self.loop, 0, @sizeOf(*TriggeredChannel))
        orelse return AmpeError.AllocationFailed;
    us_poll_init(poll, @intCast(fd), POLL_TYPE_SOCKET);
    // tc pointer is written by the poller core before the first wait();
    // store null for now; modify() sets the actual pointer when needed
    us_poll_start(poll, self.loop, triggers_mod.toEvents(exp));
    try self.polls.put(fd, poll);
}

pub fn modify(self: *UsocketsBackend, fd: FdType, seq: SeqN, exp: Triggers) AmpeError!void {
    _ = seq;
    const poll = self.polls.get(fd) orelse return AmpeError.CommunicationFailed;
    us_poll_change(poll, self.loop, triggers_mod.toEvents(exp));
}

pub fn unregister(self: *UsocketsBackend, fd: FdType) void {
    if (self.polls.fetchRemove(fd)) |entry| {
        const poll = entry.value;
        us_poll_stop(poll, self.loop);
        us_poll_free(poll, self.loop);
    }
}
```

**Note on SeqN / TriggeredChannel wiring:** The poller core sets `tc` in ext memory before calling `wait()`. The exact hook depends on how `PollerCore` exposes this — confirm against `src/ampe/poller.zig` during implementation.

### 7.5 wait

```zig
pub fn wait(self: *UsocketsBackend, timeout: i32, seqn_trc_map: *SeqnTrcMap) AmpeError!Triggers {
    // Wire ext pointers before polling
    var it = seqn_trc_map.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        if (self.polls.get(tc.fd)) |poll| {
            const ptr = @as(**TriggeredChannel, @ptrCast(@alignCast(us_poll_ext(poll))));
            ptr.* = tc;
        }
    }

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

---

## 8. `usockets/Skt.zig`

Replaces `std.posix.*` with `bsd_*` wrappers. Platform differences (error codes, socket handles) are isolated to `mapErrno()`.

```zig
extern fn bsd_create_listen_socket(host: [*:0]const u8, port: c_int, options: c_int, err: *c_int) c_int;
extern fn bsd_create_listen_socket_unix(path: [*]const u8, pathlen: usize, options: c_int, err: *c_int) c_int;
extern fn bsd_create_connect_socket(addr: *const anyopaque, options: c_int) c_int;
extern fn bsd_create_connect_socket_unix(path: [*]const u8, pathlen: usize, options: c_int) c_int;
extern fn bsd_accept_socket(fd: c_int, addr: *anyopaque) c_int;
extern fn bsd_recv(fd: c_int, buf: [*]u8, length: c_int, flags: c_int) isize;
extern fn bsd_send(fd: c_int, buf: [*]const u8, length: c_int) isize;
extern fn bsd_close_socket(fd: c_int) void;
extern fn bsd_shutdown_socket(fd: c_int) void;
extern fn bsd_socket_nodelay(fd: c_int, enabled: c_int) void;
extern fn bsd_socket_keepalive(fd: c_int, on: c_int, delay: c_uint) c_int;
extern fn us_socket_local_address(s: *const anyopaque, buf: [*]u8, length: *c_int) void;
```

**Method mapping:**

| Skt method | bsd_* call |
| :--------- | :--------- |
| `listen(host, port)` | `bsd_create_listen_socket(host, port, 0, &err)` |
| `accept(server_fd)` | `bsd_accept_socket(server_fd, &addr)` |
| `connect(addr)` | `bsd_create_connect_socket(&sockaddr_storage, 0)` — addr pre-resolved |
| `sendBuf(buf)` | `bsd_send(fd, buf.ptr, @intCast(buf.len))` |
| `recvToBuf(buf)` | `bsd_recv(fd, buf.ptr, @intCast(buf.len), 0)` |
| `close()` | `bsd_close_socket(fd)` |
| `disableNagle()` | `bsd_socket_nodelay(fd, 1)` |
| `getPort()` | `us_socket_local_address` + parse bytes |

**Error mapping (comptime branch on OS):**

```zig
fn mapErrno() AmpeError {
    if (comptime builtin.os.tag == .windows) {
        return switch (std.os.windows.ws2_32.WSAGetLastError()) {
            .WSAEWOULDBLOCK => AmpeError.WouldBlock,
            else => AmpeError.CommunicationFailed,
        };
    }
    return switch (std.posix.errno(-1)) {
        .AGAIN, .WOULDBLOCK => AmpeError.WouldBlock,
        else => AmpeError.CommunicationFailed,
    };
}
```

---

## 9. `usockets/SocketCreator.zig`

### 9.1 Listen side

`bsd_create_listen_socket(host, port, 0, &err)` handles DNS internally — no Zig-side resolution needed.

`bsd_create_listen_socket_unix(path, pathlen, 0, &err)` — for UDS. On Linux, prepend `\x00` for abstract namespace (comptime branch, same pattern as `Notifier.zig`).

### 9.2 Connect side — hostname resolution

`bsd_create_connect_socket` takes a **pre-resolved `sockaddr_storage*`**. Resolution uses `getaddrinfo` via C extern (libc is already linked by `artifact.link_libc = true`):

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
        const fd = bsd_create_connect_socket(
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

No `usockets/Notifier.zig` exists or is needed. Notifier uses `Skt` + `SocketCreator` internally — once those are implemented, Notifier works unchanged under `-Dnetwork=usockets`.

---

## 11. Windows Adapter Headers (Stage 4)

All three are required. bun-usockets loop init calls `us_create_timer` (needs `timerfd`) and `us_internal_create_async` (needs `eventfd`) internally. These calls happen regardless of user code.

### `sys/epoll.h`
Redirect epoll symbols to wepoll (already vendored in `src/ampe/windows/wepoll/`):

```c
#pragma once
#include "wepoll.h"
// Map standard names to wepoll names if they differ
#define epoll_create1(f)          epoll_create(1)
// epoll_ctl, epoll_wait, epoll_event — wepoll uses the same names
```

### `sys/timerfd.h`
Emulate via Windows Waitable Timers. `timerfd` creates an fd-like handle that can be polled. Since wepoll supports `HANDLE` objects, use a thin wrapper:

```c
#pragma once
#include <windows.h>
#define TFD_NONBLOCK  0
#define TFD_CLOEXEC   0
#define CLOCK_MONOTONIC 1

struct itimerspec {
    struct timespec it_interval;
    struct timespec it_value;
};

static inline int timerfd_create(int clockid, int flags) {
    (void)clockid; (void)flags;
    HANDLE h = CreateWaitableTimerW(NULL, FALSE, NULL);
    return h ? (int)(intptr_t)h : -1;
}

static inline int timerfd_settime(int fd, int flags,
    const struct itimerspec *new_value, struct itimerspec *old_value) {
    (void)flags; (void)old_value;
    HANDLE h = (HANDLE)(intptr_t)fd;
    LARGE_INTEGER due;
    due.QuadPart = -(LONGLONG)(new_value->it_value.tv_sec * 10000000LL
                                + new_value->it_value.tv_nsec / 100);
    LONG period_ms = (LONG)(new_value->it_interval.tv_sec * 1000
                             + new_value->it_interval.tv_nsec / 1000000);
    return SetWaitableTimer(h, &due, period_ms, NULL, NULL, FALSE) ? 0 : -1;
}
```

### `sys/eventfd.h`
Emulate via Windows manual-reset event:

```c
#pragma once
#include <windows.h>
#define EFD_NONBLOCK 0
#define EFD_CLOEXEC  0

static inline int eventfd(unsigned int initval, int flags) {
    (void)initval; (void)flags;
    HANDLE h = CreateEventW(NULL, TRUE, FALSE, NULL);
    return h ? (int)(intptr_t)h : -1;
}

static inline int eventfd_write(int fd, uint64_t val) {
    (void)val;
    return SetEvent((HANDLE)(intptr_t)fd) ? 0 : -1;
}

static inline int eventfd_read(int fd, uint64_t *val) {
    *val = 1;
    return ResetEvent((HANDLE)(intptr_t)fd) ? 0 : -1;
}
```

---

## 12. Native Hardware Testing (Stage 6)

Run the full 4-mode sandwich on native Linux hardware. Cross-compile to verify Windows and macOS do not regress:

```sh
# Native Linux — all four optimize modes
zig build test -Doptimize=Debug        -Dnetwork=usockets  # 64/64
zig build test -Doptimize=ReleaseSafe  -Dnetwork=usockets  # 64/64
zig build test -Doptimize=ReleaseFast  -Dnetwork=usockets  # 64/64
zig build test -Doptimize=ReleaseSmall -Dnetwork=usockets  # 64/64

# Cross-compile (no native macOS or Windows machine needed for compile check)
zig build -Dtarget=x86_64-windows-gnu -Dnetwork=usockets
zig build -Dtarget=x86_64-macos      -Dnetwork=usockets
zig build -Dtarget=aarch64-macos     -Dnetwork=usockets
```

Native macOS and Windows hardware testing follows the same sandwich pattern once the cross-compile passes.

---

## 14. VSCode Debug Config (Stage 0)

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
    "args": ["build", "install", "-Dnetwork=usockets", "--summary", "all"],
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
    "args": ["build", "test", "-Dnetwork=usockets", "--summary", "all"],
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

## 13. Implementation Sequence


| Stage | Work | Acceptance criterion |
| :---- | :--- | :------------------- |
| **0** | VSCode config (launch.json + tasks.json) | C source stepping works in debugger |
| **1** | `build.zig` + `Skt.zig` + `SocketCreator.zig` | `sockets_tests.zig` pass on Linux |
| **2** | Notifier already done — run tests | `Notifier_tests.zig` pass on Linux |
| **3** | `triggers.zig` + `usockets_backend.zig` | All 64 tests pass, 4-mode sandwich on Linux |
| **4** | Windows adapter headers + build.zig include path | Cross-compile `x86_64-windows-gnu -Dnetwork=usockets` succeeds |
| **5** | macOS verify | Cross-compile `x86_64-macos -Dnetwork=usockets` succeeds |
| **6** | Native hardware testing + docs | Full sandwich passes; `AGENT_STATE.md` bumped |

**Stage 3 — Linux 4-mode sandwich:**
```sh
zig build test -Doptimize=Debug        -Dnetwork=usockets  # 64/64
zig build test -Doptimize=ReleaseSafe  -Dnetwork=usockets  # 64/64
zig build test -Doptimize=ReleaseFast  -Dnetwork=usockets  # 64/64
zig build test -Doptimize=ReleaseSmall -Dnetwork=usockets  # 64/64
```

---

## 14. Critical Files

| File | Action |
| :--- | :----- |
| `vendor/bun-usockets/src/loop.c` (line 369) | Add `__attribute__((weak))` to `us_internal_dispatch_ready_poll` |
| `build.zig` | Add usockets C source + include blocks (both `lib` and `lib_unit_tests`) |
| `src/ampe/usockets/Skt.zig` | Implement using `bsd_*` wrappers |
| `src/ampe/usockets/SocketCreator.zig` | Implement using `bsd_create_*` + `getaddrinfo` extern |
| `src/ampe/usockets/triggers.zig` | Add `toEvents` / `fromEvents` |
| `src/ampe/usockets/usockets_backend.zig` | Full implementation + export `us_internal_dispatch_ready_poll` |
| `src/ampe/windows/adapters/sys/epoll.h` | New — wepoll redirect |
| `src/ampe/windows/adapters/sys/timerfd.h` | New — Windows Waitable Timer shim |
| `src/ampe/windows/adapters/sys/eventfd.h` | New — Windows Event shim |
| `.vscode/launch.json` | Add `"c"` to sourceLanguages, add usockets config |
| `.vscode/tasks.json` | Add usockets build and test tasks |

---

## 15. Open Items (minor, resolved during implementation)

- **SeqN / tc wiring in `wait()`:** Confirm how `PollerCore` exposes the `*TriggeredChannel` for a given fd before `wait()` runs. The pattern in §7.5 (iterate `seqn_trc_map` and write ext pointers before polling) may need adjustment to match how `PollerCore` actually calls `wait()`. Read `src/ampe/poller.zig` at Stage 3 start.

- **`bsd_create_connect_socket` second parameter:** The `options` field in `bsd.h` — verify whether `0` is the correct default (non-blocking, no delay) or if a flag must be set. Read `bsd.c` implementation at Stage 1.

- **Abstract UDS namespace prefix on Linux:** `Notifier.zig` already handles this pattern. Copy the same `\x00` prefix logic to `SocketCreator.createUdsServer` for consistency.
