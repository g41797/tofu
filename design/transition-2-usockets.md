# Transition to usockets: Information Base & Migration Plan

**Status:** Finalized Pre-Design
**Date:** 2026-05-04
**Purpose:** Comprehensive knowledge base for migrating Zig tofu from `std.posix` / `std.net` / `wepoll` to the uSockets C library for Zig 0.16+ compatibility.

---

## 1. Why Migration is Needed

- Zig 0.15.2 is the current base; Zig 0.16+ removes `std.posix` and `std.net` APIs entirely.
- All platform-specific logic is isolated in `src/ampe/[linux|windows|mac|usockets]` to simplify replacement.
- The wepoll C shim used for Windows is also a migration candidate for a unified C-backend via `LIBUS_USE_EPOLL`.

---

## 2. Platform Architecture & Restructuring

### 2.1 Platform Folders and Selection
Tofu uses a `network` build option (`posix` vs `usockets`) to select the backend:
- **Folders:** All OS-dependent code is consolidated under `src/ampe/` in folders: `linux/`, `windows/`, `mac/`, and `usockets/`.
- **Selection Logic:** `build.zig` provides `build_options` to `internal.zig` and `poller.zig`, which perform comptime switches to select the active `Skt` and `Poller` implementations.

### 2.2 PollerCore Design (Must Be Preserved)
The `PollerCore` logic in `src/ampe/poller/core.zig` must survive. It provides:
- **Dual-Map Indirection:** `ChannelNumber → SeqN → *TriggeredChannel`.
- **ABA Protection:** Using monotonic `SeqN` to prevent stale FD reuse issues.
- **Pointer Stability:** `TriggeredChannel` is heap-allocated and its address must remain stable for the kernel (especially on Windows).

### 2.3 Socket Interface (`Skt`)
The `Skt` struct provides the unified interface for all backends.
- **Port Recovery:** `Skt` implements `getPort() ?u16` to retrieve the OS-assigned port (essential for Notifier and testing). In POSIX this uses `getsockname`; in uSockets it uses `us_socket_local_address`.
- **Non-Blocking:** All sockets are strictly non-blocking.

### 2.4 Notifier (Cross-Thread Wakeup)
- **Status:** Moved to `src/ampe/Notifier.zig` as a **platform-independent** component.
- **Decision:** The existing socket-pair mechanism is **retained**. We will not transition to `us_wakeup_loop` for the uSockets backend, as the existing mechanism is proven and now platform-independent.

### 2.5 Triggers Abstraction
- **Packed Intent:** `Triggers` (packed u8) expresses what the Reactor wants (`recv`, `send`, `accept`, etc.).
- **Truncated Mapping:** Platform-specific `triggers.zig` files are truncated to only contain the mapping between `Triggers` and OS-specific event masks (e.g., `EPOLLIN` -> `recv`).

---

## 3. Inventory: Zig tofu’s POSIX/OS Usage

| File | Symbol(s) | Role |
| :--- | :--- | :--- |
| `src/ampe/linux/epoll_backend.zig` | `epoll_create1`, `epoll_ctl`, `epoll_wait` | Linux event loop (Target for replacement) |
| `src/ampe/linux/Skt.zig` | `posix.bind`, `posix.listen`, `posix.accept`, etc. | Sockets (Target for replacement) |
| `src/ampe/linux/SocketCreator.zig` | `posix.socket`, `posix.bind` | Creation (Target for replacement) |
| `src/ampe/linux/triggers.zig` | `EPOLLIN`, `EPOLLOUT`, etc. | Event mapping (Target for replacement) |
| `src/ampe/testHelpers.zig` | (None) | **Platform-Independent** (POSIX items moved to `Skt.zig`) |

---

## 4. Verification Strategy: Platform-Independent Contract Tests

To ensure the uSockets implementation is correct, two key test files have been rewritten to be entirely platform-independent (zero `std.posix` in test code):

1.  **`tests/ampe/Notifier_tests.zig`**: Validates cross-thread notification logic.
2.  **`tests/ampe/sockets_tests.zig`**: A comprehensive contract test suite for `Skt` and `SocketCreator`. 

These tests define the behavioral contract that the uSockets backend must satisfy. They must pass unchanged across all platforms and backends.

---

## 5. Deep uSockets Analysis (vendor/bun-usockets)

### 5.1 The "Tick" Reactor Model
Bun mirrors tofu's Reactor model by using `us_loop_run_bun_tick(loop, timeout)`. 
- **Control:** The Zig layer remains the primary driver, calling `tick()` to execute a single iteration.
- **Windows Strategy ("Forced Epoll"):** Tofu will compile uSockets with `LIBUS_USE_EPOLL` on Windows to utilize `wepoll`. This requires Tofu to provide thin C shim headers (`sys/epoll.h`, `sys/timerfd.h`, `sys/eventfd.h`) and emulated function implementations in `src/ampe/windows/shims/`.

### 5.2 The "Hook-Back" Pattern
1.  **Poll Creation:** Each `TriggeredChannel` creates a `us_poll_t` with type `POLL_TYPE_CALLBACK`.
2.  **Context Binding:** The `*TriggeredChannel` pointer is stored in the poll's extension memory (`ext_size`).
3.  **The Bounce:** OS events trigger a static C callback (Zig shim) which retrieves the `*TriggeredChannel` and updates its `act` triggers.

---

## 6. Architectural Decision: The Hybrid "Pull" Model & Backpressure

To preserve tofu's unique Reactor architecture (L2-L5 layers) and pool-based backpressure:

- **Constraint:** Tofu will **NOT** use uSockets' high-level `us_socket_t`. The high-level loop implementation automatically calls an internal **`bsd_recv`** (which wraps the standard `recv` syscall) into a shared buffer *before* invoking callbacks, which would bypass Tofu's backpressure.
- **Mechanism:** Tofu utilizes the lower-level **`us_poll_t`** with type `POLL_TYPE_CALLBACK`. 
- **Backpressure Guarantee:** When an `EPOLLIN` event occurs on a `us_poll_t`, uSockets invokes the `us_poll_cb` **without performing any I/O**. This prevents the automatic `bsd_recv` call and allows Tofu to maintain the data in the kernel buffer until a message container is successfully retrieved from the pool.
- **Flow:**
    1. `us_loop_run_bun_tick` executes.
    2. Zig shim (`us_poll_cb`) is triggered; it **only** updates the `tc.act` bitmask.
    3. Loop returns; Tofu enters Phase 7 ("Dispatch I/O").
    4. **Manual Read/Write:** Tofu retrieves the raw FD via `us_poll_fd(p)` and performs manual I/O calls. To maintain platform independence and simplify implementation, Tofu uses uSockets' internal **`bsd_recv`** and **`bsd_send`** wrappers.
- **Advantage of `bsd_recv`/`bsd_send`:** 
    - Handles `EINTR` retries automatically.
    - Abstractions over platform-specific socket types (`int` vs `SOCKET`).
    - Eliminates the need for raw Zig syscalls in the Skt implementation.

---

## 7. Master Mapping Tables

### 7.1 Low-Level Socket Cycle

| Zig Tofu / `std.posix` | uSockets / OS Analog | Description |
| :--- | :--- | :--- |
| `posix.socket` | `us_socket_group_listen` / `connect` | Creation is part of the request. |
| `posix.bind` / `posix.listen` | `us_socket_group_listen` | Combined into a single call. |
| `posix.accept` | `on_open` callback | Marks readiness; Tofu accepts manually if needed. |
| `posix.send` | **`bsd_send`** | **Direct Mapping** (uSockets wrapper). Handles `EINTR`. |
| `posix.recv` | **`bsd_recv`** | **Direct Mapping** (uSockets wrapper). Handles `EINTR`. |
| `posix.close` | `us_socket_close` | Unified close; support for reset/abort (code `1`). |

### 7.2 High-Level Functionality Mapping

| Tofu Zig Requirement | uSockets Equivalent | Notes |
| :--- | :--- | :--- |
| **IP Resolution** | `Bun__addrinfo_get` | Bun-specific DNS extension. |
| **Loop Wakeup** | `Notifier` | Socket-pair mechanism is retained. |
| **OS Wait** | `us_loop_run_bun_tick` | Single-iteration drive. |

---

## 8. Key Constraints (Non-Negotiable)

- **Reactor model is mandatory.** Single-threaded, non-inverted control.
- **Pointer stability is mandatory.** `TriggeredChannel` must remain heap-allocated.
- **ABA protection is mandatory.** `SeqN` dual-map must be preserved.
- **Abortive close is mandatory on Windows.** `SO_LINGER=0` via close code `1`.
- **Primary Platform:** Linux is the primary platform for implementation and debugging.
- **Verification Sequence:** Linux → Windows → macOS → Linux (Sandwich rule).
- **4-mode testing required:** Debug, ReleaseSafe, ReleaseFast, ReleaseSmall.

---

## 9. Appendix: Detailed OS Dependency Mapping (Linux)

### 9.1 `src/ampe/linux/epoll_backend.zig`

| OS Dependency | uSockets Analog |
| :--- | :--- |
| `epoll_create1` | `us_create_loop` (managed by Poller instance) |
| `epoll_ctl` (ADD/MOD/DEL) | `us_poll_init` / `us_poll_change` / `us_poll_stop` |
| `epoll_wait` | `us_loop_run_bun_tick` |
| `epoll_event` / `data.u64` | `us_poll_t` + `ext` memory (Hook-Back context recovery) |

### 9.2 `src/ampe/linux/Skt.zig`

| OS Dependency | uSockets Analog |
| :--- | :--- |
| `socket` + `bind` + `listen` | `us_socket_group_listen` / `us_socket_group_listen_unix` |
| `accept` / `accept4` | `on_open` callback registered with `us_socket_group` |
| `connect` | `us_socket_group_connect` / `us_socket_group_connect_unix` |
| `setsockopt` (REUSEPORT, REUSEADDR) | Managed internally by `us_socket_group` |
| `setsockopt` (TCP_NODELAY) | `us_socket_nodelay(s, 1)` |
| `setsockopt` (SO_LINGER=0) | `us_socket_close(s, 1)` (Reset flag triggers abortive close) |
| `getsockname` | `us_socket_local_address` |
| `send` / `recv` | **`bsd_send` / `bsd_recv`** |
| `close` | `us_socket_close` |
| `posix.E` (Errno) | **OS Shim** (Maps C `errno` to AmpeError) |

### 9.3 `src/ampe/linux/SocketCreator.zig`

| OS Dependency | uSockets Analog |
| :--- | :--- |
| `std.net.Address.resolveIp` | `Bun__addrinfo_get` |
| `getAddressList` (DNS) | `us_socket_group_connect` (Handles IP list internally) |
| `initUnix` (UDS) | `us_socket_group_listen_unix` / `connect_unix` |
| `posix.socket` (STREAM) | Implicit in `us_socket_group` type |
| `SOCK.NONBLOCK` / `CLOEXEC` | Mandatory/Implicit in all uSockets handles |

### 9.4 `src/ampe/linux/triggers.zig`

| OS Item | uSockets / Shim Usage | tofu.Triggers Analog |
| :--- | :--- | :--- |
| `EPOLLIN` | `LIBUS_SOCKET_READABLE` | `recv`, `accept`, `notify` |
| `EPOLLOUT` | `LIBUS_SOCKET_WRITABLE` | `send`, `connect` |
| `EPOLLERR` / `EPOLLHUP` | Passed as `error` to `us_poll_cb` | `err` |
| `CTL_ADD` / `CTL_MOD` / `CTL_DEL` | `us_poll_init` / `change` / `stop` | Registration Logic |

---

## 10. Remaining Platform Dependencies

Despite the uSockets abstraction, the following logic remains OS-specific and will be housed in platform folders:

| Area | Platform Dependency |
| :--- | :--- |
| **Error Recovery** | Mapping platform error codes (`errno` vs `WSAGetLastError`) to `AmpeError`. |
| **Lifecycle** | `WSAStartup`/`WSACleanup` (Windows only). |
| **UDS** | Abstract namespace (Linux only); path deletion constraints (Unix vs Windows). |
| **Build** | **"Forced Epoll" on Windows:** Tofu will provide thin C shim headers (`sys/epoll.h`, `sys/timerfd.h`, `sys/eventfd.h`) and emulated implementations in `src/ampe/windows/shims/` to satisfy the uSockets Linux backend while utilizing `wepoll`. |
| **Triggers** | Mapping `LIBUS_SOCKET_READABLE/WRITABLE` to OS bits. |

---

*End of migration plan.*
