# Tofu Networking Architecture Map

## Overview

Tofu is an async message-passing library over TCP and Unix Domain Sockets (UDS). Its networking stack has five layers. The public API exposes vtable-based `Ampe` and `ChannelGroup` interfaces. Below that sits a single-threaded `Reactor` that owns a `Poller` and a `Notifier`. The `Poller` selects its backend at compile time: either `stdposix` (Zig stdlib + raw syscalls, Linux/macOS/Windows) or `posixnet` (C adapter over the `g41797/uSockets` fork). The `posixnet` path is the active default (`build.zig` line 42: `const network = .posixnet`). Below `posixnet` sits the uSockets C library, which calls OS-level event APIs: `epoll` on Linux, `kqueue` on macOS, and `wepoll` (epoll emulation) on Windows.

---

## Layer Map (top to bottom)

### Layer 1: Public API

Root module: `src/tofu.zig`. Exported from this file:

| Symbol | Kind | File:line |
|---|---|---|
| `Ampe` | struct (vtable-based) | `src/ampe.zig:4` |
| `ChannelGroup` | struct (vtable-based) | `src/ampe.zig:75` |
| `Options` | struct | `src/ampe.zig:152` |
| `DefaultOptions` | const | `src/ampe.zig:157` |
| `AllocationStrategy` | enum | `src/ampe.zig:70` |
| `Message` | struct | `src/message.zig` (re-exported) |
| `BinaryHeader` | struct | `src/message.zig` (re-exported) |
| `OpCode` | enum | `src/message.zig` (re-exported) |
| `AmpeStatus` | enum | `src/status.zig:4` |
| `AmpeError` | error set | `src/status.zig:41` |
| `address` | namespace | `src/address.zig` |
| `Reactor` | struct | `src/ampe/Reactor.zig` |

User entry points on `Ampe`:

- `Ampe.get(strategy)` — get a `Message` from the pool (`src/ampe.zig:14`)
- `Ampe.put(msg)` — return a `Message` to the pool (`src/ampe.zig:27`)
- `Ampe.create()` — create a `ChannelGroup` (one connected pair of sockets) (`src/ampe.zig:46`)
- `Ampe.destroy(chnls)` — abort communication and free the `ChannelGroup` (`src/ampe.zig:55`)

User entry points on `ChannelGroup`:

- `ChannelGroup.post(msg)` — submit a message for async send (`src/ampe.zig:97`)
- `ChannelGroup.waitReceive(timeout_ns)` — blocking receive with timeout (`src/ampe.zig:121`)
- `ChannelGroup.updateReceiver(update)` — wake or notify the receive-side thread (`src/ampe.zig:144`)

Address types in `src/address.zig`:

- `TCPClientAddress` — host + port for outbound TCP (`src/address.zig:26`)
- `TCPServerAddress` — IP + port for TCP listen (`src/address.zig:93`)
- `UDSClientAddress` — filesystem path for UDS connect (`src/address.zig:162`)
- `UDSServerAddress` — filesystem path for UDS listen (`src/address.zig:209`)
- `Address` — tagged union over the four types above (`src/address.zig:261`)

Address is serialized into `Message` text headers with keys `~connect_to` and `~listen_on` (`src/address.zig:22`-`23`). Format: `"tcp|host|port"` or `"uds|/path"`.

Test/utility helpers exported from `src/tofu.zig`:

- `TempUdsPath` — generates temp UDS path via libc `getenv`/`getpid` (Unix) or `GetTempPathA`/`GetCurrentProcessId` (Windows) (`src/ampe/helpers.zig:14`)
- `FindFreeTcpPort` — binds to port 0 to find a free port (`src/ampe/helpers.zig:52`)
- `SleepMlsec` — calls `pn.thread_sleep_ms` (posixnet) or `std.Thread.sleep` (stdposix) (`src/ampe/helpers.zig:83`)
- `DestroyChannels`, `RunTasks`, `AutoArrayHashMap` — test utilities

---

### Layer 2: Internal Tofu Layers

#### 2a. Reactor (`src/ampe/Reactor.zig`)

The `Reactor` is the concrete implementation behind the `Ampe` vtable. It runs one background thread. Key fields:

| Field | Type | Purpose |
|---|---|---|
| `pool` | `Pool` | Message pool (heap-allocated `Message` objects) |
| `ntfr` | `Notifier` | Cross-thread wakeup channel |
| `ptcs` | `?Poller` | OS event loop (epoll/kqueue/wepoll/uSockets) |
| `acns` | `ActiveChannels` | Map of live channel groups |
| `chnlsGroup_map` | `ChannelsGroupMap` | Group-to-channels lookup |
| `loopTrgrs` | `Triggers` | Accumulated trigger flags per reactor tick |

`Reactor.create` (`src/ampe/Reactor.zig:68`) allocates the struct, initializes the pool, calls `internal.initPlatform()`, and spawns the reactor thread.

`Reactor.destroy` (`src/ampe/Reactor.zig:130`) sets `shutdownFlag`, sends a shutdown alert via `Notifier`, waits for the reactor thread to join, then calls `internal.deinitPlatform()`.

#### 2b. Poller selector (`src/ampe/poller.zig`)

Selects the backend at compile time (`src/ampe/poller.zig:10`-`17`):

```
pub const Poller = if (build_options.network == .posixnet)
    posixnet_backend.Poller
else switch (builtin.os.tag) {
    .windows => wepoll_backend.Poller,
    .linux   => epoll_backend.Poller,
    .macos   => kqueue_backend.Poller,
    else     => @compileError(...)
};
```

All `Poller` types are produced by `PollerCore(Backend)` (`src/ampe/core.zig:15`). `PollerCore` is a generic that composes with any backend implementing `init`, `deinit`, `register`, `modify`, `unregister`, `wait`.

#### 2c. PollerCore (`src/ampe/core.zig`)

Manages two maps:

- `chn_seqn_map: ChnSeqnMap` — ChannelNumber → SeqN (`src/ampe/core.zig:238`)
- `seqn_trc_map: SeqnTrcMap` — SeqN → `*TriggeredChannel` (`src/ampe/core.zig:239`)

`waitTriggers` (`src/ampe/core.zig:163`) reconciles expected vs actual triggers, then calls `backend.wait(timeout, &seqn_trc_map)`.

`attachChannel` (`src/ampe/core.zig:46`) registers a new socket fd with the backend.

`deleteMarked` (`src/ampe/core.zig:98`) removes channels flagged for deletion and calls `backend.unregister`.

#### 2d. TriggeredSkt / Triggers (`src/ampe/triggeredSkts.zig`)

`Triggers` is a packed `u8` struct with eight 1-bit flags: `notify`, `accept`, `connect`, `send`, `recv`, `pool`, `err`, `timeout` (`src/ampe/triggeredSkts.zig:4`-`8`).

`IoSkt` wraps a `Skt` and a pool reference. It holds the in-flight receive and send state. `IoSkt.tryRecv` and `IoSkt.trySend` are called by the reactor loop on each triggered socket.

#### 2e. Internal selector (`src/ampe/internal.zig`)

Selects `Skt` and `SocketCreator` at compile time based on `build_options.network` and `builtin.os.tag` (`src/ampe/internal.zig:6`-`41`). Exports `initPlatform` / `deinitPlatform` which call either WSAStartup/WSACleanup (stdposix Windows) or `pn.startup_sockets`/`pn.cleanup_sockets` (posixnet) (`src/ampe/internal.zig:45`-`67`).

#### 2f. Notifier (`src/ampe/Notifier.zig`)

Platform-independent. Creates a connected socket pair (TCP loopback or UDS) to wake the reactor thread from application threads. On Linux, tries UDS with abstract namespace (leading `\0`); falls back to TCP loopback. On Windows, always uses TCP loopback (`src/ampe/Notifier.zig:54`-`60`).

`sendNotification` sends one byte (packed `Notification`) to the reactor thread (`src/ampe/Notifier.zig:107`). `recvNotification` receives it (`src/ampe/Notifier.zig:116`).

---

### Layer 3: posixnet Layer

Location: `src/platform/posixnet/` and `src/platform/posixnet/wrapper/`.

#### 3a. Per-OS Skt (socket abstraction)

Three files, one per OS:

| File | OS |
|---|---|
| `src/platform/posixnet/linux/Skt.zig` | Linux |
| `src/platform/posixnet/mac/Skt.zig` | macOS |
| `src/platform/posixnet/windows/Skt.zig` | Windows |

The macOS and Linux files are structurally identical. Key `Skt` struct fields (Linux example, `src/platform/posixnet/linux/Skt.zig:8`-`10`):

```zig
fd: pn.Fd = pn.INVALID_FD,
address: pn.Addr = std.mem.zeroes(pn.Addr),
server: bool = false,
```

`Skt` methods that call into `pn` (posix_net wrapper):

| Method | Calls | File:line |
|---|---|---|
| `accept` | `pn.acceptSocket`, `pn.setLingerAbort` | `linux/Skt.zig:37` |
| `connect` | `pn.connectSocketUnix` or `pn.connectSocket` | `linux/Skt.zig:50` |
| `sendBuf` | `pn.sendBuf` | `linux/Skt.zig:92` |
| `recvToBuf` | `pn.recvToBuf` | `linux/Skt.zig:96` |
| `close` | `pn.closeSocket` | `linux/Skt.zig:104` |
| `disableNagle` | `pn.nodelay` | `linux/Skt.zig:73` |
| `setLingerAbort` | `pn.setLingerAbort` | `linux/Skt.zig:69` |
| `getPort` | `pn.localAddr`, `pn.addrPort` | `linux/Skt.zig:28` |

#### 3b. Per-OS SocketCreator

Three files:

| File | OS |
|---|---|
| `src/platform/posixnet/linux/SocketCreator.zig` | Linux |
| `src/platform/posixnet/mac/SocketCreator.zig` | macOS |
| `src/platform/posixnet/windows/SocketCreator.zig` | Windows |

`SocketCreator.parse` reads an `Address` from a `Message` and calls `fromAddress` (`linux/SocketCreator.zig:25`). `fromAddress` dispatches to one of four creators:

- `createTcpServer` → calls `resolveAddr` (via `pn.getaddrinfo`) then `pn.createListenSocketFromSockaddr` (`linux/SocketCreator.zig:41`)
- `createTcpClient` → calls `resolveAddr` then `pn.createClientSocket` (`linux/SocketCreator.zig:50`)
- `createUdsServer` / `createUdsListener` → calls `pn.createListenSocketUnix` + `pn.initAddrUnix` (`linux/SocketCreator.zig:59`-`76`)
- `createUdsClient` / `createUdsSocket` → calls `pn.createClientSocket` (`linux/SocketCreator.zig:78`-`85`)

`resolveAddr` (`linux/SocketCreator.zig:102`) calls `pn.getaddrinfo` (libc) then copies the result into a `pn.Addr`. Handles empty host (wildcard `0.0.0.0`).

#### 3c. posixnet_backend (Poller backend)

File: `src/platform/posixnet/posixnet_backend.zig`.

`PosixNetBackend` struct fields (`src/platform/posixnet/posixnet_backend.zig:63`-`67`):

```zig
loop: *anyopaque,   // uSockets loop handle
polls: PollMap,     // fd → poll handle map
allocator: Allocator,
```

Key operations:

| Method | Calls | File:line |
|---|---|---|
| `init` | `pn.poll.createLoop` | `posixnet_backend.zig:68` |
| `register` | `pn.poll.createPoll`, `pn.poll.initPoll`, `pn.poll.startPoll` | `posixnet_backend.zig:101` |
| `modify` | `pn.poll.changePoll` | `posixnet_backend.zig:115` |
| `unregister` | `pn.poll.stopPoll`, `pn.poll.freePoll` | `posixnet_backend.zig:122` |
| `wait` | `pn.poll.tick` | `posixnet_backend.zig:129` |
| `deinit` | `pn.poll.freeLoop` | `posixnet_backend.zig:80` |

The backend exports `us_internal_dispatch_ready_poll` as a C symbol (`src/platform/posixnet/posixnet_backend.zig:43`) to override the weak symbol in uSockets. This is the dispatch hook: uSockets calls it for each ready fd, and the backend looks up the `TriggeredChannel` by SeqN and sets trigger flags.

Thread-local state: `g_loop` (the uSockets loop handle) and `g_wait_state` (the in-progress wait context) are declared `threadlocal` (`src/platform/posixnet/posixnet_backend.zig:23`, `30`).

#### 3d. Trigger mapping (`src/platform/posixnet/triggers.zig`)

`usockets.toEvents(exp)` maps `Triggers` to `LIBUS_SOCKET_READABLE | LIBUS_SOCKET_WRITABLE` bitmasks (`triggers.zig:6`-`13`).

`usockets.fromEvents(events, err, exp)` maps uSockets event bits back to `Triggers` (`triggers.zig:15`-`41`). On macOS/BSD, `EV_ERROR=0x4000` and `EV_EOF=0x8000` are handled separately from the Linux epoll error path.

#### 3e. posix_net wrapper module

Module root: `src/platform/posixnet/wrapper/posix_net.zig`.

Sub-files:

| File | Contents |
|---|---|
| `wrapper/types.zig` | `Fd`, `Addr`, `SockaddrIn/In6/Un`, address family constants, `initAddrUnix`, `initAddrIp4` |
| `wrapper/ffi.zig` | `extern` declarations for all bsd_ / pn_ / us_ C functions; `addrinfo` struct variants |
| `wrapper/socket.zig` | Safe Zig wrappers: `sendBuf`, `recvToBuf`, `acceptSocket`, `connectSocket`, `closeSocket`, `nodelay`, `keepalive`, `localAddr`, `remoteAddr`, `addrFamily`, `addrPort`, `addrUnixPath` |
| `wrapper/creator.zig` | `createSocket`, `createClientSocket`, `createListenSocket`, `createListenSocketUnix`, `createConnectSocketUnix`, `createListenSocketFromSockaddr`, `findFreeTcpPort`, `resolveConnect` |
| `wrapper/poll.zig` | Wrappers for `us_create_loop`, `us_loop_free`, `us_create_poll`, `us_poll_*`, `us_loop_run_tick`, `us_internal_poll_type` |

`Addr` is an opaque 128-byte buffer (`sockaddr_storage` equivalent) plus metadata (`wrapper/types.zig:25`-`31`). All socket addresses flow through `Addr`, not `std.net.Address` (removed in Stage 6).

`addrFamily` reads the address family byte from `Addr.mem`. On macOS/BSD, reads `mem[1]` (`sa_family` in BSD sockaddr layout). On Linux/Windows, reads `mem[0..2]` as `u16 LE` (`wrapper/socket.zig:117`-`126`).

`initAddrUnix` writes the BSD vs Linux/Windows sockaddr layout difference at `mem[0..2]` (`wrapper/types.zig:57`-`73`).

---

### Layer 4: uSockets Interface

The uSockets fork is declared as a Zig package dependency in `build.zig.zon` (`build.zig.zon:17`-`20`):

```
.usockets = .{
    .url = "git+https://github.com/g41797/uSockets.git#master",
    .hash = "N-V-__8AALwjBgA3LAMIs1wy-EY8ATSedwDeOKjPRG8U1K18",
},
```

The cached snapshot is at: `zig-pkg/N-V-__8AALwjBgA3LAMIs1wy-EY8ATSedwDeOKjPRG8U1K18/`.

C source files compiled into the library (`build.zig:107`-`121`):

| File | Purpose |
|---|---|
| `src/bsd.c` | BSD networking wrappers |
| `src/context.c` | uSockets context/loop data init |
| `src/loop.c` | Loop lifecycle |
| `src/socket.c` | Socket I/O |
| `src/udp.c` | UDP (not used by Tofu, compiled anyway) |
| `src/eventing/epoll_kqueue.c` | Linux/macOS event loop (not on Windows) |
| `src/platform/posixnet/wrapper/adapters/us_epoll_win.c` | Windows event loop (wepoll-backed) |
| `src/platform/posixnet/wrapper/adapters/pn_utils.c` | Tofu-specific C utilities |

Include paths (`build.zig:115`-`117`):

- `src/` (for `libusockets.h`)
- `src/internal` (for `internal.h`)
- `src/internal/networking` (for `bsd.h`)

Compile flags: `-fno-sanitize=undefined -DLIBUS_NO_SSL -DLIBUS_USE_EPOLL` (Linux) or `-DLIBUS_USE_KQUEUE` (macOS) (`build.zig:103`-`104`).

#### All uSockets symbols called by Tofu

**From `wrapper/ffi.zig` — event loop and polling:**

| Symbol | Declared at | Called from |
|---|---|---|
| `us_create_loop` | `ffi.zig:46` | `poll.zig:11` → `posixnet_backend.zig:71` |
| `us_loop_free` | `ffi.zig:47` | `poll.zig:14` → `posixnet_backend.zig:89` |
| `us_create_poll` | `ffi.zig:48` | `poll.zig:19` → `posixnet_backend.zig:101` |
| `us_poll_free` | `ffi.zig:49` | `poll.zig:24` → `posixnet_backend.zig:83,127` |
| `us_poll_init` | `ffi.zig:50` | `poll.zig:29` → `posixnet_backend.zig:102` |
| `us_poll_start` | `ffi.zig:51` | `poll.zig:34` → `posixnet_backend.zig:107` |
| `us_poll_change` | `ffi.zig:52` | `poll.zig:39` → `posixnet_backend.zig:97,119` |
| `us_poll_stop` | `ffi.zig:53` | `poll.zig:44` → `posixnet_backend.zig:83,126` |
| `us_poll_ext` | `ffi.zig:54` | `poll.zig:49` → `posixnet_backend.zig:48,104` |
| `us_loop_run_tick` | `ffi.zig:55` | `poll.zig:54` → `posixnet_backend.zig:137` |
| `us_internal_poll_type` | `ffi.zig:56` | `poll.zig:61` → `posixnet_backend.zig:46` |

**Overridden weak symbol (exported from Zig):**

| Symbol | Declared at | Purpose |
|---|---|---|
| `us_internal_dispatch_ready_poll` | `posixnet_backend.zig:43` | Called by `us_loop_run_tick` for each ready fd; Zig side overrides the uSockets weak definition |

**From `wrapper/ffi.zig` — BSD socket operations:**

| Symbol | Declared at |
|---|---|
| `bsd_set_linger_abort` | `ffi.zig:11` |
| `bsd_create_listen_socket` | `ffi.zig:25` |
| `bsd_create_listen_socket_unix` | `ffi.zig:26` |
| `bsd_create_socket` | `ffi.zig:27` |
| `bsd_connect_socket_unix` | `ffi.zig:28` |
| `bsd_accept_socket` | `ffi.zig:29` |
| `bsd_recv` | `ffi.zig:30` |
| `bsd_send` | `ffi.zig:31` |
| `bsd_close_socket` | `ffi.zig:32` |
| `bsd_shutdown_socket` | `ffi.zig:33` |
| `bsd_shutdown_socket_read` | `ffi.zig:34` |
| `bsd_set_nonblocking` | `ffi.zig:35` |
| `bsd_socket_nodelay` | `ffi.zig:36` |
| `bsd_socket_keepalive` | `ffi.zig:37` |
| `bsd_would_block` | `ffi.zig:38` |
| `bsd_addr_get_port` | `ffi.zig:39` (declared but not called; `addrPort` is pure-Zig) |
| `bsd_local_addr` | `ffi.zig:40` |
| `bsd_remote_addr` | `ffi.zig:41` |
| `bsd_addr_get_ip` | `ffi.zig:42` (declared, not currently called) |
| `bsd_addr_get_ip_length` | `ffi.zig:43` (declared, not currently called) |

**From `wrapper/ffi.zig` — pn_utils.c functions:**

| Symbol | Declared at | Purpose |
|---|---|---|
| `pn_create_listen_socket` | `ffi.zig:12` | TCP listen with explicit backlog |
| `pn_create_listen_socket_unix` | `ffi.zig:13` | UDS listen with explicit backlog |
| `pn_create_connect_socket_unix` | `ffi.zig:14` | UDS non-blocking connect |
| `pn_wait_writable` | `ffi.zig:15` | Wait for non-blocking connect completion via `select` |
| `pn_connect_socket` | `ffi.zig:16` | TCP non-blocking connect on existing fd |
| `pn_create_listen_socket_from_sockaddr` | `ffi.zig:17` | TCP listen from pre-built sockaddr |

**From `wrapper/ffi.zig` — platform utilities:**

| Symbol | Declared at | Purpose |
|---|---|---|
| `thread_sleep_ms` | `ffi.zig:20` | Millisecond sleep (`nanosleep` on POSIX, `Sleep` on Windows) |
| `startup_sockets` | `ffi.zig:21` | WSAStartup on Windows, no-op on POSIX |
| `cleanup_sockets` | `ffi.zig:22` | WSACleanup on Windows, no-op on POSIX |
| `unlink` | `ffi.zig:59` | Delete UDS path file (POSIX) |
| `_unlink` | `ffi.zig:60` | Delete UDS path file (Windows) |

**DNS resolution (libc — not from uSockets):**

| Symbol | Declared at | Purpose |
|---|---|---|
| `getaddrinfo` | `ffi.zig:105` | Resolve host/port to sockaddr |
| `freeaddrinfo` | `ffi.zig:106` | Free getaddrinfo result |

---

### Layer 5: OS Primitives

#### Linux

Used by `src/eventing/epoll_kqueue.c` (compiled with `-DLIBUS_USE_EPOLL`):

| Syscall/function | Where in C source | Purpose |
|---|---|---|
| `epoll_create1(EPOLL_CLOEXEC)` | `epoll_kqueue.c:108` | Create epoll instance |
| `epoll_wait(loop->fd, ...)` | `epoll_kqueue.c:127`, `487` | Wait for ready fds |
| `epoll_ctl(EPOLL_CTL_ADD, ...)` | `epoll_kqueue.c:237` | Register fd |
| `epoll_ctl(EPOLL_CTL_MOD, ...)` | `epoll_kqueue.c:251` | Modify fd events |
| `epoll_ctl(EPOLL_CTL_DEL, ...)` | `epoll_kqueue.c:267` | Unregister fd |
| `timerfd_create(CLOCK_REALTIME, ...)` | `epoll_kqueue.c:295` | Create timer fd |
| `timerfd_settime(...)` | `epoll_kqueue.c:349` | Arm timer |
| `eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)` | `epoll_kqueue.c:380` | Create wakeup fd |
| `write(eventfd, &one, 8)` | `epoll_kqueue.c:411` | Wakeup async notify |
| `read(fd, &buf, 8)` | `epoll_kqueue.c:282` | Drain timer/eventfd |
| `close(fd)` | `epoll_kqueue.c:43`, `333`, `395` | Close epoll/timerfd/eventfd |

Used by `src/bsd.c` on Linux:

| Syscall/function | Purpose |
|---|---|
| `socket(AF, SOCK_STREAM, 0)` | Create TCP/UDS fd |
| `bind`, `listen` | Bind and listen |
| `accept4(SOCK_NONBLOCK | SOCK_CLOEXEC)` | Accept with non-blocking flag |
| `connect` | Non-blocking connect |
| `send` / `recv` | Socket I/O |
| `shutdown` | Half-close |
| `close` | Close socket |
| `fcntl(O_NONBLOCK)` | Set non-blocking mode |
| `setsockopt(SO_REUSEADDR, SO_REUSEPORT, TCP_NODELAY, SO_LINGER, SO_KEEPALIVE)` | Socket options |
| `getsockname`, `getpeername` | Get local/remote address |
| `nanosleep` | Sleep in `pn_utils.c` |
| `select` | Wait for writable in `pn_wait_writable` |
| `unlink` | Delete UDS socket file |

Also used by `pn_utils.c`:

| Function | Purpose |
|---|---|
| `listen(fd, backlog)` | Called after `bsd_create_listen_socket` to apply explicit backlog |
| `bind` | Direct bind from pre-built sockaddr in `pn_create_listen_socket_from_sockaddr` |
| `setsockopt(SO_REUSEADDR, SO_REUSEPORT)` | Set before bind in `pn_create_listen_socket_from_sockaddr` |
| `getsockopt(SO_ERROR)` | Check connect result in `pn_wait_writable` |

#### macOS

Used by `src/eventing/epoll_kqueue.c` (compiled with `-DLIBUS_USE_KQUEUE`):

| Syscall/function | Where in C source | Purpose |
|---|---|---|
| `kqueue()` | `epoll_kqueue.c:110` | Create kqueue instance |
| `kevent(fd, NULL, 0, ready_polls, 1024, NULL)` | `epoll_kqueue.c:129`, `504` | Wait for events |
| `kevent(kqfd, change_list, n, NULL, 0, NULL)` | `epoll_kqueue.c:201` | Add/remove filters |
| `EV_SET + EVFILT_READ/WRITE` | `epoll_kqueue.c:193,198` | Configure read/write filters |
| `EV_SET + EVFILT_TIMER` | `epoll_kqueue.c:371` | Timer |
| `EV_SET + EVFILT_USER + NOTE_TRIGGER` | `epoll_kqueue.c:457` | Async wakeup |

Used by `src/bsd.c` on macOS: same POSIX socket calls as Linux. `accept` uses `accept4` on Linux; on macOS uses `accept` + `fcntl(O_NONBLOCK)` + `apple_no_sigpipe` (`F_SETNOSIGPIPE`).

#### Windows

Tofu uses `wepoll` as an epoll emulation layer over Windows IOCP/AFD.

The `wepoll` package is declared in `build.zig.zon` (`build.zig.zon:21`-`24`):

```
.wepoll = .{
    .url = "git+https://github.com/piscisaureus/wepoll#dist",
    .hash = "N-V-__8AAHdDAQBYE31YD6dB4IlHQ_qqBAEu07X4VB56RL2Q",
},
```

Cached at: `zig-pkg/N-V-__8AAHdDAQBYE31YD6dB4IlHQ_qqBAEu07X4VB56RL2Q/`.

The adapter `src/platform/posixnet/wrapper/adapters/sys/epoll.h` (`epoll.h:1`-`32`) redirects `epoll_create1`, `epoll_ctl`, `epoll_wait` to wepoll functions. `us_epoll_win.c` provides all `us_*` functions using these redirects.

On Windows, `src/bsd.c` uses Winsock2 (`winsock2.h`, `ws2tcpip.h`):

| Winsock function | Purpose |
|---|---|
| `WSAStartup` / `WSACleanup` | Initialize Winsock (`pn_utils.c:213`-`230`) |
| `socket(AF, SOCK_STREAM, 0)` | Create socket |
| `bind`, `listen`, `connect` | Bind, listen, connect |
| `accept` | Accept connection |
| `send`, `recv` | Socket I/O |
| `closesocket` | Close socket |
| `ioctlsocket(FIONBIO)` | Set non-blocking |
| `setsockopt(SO_REUSEADDR, TCP_NODELAY, SO_LINGER, SO_KEEPALIVE)` | Socket options |
| `getsockname`, `getpeername` | Get local/remote address |
| `select` | Wait for writable in `pn_wait_writable` |
| `getsockopt(SO_ERROR)` | Check connect result |
| `WSAGetLastError` | Check last error |
| `Sleep(ms)` | Sleep in `pn_utils.c` |

For UDS on Windows, `pn_utils.c` uses `afunix.h` and `struct sockaddr_un` with `AF_UNIX` (`pn_utils.c:8`-`9`, `pn_utils.c:167`). Requires Windows 10 RS4 (build 17063+), enforced in `build.zig:24`.

---

## Supporting Utilities

### Address Parsing and Representation

Two levels:

1. **High-level (`src/address.zig`):** `Address` union with `TCPClientAddress`, `TCPServerAddress`, `UDSClientAddress`, `UDSServerAddress`. Serialized as text headers in `Message`. Parsed from `~connect_to` and `~listen_on` headers. No OS types used.

2. **Low-level (`src/platform/posixnet/wrapper/types.zig`):** `pn.Addr` — opaque 128-byte buffer (`sockaddr_storage` equivalent) with platform-aware family byte reading. `SockaddrIn`, `SockaddrIn6`, `SockaddrUn` are extern struct overlays. `initAddrUnix` and `initAddrIp4` build `Addr` values directly.

DNS resolution uses `getaddrinfo` / `freeaddrinfo` from libc. The `addrinfo` struct has three layouts depending on platform (`ffi.zig:66`-`103`): `addrinfo_posix` (Linux), `addrinfo_bsd` (macOS/BSD), `addrinfo_win` (Windows), selected at compile time.

### DNS / Hostname Resolution

Resolved via libc `getaddrinfo` called in:

- `src/platform/posixnet/linux/SocketCreator.zig:102` — `resolveAddr` (TCP server and client creation)
- `src/platform/posixnet/wrapper/creator.zig:74` — `resolveConnect` (direct connect utility)

No in-process DNS; all resolution delegated to libc. UDS paths are filesystem paths; no resolution needed.

### Buffer Management

No separate buffer abstraction. Buffers are slices passed directly to `pn.sendBuf` and `pn.recvToBuf`, which call `bsd_send` and `bsd_recv`. In-flight message data lives in heap-allocated `Message` objects managed by `Pool`.

### Timer Mechanisms

No application-level timers in the networking stack. The event loop timeout is passed as an integer (`timeout_ms`) to `us_loop_run_tick` / `pn.poll.tick` (`posixnet_backend.zig:137`). uSockets internally creates `timerfd` (Linux) or kqueue `EVFILT_TIMER` (macOS) for its own timer abstraction, but Tofu does not use `us_create_timer` directly.

`thread_sleep_ms` (`pn_utils.c:201`) is used for retry delays in `Notifier.initPair` and `Pool.init` — not for I/O timeouts.

### Thread Wakeup / Notifier

`src/ampe/Notifier.zig` creates a connected socket pair at startup. Application threads call `sendNotification` to write one byte. The reactor thread has the receiver socket registered with the poller and wakes up when readable.

On Linux, the UDS path uses an abstract namespace socket (first byte `\0`) to avoid filesystem cleanup. Falls back to TCP loopback if UDS fails. On Windows, always TCP loopback (`Notifier.zig:55`-`60`).

### Pool and Allocator

`src/ampe/Pool.zig` — a singly-linked freelist of heap-allocated `Message` objects. Bounded by `maxMsgs`. Uses a `std.Io.Mutex` for thread safety. When the pool goes empty and a message is returned, it signals the reactor via `Notifier.Alerter.send_alert(.freedMemory)`.

`Message` objects are created with `gpa.create(Message)` and destroyed with `gpa.destroy`. The pool tracks count in `currMsgs`.

### Connection Lifecycle

1. `SocketCreator.parse(msg)` reads address from `Message` headers.
2. For TCP client: `resolveAddr` → `pn.createClientSocket` → `Skt.connect()` (non-blocking, returns `false` if in-progress).
3. For TCP server: `resolveAddr` → `pn.createListenSocketFromSockaddr` → listener `Skt`.
4. Socket fd registered with `PollerCore.attachChannel` → `backend.register`.
5. Reactor loop calls `backend.wait` → fires `us_loop_run_tick` → dispatches via `us_internal_dispatch_ready_poll`.
6. Trigger flags set on `TriggeredChannel`. Reactor calls `tryRecv` / `trySend` / `tryAccept` / `tryConnect`.
7. On error or peer disconnect: channel marked for deletion. `deleteMarked` unregisters from backend, closes socket, frees `TriggeredChannel`.

---

## std.posix Usage Verification

**Result: used only in the `stdposix` backend and in two shared type aliases. Not used in the `posixnet` backend or the posix_net wrapper.**

Files with `std.posix` references:

| File | Usage | Note |
|---|---|---|
| `src/platform/stdposix/linux/epoll_backend.zig` | `std.posix.epoll_create1`, `epoll_ctl`, `epoll_wait`, `close` | stdposix backend only; not compiled when `network=posixnet` |
| `src/platform/stdposix/linux/Skt.zig` | `std.posix.socket_t`, `SOCK.*`, `AF.*`, `setsockopt`, `send`, `recv` | stdposix backend only |
| `src/platform/stdposix/linux/SocketCreator.zig` | `const posix = std.posix` alias | stdposix backend only |
| `src/platform/stdposix/mac/triggers.zig` | `std.posix.system.Kevent`, `EVFILT.*`, `EV.*` | stdposix backend only |
| `src/platform/stdposix/mac/Skt.zig` | various `std.posix.*` calls | stdposix backend only |
| `src/platform/stdposix/mac/SocketCreator.zig` | various `std.posix.*` calls | stdposix backend only |
| `src/platform/stdposix/windows/Skt.zig` | `std.posix.socket(AF.INET, SOCK.STREAM, 0)` at line 167 | stdposix Windows only |
| `src/ampe/internal.zig:24` | `std.posix.fd_t` — used as `Socket` type in posixnet path | Type alias only; no syscall |
| `src/ampe/common.zig:56,61` | `std.posix.fd_t` — used in `toFd` and `FdType` | Type alias only; no syscall |

The three non-stdposix occurrences (`internal.zig:24`, `common.zig:56`, `common.zig:61`) use `std.posix.fd_t` only as a type synonym for `i32` (the POSIX fd type). No POSIX API is called through them.

**In the posixnet backend and posix_net wrapper, no `std.posix` API calls exist.** All socket operations go through `bsd_*` and `pn_*` C functions.

---

## Key Observations

1. **posixnet is the hardcoded default.** `build.zig:42` sets `const network = .posixnet` unconditionally. The `stdposix` backend is compiled but not selected unless the line is changed. The commented-out option block (lines 36–41) shows the intent to restore selection in Zig 0.20.

2. **Dual-path patching.** Changes to uSockets C source must be applied in two places: the local fork at `~/dev/root/github.com/g41797/uSockets/src/` and the Zig package cache at `~/.cache/zig/p/N-V-__8AAPIOBgC…/src/`. The cache is what `zig build` actually compiles. See `design/AGENT_STATE.md` for the dual-path protocol.

3. **`us_internal_dispatch_ready_poll` override.** The posixnet backend exports this as a C symbol (`posixnet_backend.zig:43`). uSockets defines it as a weak symbol; the Zig export wins at link time. This gives Tofu full control over event dispatch without a callback registration API.

4. **No `std.net` in the codebase.** All `std.net.Address` usage was removed in Stage 6. `pn.Addr` is the sole address representation. `getaddrinfo`/`freeaddrinfo` are called directly from Zig via `extern` declarations in `ffi.zig`.

5. **Windows event loop is wepoll, not IOCP directly.** `wepoll` wraps Windows AFD (Ancillary Function Driver) to emulate epoll semantics. Tofu does not use IOCP or completion ports directly.

6. **`std.posix.fd_t` as a type alias in shared code.** `common.zig` and `internal.zig` use `std.posix.fd_t` as a type name (equivalent to `i32`) for non-Windows fd values. This is a type definition, not a syscall. It appears in both stdposix and posixnet compilation paths. This is a documentation note, not a violation; the rule prohibits using `std.posix` APIs in new code.

7. **No wakeup via eventfd or pipe.** The `Notifier` uses a socketpair (TCP or UDS) for cross-thread wakeup. The `eventfd` in uSockets is used internally for the `us_internal_async` mechanism, which Tofu does not call.

8. **No DNS beyond getaddrinfo.** There is no custom resolver, no caching, no async DNS. Hostname resolution is synchronous via `getaddrinfo` at socket creation time only.

9. **UDS abstract namespace on Linux.** When `Notifier` creates a UDS pair on Linux, `socket_file[0]` is set to `\0` (`Notifier.zig:83`), making it an abstract namespace socket. These do not appear in the filesystem and need no cleanup. Regular (filesystem) UDS paths used for application-level connections are deleted on server socket close via `deleteUDSPath`.

10. **`bsd_addr_get_port`, `bsd_addr_get_ip`, `bsd_addr_get_ip_length` declared but not called.** `addrPort` is implemented in pure Zig in `socket.zig:130`. `bsd_addr_get_ip` and `bsd_addr_get_ip_length` are declared in `ffi.zig` but have no call sites in `socket.zig` or `creator.zig`. They remain available for future use.
