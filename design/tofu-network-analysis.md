# Tofu Networking — L3/L4/L5 Stdlib Replacement Analysis

## Overview

This document classifies every item in the L3 (posixnet wrapper), L4 (uSockets C symbols), and
L5 (OS primitives) layers of the Tofu networking stack.

Three classifications are used:

- **KEEP** — already optimal; no stdlib replacement needed or beneficial.
- **REPLACE_WITH_STD** — a direct Zig 0.16 stdlib equivalent exists and covers the functionality.
- **LACKING** — no Zig 0.16 stdlib equivalent exists; custom implementation would be required.

Classification applies per platform: Linux, macOS, Windows.

The `stdposix` backend is out of scope.

Zig 0.16 stdlib path used for verification: `/home/g41797/dev/langs/zig-x86_64-linux-0.16.0/lib/std`.

Key files examined:
- `os/linux.zig` — raw Linux syscall wrappers.
- `c.zig` — libc extern declarations, kqueue, POSIX socket, getaddrinfo.
- `Io/net.zig` — high-level async TCP/UDS API over `std.Io`.
- `Io/Kqueue.zig` — kqueue-based async I/O runtime.
- `Io/Uring.zig` — io_uring-based async I/O runtime (Linux default in 0.16).
- `os/windows/ws2_32.zig` — Winsock constants and types (no function bindings).

---

## Linux Analysis

### L3 posixnet wrapper

| Symbol | Classification | Rationale |
|---|---|---|
| `pn.acceptSocket` | KEEP | Wraps `bsd_accept_socket` which calls `accept4(SOCK_NONBLOCK\|SOCK_CLOEXEC)`. No stdlib high-level equivalent for non-blocking accept at this layer. |
| `pn.connectSocket` | KEEP | Wraps `pn_connect_socket`. Handles EINPROGRESS/EALREADY logic for non-blocking connect. No stdlib equivalent at this abstraction level. |
| `pn.connectSocketUnix` | KEEP | Wraps `pn_create_connect_socket_unix`. No stdlib equivalent for direct non-blocking UDS connect. |
| `pn.sendBuf` | KEEP | Wraps `bsd_send`. Direct MSG_NOSIGNAL send with EAGAIN detection. `std.os.linux.sendto` exists but requires caller to manage flag/errno handling. |
| `pn.recvToBuf` | KEEP | Wraps `bsd_recv`. Direct recv with EAGAIN detection. Same rationale as sendBuf. |
| `pn.closeSocket` | KEEP | Wraps `bsd_close_socket`. Calls `close()` with errno check. `std.os.linux.close` (line 1592) is equivalent in principle but different signature (returns raw usize). |
| `pn.nodelay` | KEEP | Wraps `bsd_socket_nodelay`. Sets TCP_NODELAY via `setsockopt`. `std.os.linux.setsockopt` exists (line 2312) but no nodelay-specific helper. |
| `pn.setLingerAbort` | KEEP | Wraps `bsd_set_linger_abort`. Sets SO_LINGER with `l_onoff=1, l_linger=0`. No stdlib equivalent. |
| `pn.keepalive` | KEEP | Wraps `bsd_socket_keepalive`. Sets SO_KEEPALIVE. No stdlib helper. |
| `pn.localAddr` | KEEP | Wraps `bsd_local_addr`. Calls `getsockname` into `pn.Addr`. No stdlib equivalent for `pn.Addr` type. |
| `pn.remoteAddr` | KEEP | Wraps `bsd_remote_addr`. Calls `getpeername` into `pn.Addr`. No stdlib equivalent. |
| `pn.addrPort` | KEEP | Pure-Zig: reads port bytes from `pn.Addr.mem[2..4]`. No stdlib dependency. |
| `pn.addrFamily` | KEEP | Pure-Zig: reads address family from `pn.Addr.mem`. Platform-aware byte layout. No stdlib dependency. |
| `pn.getaddrinfo` | REPLACE_WITH_STD | `std.c.getaddrinfo` at `c.zig:10925`. Direct libc extern. Functionally identical. |
| `pn.freeaddrinfo` | REPLACE_WITH_STD | `std.c.freeaddrinfo` at `c.zig:10934`. Direct libc extern. Functionally identical. |
| `pn.createSocket` | KEEP | Wraps `bsd_create_socket`. Creates a non-blocking socket with SOCK_CLOEXEC. No stdlib equivalent at this level. |
| `pn.createClientSocket` | KEEP | Wraps `bsd_create_socket` + sets non-blocking. No stdlib equivalent. |
| `pn.createListenSocket` | KEEP | Wraps `pn_create_listen_socket`. Combines socket+SO_REUSEADDR+bind+listen. No stdlib one-call equivalent. |
| `pn.createListenSocketUnix` | KEEP | Wraps `pn_create_listen_socket_unix`. No stdlib equivalent. |
| `pn.createListenSocketFromSockaddr` | KEEP | Wraps `pn_create_listen_socket_from_sockaddr`. Takes pre-built sockaddr. No stdlib equivalent. |
| `pn.createConnectSocketUnix` | KEEP | Wraps `pn_create_connect_socket_unix`. Non-blocking UDS connect. No stdlib equivalent. |
| `pn.initAddrUnix` | KEEP | Pure-Zig: writes sockaddr_un into `pn.Addr`. Platform-aware layout. No stdlib equivalent for `pn.Addr`. |
| `pn.initAddrIp4` | KEEP | Pure-Zig: writes sockaddr_in into `pn.Addr`. No stdlib equivalent for `pn.Addr`. |
| `pn.Addr` | KEEP | 128-byte sockaddr_storage buffer. Custom type; stdlib uses `std.posix.sockaddr` or OS-specific structs. Removing `pn.Addr` would require cascade changes across all backends. |
| `pn.thread_sleep_ms` | REPLACE_WITH_STD | `std.os.linux.nanosleep` at `os/linux.zig:1999`. Converts ms to nanosecond timespec. Wrappable in a trivial inline function. |
| `pn.startup_sockets` | KEEP | No-op on Linux. No stdlib action required. |
| `pn.cleanup_sockets` | KEEP | No-op on Linux. No stdlib action required. |
| `pn.unlink` | REPLACE_WITH_STD | `std.os.linux.unlink` at `os/linux.zig:1792`. Direct syscall wrapper. Identical signature. |

### L4 uSockets symbols

| Symbol | Classification | Rationale |
|---|---|---|
| `us_create_loop` | KEEP | Calls `epoll_create1` + timerfd + eventfd. The Zig stdlib provides individual syscalls (`os/linux.zig:2621`, `2649`, `2645`) but not the combined loop-init concept. |
| `us_loop_free` | KEEP | Frees loop state, closes epoll/timerfd/eventfd fds. Custom lifecycle; no stdlib equivalent. |
| `us_loop_run_tick` | KEEP | Calls `epoll_wait` and dispatches via `us_internal_dispatch_ready_poll`. The dispatch pattern is Tofu-specific. No stdlib equivalent. |
| `us_create_poll` | KEEP | Allocates per-fd poll state. Custom structure; no stdlib equivalent. |
| `us_poll_free` | KEEP | Frees per-fd poll state. No stdlib equivalent. |
| `us_poll_init` | KEEP | Initializes poll slot with fd and type. No stdlib equivalent. |
| `us_poll_start` | KEEP | Calls `epoll_ctl(EPOLL_CTL_ADD)`. `std.os.linux.epoll_ctl` (line 2625) exists but the poll wrapping is Tofu-specific. |
| `us_poll_change` | KEEP | Calls `epoll_ctl(EPOLL_CTL_MOD)`. Same rationale. |
| `us_poll_stop` | KEEP | Calls `epoll_ctl(EPOLL_CTL_DEL)`. Same rationale. |
| `us_poll_ext` | KEEP | Returns per-fd user data pointer. Custom slot; no stdlib equivalent. |
| `us_internal_poll_type` | KEEP | Returns poll type byte. Custom enum; no stdlib equivalent. |
| `us_internal_dispatch_ready_poll` | KEEP | Zig-override of uSockets weak symbol. Tofu-specific dispatch hook. No stdlib concept. |
| `bsd_set_linger_abort` | KEEP | Sets SO_LINGER with l_linger=0. No stdlib helper. |
| `bsd_create_listen_socket` | KEEP | Multi-step: socket+REUSEADDR+bind+listen. No stdlib one-liner. |
| `bsd_create_listen_socket_unix` | KEEP | UDS listen socket with unlink-first. No stdlib equivalent. |
| `bsd_create_socket` | KEEP | Non-blocking SOCK_CLOEXEC socket. No stdlib equivalent at this level. |
| `bsd_connect_socket_unix` | KEEP | Non-blocking UDS connect with EINPROGRESS handling. No stdlib equivalent. |
| `bsd_accept_socket` | KEEP | `accept4(SOCK_NONBLOCK\|SOCK_CLOEXEC)`. `std.os.linux.accept4` exists (line 2452) but `bsd_accept_socket` wraps it with error-normalisation. |
| `bsd_recv` | KEEP | `recv` with MSG_NOSIGNAL and EAGAIN normalisation. No stdlib equivalent. |
| `bsd_send` | KEEP | `send` with MSG_NOSIGNAL and EAGAIN normalisation. No stdlib equivalent. |
| `bsd_close_socket` | KEEP | `close` with errno handling. `std.os.linux.close` exists (line 1592) but bsd_close_socket adds retry-on-EINTR. |
| `bsd_shutdown_socket` | KEEP | `shutdown` wrapper. `std.os.linux.shutdown` exists (line 2390) but bsd_shutdown_socket normalises errors. |
| `bsd_shutdown_socket_read` | KEEP | `shutdown(SHUT_RD)`. Same rationale. |
| `bsd_set_nonblocking` | KEEP | `fcntl(O_NONBLOCK)`. `std.os.linux.fcntl` exists (line 1919) but bsd_set_nonblocking is a convenience wrapper. |
| `bsd_socket_nodelay` | KEEP | `setsockopt(TCP_NODELAY)`. No stdlib one-liner. |
| `bsd_socket_keepalive` | KEEP | `setsockopt(SO_KEEPALIVE)`. No stdlib one-liner. |
| `bsd_would_block` | KEEP | Tests errno for EAGAIN/EWOULDBLOCK. No stdlib equivalent. |
| `bsd_local_addr` | KEEP | `getsockname` into opaque buffer. No stdlib equivalent for `pn.Addr`. |
| `bsd_remote_addr` | KEEP | `getpeername` into opaque buffer. No stdlib equivalent for `pn.Addr`. |
| `bsd_addr_get_port` | KEEP (unused) | Declared, not called. Pure-Zig `addrPort` is used instead. |
| `bsd_addr_get_ip` | KEEP (unused) | Declared, not called. |
| `bsd_addr_get_ip_length` | KEEP (unused) | Declared, not called. |
| `pn_create_listen_socket` | KEEP | TCP listen with explicit backlog. No stdlib equivalent. |
| `pn_create_listen_socket_unix` | KEEP | UDS listen with explicit backlog. No stdlib equivalent. |
| `pn_create_connect_socket_unix` | KEEP | Non-blocking UDS connect. No stdlib equivalent. |
| `pn_wait_writable` | KEEP | `select` poll for connect completion + `getsockopt(SO_ERROR)`. No stdlib equivalent. |
| `pn_connect_socket` | KEEP | Non-blocking TCP connect with EINPROGRESS/EALREADY/EISCONN handling. No stdlib equivalent. |
| `pn_create_listen_socket_from_sockaddr` | KEEP | TCP listen from pre-built sockaddr. No stdlib equivalent. |

### L5 OS primitives (Linux)

| Syscall/function | Classification | stdlib_ref |
|---|---|---|
| `epoll_create1` | REPLACE_WITH_STD | `std.os.linux.epoll_create1` — `os/linux.zig:2621` |
| `epoll_wait` | REPLACE_WITH_STD | `std.os.linux.epoll_wait` — `os/linux.zig:2629` |
| `epoll_ctl` | REPLACE_WITH_STD | `std.os.linux.epoll_ctl` — `os/linux.zig:2625` |
| `timerfd_create` | REPLACE_WITH_STD | `std.os.linux.timerfd_create` — `os/linux.zig:2649` |
| `timerfd_settime` | REPLACE_WITH_STD | `std.os.linux.timerfd_settime` — `os/linux.zig:2670` |
| `eventfd` | REPLACE_WITH_STD | `std.os.linux.eventfd` — `os/linux.zig:2645` |
| `socket` | REPLACE_WITH_STD | `std.os.linux.socket` — `os/linux.zig:2305` |
| `bind` | REPLACE_WITH_STD | `std.os.linux.bind` — `os/linux.zig:2397` |
| `listen` | REPLACE_WITH_STD | `std.os.linux.listen` — `os/linux.zig:2404` |
| `accept4` | REPLACE_WITH_STD | `std.os.linux.accept4` — `os/linux.zig:2452` |
| `connect` | REPLACE_WITH_STD | `std.os.linux.connect` — `os/linux.zig:2340` |
| `send` | REPLACE_WITH_STD | `std.os.linux.sendto` (send with null addr/alen=0) — `os/linux.zig:2411` |
| `recv` | REPLACE_WITH_STD | `std.os.linux.recvfrom` (recv with null addr) — `os/linux.zig:2371` |
| `shutdown` | REPLACE_WITH_STD | `std.os.linux.shutdown` — `os/linux.zig:2390` |
| `close` | REPLACE_WITH_STD | `std.os.linux.close` — `os/linux.zig:1592` |
| `fcntl(O_NONBLOCK)` | REPLACE_WITH_STD | `std.os.linux.fcntl` — `os/linux.zig:1919` |
| `setsockopt` | REPLACE_WITH_STD | `std.os.linux.setsockopt` — `os/linux.zig:2312` |
| `getsockopt` | REPLACE_WITH_STD | `std.os.linux.getsockopt` — `os/linux.zig:2319` |
| `getsockname` | REPLACE_WITH_STD | `std.os.linux.getsockname` — `os/linux.zig:2291` |
| `getpeername` | REPLACE_WITH_STD | `std.os.linux.getpeername` — `os/linux.zig:2298` |
| `nanosleep` | REPLACE_WITH_STD | `std.os.linux.nanosleep` — `os/linux.zig:1999` |
| `select` | LACKING | No `select` wrapper in `std.os.linux`. Only `poll`/`ppoll` exist in `std.posix` (line 1003). The C `select` is not exposed via stdlib on Linux. |
| `unlink` | REPLACE_WITH_STD | `std.os.linux.unlink` — `os/linux.zig:1792` |
| `write` (eventfd drain) | REPLACE_WITH_STD | `std.os.linux.write` — `os/linux.zig:1427` |
| `read` (timerfd/eventfd drain) | REPLACE_WITH_STD | `std.os.linux.read` — `os/linux.zig:1267` |

---

## macOS Analysis

### L3 posixnet wrapper

Same as Linux analysis. All `pn.*` wrapper functions are cross-platform. The classifications
and rationale are identical to the Linux column. Key difference: on macOS, `pn.acceptSocket`
calls `accept` + `fcntl(F_SETNOSIGPIPE)` + `fcntl(O_NONBLOCK)` instead of `accept4`.

### L4 uSockets symbols

| Symbol | Classification | Rationale |
|---|---|---|
| `us_create_loop` | KEEP | Calls `kqueue()` + kevent for EVFILT_TIMER + EVFILT_USER. `std.c.kqueue` (c.zig:10888) exists but the loop-init concept has no stdlib equivalent. |
| `us_loop_free` | KEEP | Frees kqueue loop. No stdlib equivalent. |
| `us_loop_run_tick` | KEEP | Calls `kevent` (wait) and dispatches. `std.c.kevent` (c.zig:10889) exists but the dispatch pattern is Tofu-specific. |
| `us_create_poll` | KEEP | Same rationale as Linux. |
| `us_poll_free` | KEEP | Same rationale as Linux. |
| `us_poll_init` | KEEP | Same rationale as Linux. |
| `us_poll_start` | KEEP | Calls `kevent(EVFILT_READ + EVFILT_WRITE, EV_ADD)`. Individual kevent call could use `std.c.kevent` but the poll wrapping is Tofu-specific. |
| `us_poll_change` | KEEP | Calls `kevent` to modify filters. Same rationale. |
| `us_poll_stop` | KEEP | Calls `kevent(EV_DELETE)`. Same rationale. |
| `us_poll_ext` | KEEP | Same rationale as Linux. |
| `us_internal_poll_type` | KEEP | Same rationale as Linux. |
| `us_internal_dispatch_ready_poll` | KEEP | Same rationale as Linux. |
| `bsd_*` symbols (all) | KEEP | Same rationale as Linux. On macOS, `bsd_accept_socket` uses `accept` + `fcntl(F_SETNOSIGPIPE)` instead of `accept4`; no stdlib helper covers this compound operation. |
| `pn_*` symbols (all) | KEEP | Same rationale as Linux. |

### L5 OS primitives (macOS)

| Syscall/function | Classification | stdlib_ref |
|---|---|---|
| `kqueue` | REPLACE_WITH_STD | `std.c.kqueue` — `c.zig:10888` |
| `kevent` (wait) | REPLACE_WITH_STD | `std.c.kevent` — `c.zig:10889` |
| `kevent` (register/change) | REPLACE_WITH_STD | `std.c.kevent` — `c.zig:10889` |
| `EVFILT_READ/WRITE/TIMER/USER` | REPLACE_WITH_STD | `std.c.EVFILT` — `c.zig:9865` |
| `EV_ADD/DELETE/ENABLE/DISABLE/EOF/ERROR` | REPLACE_WITH_STD | `std.c.EV` — `c.zig:9722` |
| `NOTE_TRIGGER` (EVFILT_USER wakeup) | REPLACE_WITH_STD | `std.c.NOTE.TRIGGER` — `c.zig:9991` |
| `socket` | REPLACE_WITH_STD | `std.c.socket` — `c.zig:10572` |
| `bind` | REPLACE_WITH_STD | `std.c.bind` — `c.zig:10730` |
| `listen` | REPLACE_WITH_STD | `std.c.listen` — `c.zig:10731` |
| `accept` + `fcntl(O_NONBLOCK)` | REPLACE_WITH_STD | `std.c.accept` — `c.zig:10735`; `std.c.fcntl` — `c.zig:10725` |
| `F_SETNOSIGPIPE` | REPLACE_WITH_STD | `std.c.F.SETNOSIGPIPE` — `c.zig:927` (within F struct, macOS section) |
| `connect` | REPLACE_WITH_STD | `std.c.connect` — `c.zig:10734` |
| `send` | REPLACE_WITH_STD | `std.c.send` — `c.zig:10739` |
| `recv` | REPLACE_WITH_STD | `std.c.recv` — `c.zig:10751` |
| `shutdown` | REPLACE_WITH_STD | `std.c.shutdown` — `c.zig:10729` |
| `close` | REPLACE_WITH_STD | `std.c.close` — `c.zig:10285` |
| `fcntl(O_NONBLOCK)` | REPLACE_WITH_STD | `std.c.fcntl` — `c.zig:10725` |
| `setsockopt` | REPLACE_WITH_STD | `std.c.setsockopt` — `c.zig:10738` |
| `getsockopt` | REPLACE_WITH_STD | `std.c.getsockopt` — `c.zig:10737` |
| `getsockname` | REPLACE_WITH_STD | `std.c.getsockname` — `c.zig:10732` |
| `getpeername` | REPLACE_WITH_STD | `std.c.getpeername` — `c.zig:10733` |
| `select` | LACKING | Not exposed in stdlib. See Linux note. |

---

## Windows Analysis

### L3 posixnet wrapper

Same as Linux for most items. Key difference: `pn.startup_sockets` and `pn.cleanup_sockets`
call `WSAStartup`/`WSACleanup` on Windows, which are not in the stdlib (see L5 below).

| Symbol | Classification | Rationale |
|---|---|---|
| `pn.startup_sockets` | KEEPING | Calls `WSAStartup`. No stdlib equivalent for Winsock initialization. |
| `pn.cleanup_sockets` | KEEPING | Calls `WSACleanup`. No stdlib equivalent. |
| `pn.unlink` / `pn._unlink` | LACKING | Neither `std.os.linux.unlink` nor a Windows filesystem delete is exposed in the stdlib at the raw C extern level needed here. `std.Io.Dir.deleteFile` exists but requires an `Io` instance and is async. The Windows path calls `_unlink` from MSVCRT. |
| All other `pn.*` | KEEP | Same rationale as Linux/macOS. |

### L4 uSockets symbols

| Symbol | Classification | Rationale |
|---|---|---|
| `us_create_loop` | KEEP | On Windows calls wepoll `epoll_create1` adapter. wepoll has no stdlib equivalent. |
| `us_loop_free` | KEEP | Frees wepoll loop. No stdlib equivalent. |
| `us_loop_run_tick` | KEEP | Calls wepoll `epoll_wait` adapter + dispatch. No stdlib equivalent. |
| `us_create_poll` | KEEP | Same rationale as Linux. |
| `us_poll_free` | KEEP | Same rationale as Linux. |
| `us_poll_init` | KEEP | Same rationale as Linux. |
| `us_poll_start` | KEEP | Calls wepoll `epoll_ctl(EPOLL_CTL_ADD)`. No stdlib equivalent. |
| `us_poll_change` | KEEP | Calls wepoll `epoll_ctl(EPOLL_CTL_MOD)`. No stdlib equivalent. |
| `us_poll_stop` | KEEP | Calls wepoll `epoll_ctl(EPOLL_CTL_DEL)`. No stdlib equivalent. |
| `us_poll_ext` | KEEP | Same rationale as Linux. |
| `us_internal_poll_type` | KEEP | Same rationale as Linux. |
| `us_internal_dispatch_ready_poll` | KEEP | Same rationale as Linux. |
| `bsd_*` symbols (all) | KEEP | On Windows, these call Winsock2 functions. None of the Winsock functions (`WSASend`, `WSARecv`, `closesocket`, `ioctlsocket`) are exposed via Zig stdlib. |
| `pn_*` symbols (all) | KEEP | Same rationale. `pn_wait_writable` uses Winsock `select`. |

### L5 OS primitives (Windows)

| Syscall/function | Classification | Rationale |
|---|---|---|
| `WSAStartup` | LACKING | No stdlib binding. Zig's `Io.Threaded` initialises Winsock internally via AFD, but there is no public `WSAStartup` extern in the stdlib. |
| `WSACleanup` | LACKING | Same as `WSAStartup`. |
| `socket` | LACKING | Winsock `socket()` is not in stdlib. `ws2_32.zig` has types and constants but no function bindings. The stdlib's `Io.Threaded` uses AFD (`openSocketAfd`) internally, not `socket()` directly. |
| `bind` | LACKING | Winsock `bind()` has no stdlib binding. |
| `listen` | LACKING | Winsock `listen()` has no stdlib binding. |
| `accept` | LACKING | Winsock `accept()` has no stdlib binding. |
| `connect` | LACKING | Winsock `connect()` has no stdlib binding. |
| `send` | LACKING | Winsock `send()` has no stdlib binding. |
| `recv` | LACKING | Winsock `recv()` has no stdlib binding. |
| `closesocket` | LACKING | No stdlib binding. Different from POSIX `close`. |
| `ioctlsocket(FIONBIO)` | LACKING | No stdlib binding. Used for non-blocking mode on Windows. |
| `setsockopt` | LACKING | Winsock `setsockopt()` has no stdlib binding. |
| `getsockopt` | LACKING | Winsock `getsockopt()` has no stdlib binding. |
| `getsockname` | LACKING | Winsock `getsockname()` has no stdlib binding. |
| `getpeername` | LACKING | Winsock `getpeername()` has no stdlib binding. |
| `select` | LACKING | Winsock `select()` has no stdlib binding. |
| `WSAGetLastError` | LACKING | No stdlib binding. |
| `Sleep(ms)` | LACKING | `kernel32.Sleep` has no stdlib binding. `std.Io` has sleep via `Io.Timeout` but not a raw millisecond C extern. |
| `epoll_create1` (wepoll) | LACKING | wepoll adapter; not a real syscall. No stdlib equivalent for epoll emulation over Windows AFD. |
| `epoll_ctl` (wepoll) | LACKING | Same as above. |
| `epoll_wait` (wepoll) | LACKING | Same as above. |
| `AF_UNIX` / `sockaddr_un` | REPLACE_WITH_STD | `std.os.windows.ws2_32.AF.UNIX` — `ws2_32.zig:43`; `std.os.windows.ws2_32.sockaddr.un` — `ws2_32.zig:231` |

---

## Cross-Platform Summary

The table below lists each item with its classification per platform. Only items that differ
across platforms or have non-trivial classifications are shown in full. KEEP items that are
identical across all three platforms are grouped.

### L3 — All KEEP across all platforms (same rationale)

`pn.acceptSocket`, `pn.connectSocket`, `pn.connectSocketUnix`, `pn.sendBuf`, `pn.recvToBuf`,
`pn.closeSocket`, `pn.nodelay`, `pn.setLingerAbort`, `pn.keepalive`, `pn.localAddr`,
`pn.remoteAddr`, `pn.addrPort`, `pn.addrFamily`, `pn.createSocket`, `pn.createClientSocket`,
`pn.createListenSocket`, `pn.createListenSocketUnix`, `pn.createListenSocketFromSockaddr`,
`pn.createConnectSocketUnix`, `pn.initAddrUnix`, `pn.initAddrIp4`, `pn.Addr`

### L3 — Items with platform differences

| Symbol | Linux | macOS | Windows |
|---|---|---|---|
| `pn.getaddrinfo` | REPLACE_WITH_STD (`c.zig:10925`) | REPLACE_WITH_STD (`c.zig:10925`) | REPLACE_WITH_STD (`c.zig:10925`) |
| `pn.freeaddrinfo` | REPLACE_WITH_STD (`c.zig:10934`) | REPLACE_WITH_STD (`c.zig:10934`) | REPLACE_WITH_STD (`c.zig:10934`) |
| `pn.thread_sleep_ms` | REPLACE_WITH_STD (`os/linux.zig:1999`) | REPLACE_WITH_STD (`std.c.nanosleep` `c.zig:10493`) | LACKING (no `Sleep` extern in stdlib) |
| `pn.startup_sockets` | KEEP (no-op) | KEEP (no-op) | KEEP (calls WSAStartup; no stdlib equivalent) |
| `pn.cleanup_sockets` | KEEP (no-op) | KEEP (no-op) | KEEP (calls WSACleanup; no stdlib equivalent) |
| `pn.unlink` | REPLACE_WITH_STD (`os/linux.zig:1792`) | REPLACE_WITH_STD (`std.c.unlink` `c.zig:10665`) | LACKING (`_unlink` from MSVCRT; not in stdlib) |

### L4 — All KEEP across all platforms

All L4 symbols (us_create_loop, us_loop_free, us_loop_run_tick, us_create_poll, us_poll_free,
us_poll_init, us_poll_start, us_poll_change, us_poll_stop, us_poll_ext, us_internal_poll_type,
us_internal_dispatch_ready_poll, all bsd_* and pn_* symbols) are KEEP on all platforms.

Rationale: these are compound operations, custom lifecycle management, or C-level glue that
has no direct Zig stdlib equivalent. Individual OS primitives within them can be replaced,
but the L4 boundary functions themselves cannot.

### L5 — Platform comparison

| OS primitive | Linux | macOS | Windows |
|---|---|---|---|
| epoll_create1 | REPLACE_WITH_STD | N/A | LACKING (wepoll) |
| epoll_wait | REPLACE_WITH_STD | N/A | LACKING (wepoll) |
| epoll_ctl | REPLACE_WITH_STD | N/A | LACKING (wepoll) |
| timerfd_create | REPLACE_WITH_STD | N/A | LACKING |
| timerfd_settime | REPLACE_WITH_STD | N/A | LACKING |
| eventfd | REPLACE_WITH_STD | N/A | LACKING |
| kqueue | N/A | REPLACE_WITH_STD | N/A |
| kevent | N/A | REPLACE_WITH_STD | N/A |
| EVFILT_READ/WRITE/TIMER/USER | N/A | REPLACE_WITH_STD | N/A |
| EV flags (EOF/ERROR/ADD/DELETE) | N/A | REPLACE_WITH_STD | N/A |
| NOTE_TRIGGER | N/A | REPLACE_WITH_STD | N/A |
| socket | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| bind | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| listen | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| accept/accept4 | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| connect | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| send | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| recv | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| shutdown | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| close/closesocket | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| fcntl(O_NONBLOCK) | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING (ioctlsocket) |
| F_SETNOSIGPIPE | N/A | REPLACE_WITH_STD | N/A |
| setsockopt | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| getsockopt | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| getsockname | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| getpeername | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| nanosleep | REPLACE_WITH_STD | REPLACE_WITH_STD | N/A |
| Sleep(ms) | N/A | N/A | LACKING |
| select | LACKING | LACKING | LACKING |
| unlink | REPLACE_WITH_STD | REPLACE_WITH_STD | LACKING |
| WSAStartup/WSACleanup | N/A | N/A | LACKING |
| WSAGetLastError | N/A | N/A | LACKING |
| AF_UNIX/sockaddr_un | N/A | N/A | REPLACE_WITH_STD |

---

## Missing Pieces

1. **Windows Winsock bindings absent from stdlib.** `std.os.windows.ws2_32.zig` contains
   only constants and types. No function bindings (`socket`, `bind`, `listen`, `accept`,
   `connect`, `send`, `recv`, `closesocket`, `ioctlsocket`, `setsockopt`, `getsockopt`,
   `getsockname`, `getpeername`, `select`, `WSAStartup`, `WSACleanup`, `WSAGetLastError`)
   are declared in the stdlib. The stdlib `Io.Threaded` accesses Windows networking through
   AFD (`openSocketAfd` in `Io/Threaded.zig`) rather than Winsock directly, and that path
   is not public API.

2. **wepoll has no stdlib equivalent.** On Windows, uSockets uses the third-party `wepoll`
   library (`g41797/wepoll` fork) to emulate epoll over Windows AFD/IOCP. Zig 0.16 stdlib
   has no epoll emulation layer for Windows. The stdlib Windows path uses AFD internally
   through `Io.Uring` (io_uring style via IOCP), not through an epoll surface.

3. **`select` is absent.** Linux: only `poll`/`ppoll` wrappers in `std.posix` (line 1003).
   macOS/Windows: no `select` C extern in stdlib either. `pn_wait_writable` uses `select`
   to detect non-blocking connect completion; this would require a direct libc call or a
   manual extern declaration if replaced.

4. **`Sleep(ms)` for Windows.** No `kernel32.Sleep` extern in `std.os.windows.kernel32.zig`
   (the file exists but contains different Win32 APIs). `thread_sleep_ms` on Windows calls
   `Sleep` from `pn_utils.c`. Replacement would require a manual extern declaration.

5. **`_unlink` for Windows.** MSVCRT `_unlink` has no stdlib binding. `std.Io.Dir.deleteFile`
   is the stdlib equivalent but requires an async `Io` context.

6. **NOTE_TRIGGER absence on non-macOS.** `std.c.NOTE.TRIGGER` is defined only for macOS
   family (`native_os == .macos` etc.). On Linux/Windows this constant resolves to `void`.
   This is correct since EVFILT_USER is a macOS-only mechanism.

---

## Risk Assessment

**Linux:** Low risk. All L5 OS primitives have stdlib equivalents in `std.os.linux`. The main
gap is `select`, which is used only by `pn_wait_writable` for connect-completion detection.
A direct syscall or libc extern is a one-line addition if needed.

**macOS:** Low risk. All L5 OS primitives have stdlib equivalents in `std.c`. The `select`
gap exists but is minor. All kqueue constants (EVFILT, EV, NOTE) are fully present.

**Windows:** High risk. The entire Winsock layer has no stdlib bindings. Replacing even the
simplest socket operation on Windows would require declaring extern functions manually.
Additionally, wepoll (the core event loop mechanism on Windows) has no stdlib replacement.
Zig 0.16's own Windows networking goes through a completely different path (AFD-based, async
only through `std.Io`), which is incompatible with Tofu's synchronous uSockets-based loop.

**L3/L4 layers:** The posixnet wrapper and uSockets C symbols form a tightly coupled layer.
Replacing them would require rewriting the entire event loop, poll lifecycle, and BSD socket
management in Zig. The stdlib `std.Io.net` provides equivalent high-level functionality, but
its design (async, fiber-based, requires `Io` context) is incompatible with Tofu's current
single-threaded reactor + manual fd registration architecture.

---

## Final Verdict

**Not Currently Replaceable** on Windows.
**Partially Replaceable** on Linux and macOS.

Detailed breakdown:

- **L5 Linux:** Fully replaceable with stdlib. All raw syscalls have `std.os.linux` equivalents.
  Only `select` lacks a direct stdlib binding.
- **L5 macOS:** Fully replaceable with stdlib. All kqueue and socket primitives are in `std.c`.
  Only `select` lacks a binding.
- **L5 Windows:** Not replaceable with stdlib. The Winsock function layer and wepoll have
  no stdlib equivalents. Zig 0.16 stdlib provides Windows networking only through its async
  `Io.Threaded` internal path, which is not accessible as a direct syscall surface.
- **L4 (all platforms):** Not replaceable with stdlib. The uSockets loop, poll, and dispatch
  model has no stdlib analogue. The stdlib `std.Io` provides a different, incompatible
  programming model (async/fiber, not manual fd registration with synchronous wait).
- **L3 (all platforms):** Not replaceable with stdlib. The posixnet wrapper functions
  are purpose-built adapters that combine multiple OS calls with Tofu-specific error
  normalisation and the `pn.Addr` type. `pn.getaddrinfo`/`pn.freeaddrinfo` are the only
  functions with direct stdlib equivalents.
