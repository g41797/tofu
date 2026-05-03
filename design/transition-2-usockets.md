# Transition to usockets: Information Base & Migration Plan

**Status:** Finalized Pre-Design
**Date:** 2026-05-03
**Purpose:** Comprehensive knowledge base for migrating Zig tofu from `std.posix` / `std.net` / `wepoll` to the uSockets C library for Zig 0.16+ compatibility.

---

## 1. Why Migration is Needed

- Zig 0.15.2 is the current base; Zig 0.16+ removes `std.posix` and `std.net` APIs entirely.
- `src/ampe/os/linux/Skt.zig` uses `std.posix` for socket operations on both Linux and macOS.
- `src/ampe/poller/epoll_backend.zig` and `kqueue_backend.zig` use OS primitives directly via `std.posix`.
- The wepoll C shim used for Windows is also a migration candidate for a unified C-backend.

---

## 2. Current Platform Architecture (To Be Replaced)

### 2.1 Platform Split in `internal.zig`
Currently, tofu uses a comptime switch to select backends:
- **Windows:** `os/windows/Skt.zig` + `wepoll_backend.zig`.
- **Linux/macOS:** `os/linux/Skt.zig` + `epoll_backend.zig` or `kqueue_backend.zig`.

### 2.2 PollerCore Design (Must Be Preserved)
The `PollerCore` logic in `src/ampe/poller/core.zig` must survive. It provides:
- **Dual-Map Indirection:** `ChannelNumber → SeqN → *TriggeredChannel`.
- **ABA Protection:** Using monotonic `SeqN` to prevent stale FD reuse issues.
- **Pointer Stability:** `TriggeredChannel` is heap-allocated and its address must remain stable for the kernel (especially on Windows).

### 2.3 Socket Type Per Platform

| Platform | Socket Type | Non-Blocking | Closure |
| :------- | :---------- | :----------- | :------ |
| Linux    | `fd_t` (i32) | `O_NONBLOCK` | `posix.close` |
| macOS    | `fd_t` (i32) | `O_NONBLOCK` | `posix.close` + raw `setsockopt` for linger |
| Windows  | `SOCKET` (usize) | `FIONBIO` | `closesocket` + `SO_LINGER=0` |

### 2.4 Notifier (Cross-Thread Wakeup) — Current

| Platform | Mechanism |
| :------- | :-------- |
| Linux    | Abstract UDS socket pair |
| macOS    | Filesystem-based UDS socket pair |
| Windows  | TCP loopback socket pair |

Replaced by `us_wakeup_loop` after migration (see Section 6.2).

### 2.5 Key Platform Rules (from OS_BACKENDS.md)

- Windows: `SO_LINGER=0` (abortive close) is **mandatory** on all socket close paths.
- Windows: wepoll constants differ from Linux — `EPOLL_CTL_MOD=2`, `EPOLL_CTL_DEL=3` (inverse of Linux order).
- Windows: `WepollEvent` uses custom ABI layout to match Windows C memory layout.
- Windows: UDS requires RS4+; no abstract namespace; unstable under high load.
- macOS: `setLingerAbort` must use raw `system.setsockopt` to avoid `EINVAL` panic.
- macOS: No abstract sockets in Notifier.

### 2.6 Triggers Abstraction

```zig
// packed u8 — intent-based, not mechanism-based
pub const Triggers = packed struct(u8) {
    notify:  bool,
    accept:  bool,
    connect: bool,
    send:    bool,
    recv:    bool,
    pool:    bool,
    err:     bool,
    timeout: bool,
};
```

`Triggers` expresses **what the Reactor wants** (`recv`, `send`, `accept`...), not **how the OS signals it** (`EPOLLIN`, `EVFILT_READ`...). This abstraction is platform-independent and survives the migration unchanged. The `triggers.zig` mapping layer must be reproduced for the usockets backend.

### 2.7 Nine-Phase Reactor Loop

These phases are the behavioral contract of tofu's Reactor. They must survive the migration intact.

1. Compute timeout
2. Poll (OS wait) — replaced by `us_loop_run_bun_tick`
3. Classify events
4. Check timeouts
5. Drain inbox
6. Resolve events
7. Dispatch I/O
8. Process closes
9. Drain check

---

## 3. Inventory: Zig tofu’s POSIX/OS Usage

| File | Symbol(s) | Role |
| :--- | :--- | :--- |
| `src/ampe/poller/epoll_backend.zig` | `epoll_create1`, `epoll_ctl`, `epoll_wait` | Linux event loop |
| `src/ampe/poller/kqueue_backend.zig` | `kqueue`, `kevent` | macOS/BSD event loop |
| `src/ampe/poller/wepoll_backend.zig` | `wepoll.h` (C shim) | Windows event loop |
| `src/ampe/os/linux/Skt.zig` | `posix.bind`, `posix.listen`, `posix.accept`, `posix.connect`, `posix.close` | Sockets (Linux/macOS) |
| `src/ampe/os/windows/Skt.zig` | `ws2_32.bind`, `ws2_32.listen`, `ws2_32.accept`, `ws2_32.connect`, `ws2_32.closesocket` | Sockets (Windows) |
| `src/ampe/SocketCreator.zig` | `std.net.Address`, `std.net.getAddressList` | Address resolution & socket creation |
| `src/ampe/triggeredSkts.zig` | `posix.send`, `posix.sendto`, `posix.iovec_const` | Data transmission |
| `src/ampe/Notifier.zig` | `UDS / TCP pair`, `posix.recv`, `posix.send` | Cross-thread loop wakeup |

---

## 4. Deep uSockets Analysis (vendor/bun-usockets)

### 4.1 Architecture & Model
- **Platform Backends:** Uses `epoll` (Linux), `kqueue` (macOS/BSD), and `libuv` (Windows default).
- **Windows — two options:**
  - `LIBUS_USE_LIBUV`: bun's actual Windows path. Requires libuv as a dependency.
  - `LIBUS_USE_EPOLL` + wepoll shim: preferred tofu path. `epoll_kqueue.h` does `#include <sys/epoll.h>` under `LIBUS_USE_EPOLL`; on Windows that header does not exist natively. A one-file shim (`sys/epoll.h` → `#include <wepoll.h>`) connects the two. Tofu already vendors `wepoll.h` + `wepoll.c` at `src/ampe/os/windows/wepoll/`. No changes to bun-usockets C source required. bun-usockets does **not** embed wepoll — it must be supplied externally.
- **Loop Integration:** Supports `us_loop_run_bun_tick(loop, timeout)`, which executes a single iteration—perfect for a Reactor model.
- **User Data:** `us_poll_t` provides "extension memory" (`ext_size`) for storing the `*TriggeredChannel` context.

### 4.2 Key Capabilities
- **Threading:** Strictly single-threaded loop. Thread-safe wakeup is provided by `us_wakeup_loop(loop)`.
- **Backpressure:** `us_socket_write` returns bytes accepted and auto-arms writable triggers on partial success.
- **Allocation:** Uses `us_calloc` and `us_free`. Can be shimmed to use Zig's GPA or a global C-allocator.

---

## 5. Insights from Bun's uSockets Integration

Analysis of the Bun repository (`/home/g41797/dev/root/github.com/oven-sh/bun/`) reveals how to idiomaticaly integrate uSockets into a Zig project.

### 5.1 The "Tick" Reactor Model
Bun mirrors tofu's Reactor model by using `us_loop_run_bun_tick(loop, timeout)`. 
- **Control:** Bun does NOT use the standard `us_loop_run()` (callback-driven proactor). Instead, it calls `tick()` from its main `VirtualMachine.tick()`, allowing the Zig layer to remain the primary driver.
- **Notifications:** Cross-thread signaling uses `us_wakeup_loop(loop)`. The `wakeup` callback is defined in Zig (via `callconv(.c)`) and typically signals the loop to drain a task queue.

### 5.2 Binding & Dispatch Mechanism
- **C-to-Zig Bounce:** Bun uses a central `src/deps/uws/dispatch.zig` that `export`s functions like `us_dispatch_data` and `us_dispatch_writable`.
- **Kind-Based Switching:** Every socket is stamped with a `SocketKind` (e.g., `.bun_socket_tcp`, `.postgres`). The dispatch layer switches on this kind to route events to the correct Zig handler.
- **VTable Trampolines:** Bun generates static C-ABI compatible vtables at comptime via `vtable.make(H)`. This allows uSockets to call a single C function pointer which "bounces" into a Zig trampoline that:
    1. Recovers the typed `ext` context from `us_socket_t`.
    2. Forwards the call to the high-level Zig handler.

### 5.3 Context & Memory Management
- **Recovery:** Bun stores the Zig object pointer (`*This`) directly in the `us_socket_t.ext()` memory.
- **Allocation:** uSockets uses `us_calloc`/`us_free`. Bun's fork defines these as standard `calloc`/`free`. Since Bun uses `mimalloc` as its global allocator, the C calls are automatically routed to it.

### 5.4 Build & Windows Strategy
- **Unified Sources:** Bun uses a custom "Unified Source" build to concatenate small C files into larger translation units for speed.
- **Windows backend:** Bun uses `LIBUS_USE_LIBUV` on Windows. Neither the vendored `bun-usockets` nor the bun repo contain wepoll — zero references. The `LIBUS_USE_EPOLL` + wepoll shim path (see Section 4.1) is tofu's preferred option to avoid a libuv dependency. It requires one build artifact: a `sys/epoll.h` file that redirects to `wepoll.h`.

---

## 6. Master Mapping Tables

### 6.1 Low-Level Socket Cycle (Replacing Removed APIs)

| Zig Tofu / `std.posix` (REMOVED in 0.16) | uSockets Equivalent | Description |
| :--- | :--- | :--- |
| `posix.socket` | `us_socket_group_listen` / `connect` | Creation is part of the listen/connect request. |
| `posix.bind` / `posix.listen` | `us_socket_group_listen` | Combined bind + listen into a single call. |
| `posix.accept` | `on_open` callback | uSockets manages the accept loop internally. |
| `posix.connect` | `us_socket_group_connect` | Managed non-blocking connect with DNS support. |
| `posix.recv` | `on_data` callback | uSockets reads into shared buffer; Tofu handles in `on_data`. |
| `posix.send` | `us_socket_write` | uSockets handles transmission and backpressure. |
| `posix.close` | `us_socket_close` | Unified close; support for reset/abort (code `1`). |
| `O_NONBLOCK` / `FIONBIO` | (Automatic) | All uSockets handles are non-blocking. |
| `TCP_NODELAY` | `us_socket_nodelay` | Simple toggle for Nagles algorithm. |
| `SO_LINGER` (Abortive) | `us_socket_close(..., 1, ...)` | Using close code `1` (Reset) triggers abortive shutdown. |

### 6.2 High-Level Functionality Mapping

| Tofu Zig Requirement | uSockets Equivalent | Notes |
| :--- | :--- | :--- |
| **IP Resolution** | `Bun__addrinfo_get` | Bun-specific extension in `internal.h` for DNS. |
| **DNS List Strategy** | `us_socket_group_connect` | Handles multiple IPs and address families internally. |
| **Unix Sockets (UDS)** | `..._listen_unix` / `..._connect_unix` | Unified UDS support across platforms. |
| **Loop Wakeup** | `us_wakeup_loop` | Replaces UDS/TCP socket-pair `Notifier` logic. |
| **Timer/Timeout** | `us_socket_timeout` | Integrated timer support (4s granularity). |
| **OS Wait** | `us_loop_run_bun_tick` | Single-iteration drive for the Reactor loop. |
| **Peer Identity** | `us_socket_remote_address` | Replaces `getnameinfo` for logging/security. |

---

## 7. Architecture Layer Map

Migration scope is L0 and L1 only. L2 may require internal restructuring for `us_loop_run_bun_tick` integration, but the 9-phase loop structure must be preserved.

```
L5  Public API        — Ampe, ChannelGroup, vtables         (untouched)
L4  Protocol          — framing, message lifecycle           (untouched)
L3  Messaging Runtime — Engine, Reactor loop, backpressure   (untouched)
L2  Reactor Core      — waitTriggers, event dispatch         (internal restructure only)
L1  OS / Poller       — epoll / kqueue / wepoll              (THIS IS WHAT CHANGES)
L0  External          — std.posix, ws2_32, wepoll.h          (replaced by usockets)
```

---

## 8. Migration Strategy: The "Hook-Back" Pattern

To preserve tofu's unique Reactor architecture (L2-L5 layers) while replacing the L0-L1 OS layer:

1.  **Poll Creation:** Each `TriggeredChannel` creates a `us_poll_t` with type `POLL_TYPE_CALLBACK`.
2.  **Context Binding:** The `*TriggeredChannel` pointer is stored in the poll's extension memory (`ext_size`).
3.  **Tick Phase:** `Reactor.waitTriggers` calls `us_loop_run_bun_tick`.
4.  **The Bounce:**
    - uSockets receives an OS event.
    - It calls a static C callback (Zig shim via `export fn`).
    - The Zig shim retrieves the `*TriggeredChannel` from the poll extension.
    - The shim updates `tc.act` with the triggered events (Recv, Send, etc.).
5.  **Dispatch:** After the tick returns, `waitTriggers` returns the accumulated `Triggers` summary for tofu's 9-phase loop to process.

---

## 9. Open Questions & Resolutions

- **Reactor Preservation?** YES. Validated by Bun's "Tick" pattern.
- **Socket Handle?** `Skt` will wrap `us_poll_t*`. Raw I/O still available via `us_poll_fd(p)`.
- **Pointer Stability?** Guaranteed. `TriggeredChannel` stays heap-allocated; stored in `ext`.
- **Notifier?** Replaced by `us_wakeup_loop`.
- **Windows UDS?** Becomes consistent via uSockets abstraction over `wepoll`.
- **Abortive Close?** Supported via close code `1` (Reset).

---

## 10. Key Constraints (Non-Negotiable)

- **Reactor model is mandatory.**
- **Pointer stability is mandatory.** TriggeredChannel must remain heap-allocated.
- **ABA protection is mandatory.** `SeqN` dual-map must be preserved.
- **Abortive close is mandatory on Windows.** `SO_LINGER=0` must be used.
- **Verification Sequence:** Linux → Windows → macOS → Linux (Sandwich rule).
- **4-mode testing required.** Debug, ReleaseSafe, ReleaseFast, ReleaseSmall — all platforms.
- **Architectural changes require author approval** before implementation.
- **No git commands.** Author manages version control manually.

---

*End of migration plan.*
