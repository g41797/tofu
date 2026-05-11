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

---

## 11. Upstream uSockets Analysis (uNetworking/uSockets)

This section provides the mapping between Zig tofu and the original upstream **uNetworking/uSockets** implementation (former implementation of the one vendored by Bun).

### 11.1 Reactor Event Loop & "Tick" Mechanism
Unlike Bun's version, upstream uSockets does not provide a public `us_loop_run_bun_tick` function. To maintain tofu's single-threaded Reactor "tick" model, the following strategy is used:

- **Mechanism:** Tofu implements its own `tick` by calling `epoll_wait` (Linux) or `kevent` (macOS) on the loop's internal file descriptor (`loop->fd`).
- **Dispatch:** Events are dispatched via `us_internal_dispatch_ready_poll`, which is the standard uSockets entry point for event processing.

| Tofu Requirement | Upstream uSockets / POSIX | Notes |
| :--- | :--- | :--- |
| **Loop Creation** | `us_create_loop` | Initializes the backend (`epoll_create1` / `kqueue`). |
| **Loop Tick** | Custom `epoll_wait` on `loop->fd` | Replicates the body of `us_loop_run` for one iteration. |
| **Wakeup** | `us_wakeup_loop` | Uses `eventfd` (Linux) or `EVFILT_USER` (macOS). |

### 11.2 Master Mapping Table: POSIX vs. Upstream uSockets

| Zig Tofu / `std.posix` | uSockets (BSD Wrapper) | tofu Implementation Strategy |
| :--- | :--- | :--- |
| `posix.socket` | `bsd_create_socket` | Used for raw socket creation if needed. |
| `posix.bind` / `listen` | `bsd_create_listen_socket` | Unified creation and binding. |
| `posix.accept` | `bsd_accept_socket` | Direct mapping (wraps `accept4` on Linux). |
| `posix.connect` | `bsd_create_connect_socket` | Unified resolution and connection. |
| `posix.send` | **`bsd_send`** | Direct mapping. Handles `MSG_MORE`. |
| `posix.recv` | **`bsd_recv`** | Direct mapping. |
| `posix.close` | `bsd_close_socket` | Standard `close` / `closesocket`. |
| `setsockopt(NODELAY)` | `bsd_socket_nodelay` | Exposed wrapper. |

### 11.3 Address Resolution & UDS
Upstream uSockets integrates address resolution directly into the socket creation functions, simplifying the `SocketCreator` logic.

| Tofu Requirement | uSockets Analog | Implementation Notes |
| :--- | :--- | :--- |
| **TCP Resolve & Bind** | `bsd_create_listen_socket` | Uses internal `getaddrinfo`. |
| **TCP Resolve & Connect**| `bsd_create_connect_socket`| Uses internal `getaddrinfo`. |
| **UDS Listen** | `bsd_create_listen_socket_unix` | Handles path unlinking and binding. |
| **UDS Connect** | `bsd_create_connect_socket_unix`| Standard AF_UNIX connection. |

### 11.4 Poller Mechanism (Non-Callback Integration)
To preserve the "Pull" model and backpressure, Tofu uses the low-level poll API with `POLL_TYPE_CALLBACK`:

1.  **Poll Initialization:** `us_create_poll` creates the poll object; `us_poll_init` associates it with the raw FD.
2.  **Poll Type:** Set to `POLL_TYPE_CALLBACK` to bypass the high-level socket context handlers.
3.  **The Hook-Back:** The poll's extension memory stores the `*TriggeredChannel` pointer.
4.  **I/O Dispatch:** When the loop tick detects readiness, Tofu retrieves the FD via `us_poll_fd(p)` and performs manual I/O using the `bsd_send` / `bsd_recv` wrappers.

This mapping ensures that Tofu can transition to the upstream uSockets library while maintaining its architectural integrity and performance characteristics.

## 12. Proposal: OS-Separated Folders in a uSockets World

Despite the unified API provided by uSockets, Tofu will maintain its OS-separated folder structure (`linux/`, `windows/`, `mac/`) for the uSockets backend. This preserves the **Compile-Time Facade** pattern and isolates platform-specific environment requirements.

### 12.1 File-by-File Status Update

| File | Status | Role with uSockets |
| :--- | :--- | :--- |
| **`usockets_backend.zig`** | **NEW** | Replaces OS-specific backends (e.g., `epoll_backend.zig`). Implements the Poller interface and the custom `tick()` logic (manual FD wait + dispatch). |
| **`Skt.zig`** | **REFACTORED** | Retained to handle platform-specific environment (WSAStartup/Cleanup on Windows), Abstract UDS namespaces (Linux), and mapping OS error codes (`errno` vs `WSAGetLastError`) to `AmpeError`. Calls `bsd_send`/`bsd_recv`. |
| **`SocketCreator.zig`** | **REFACTORED** | Significantly simplified. Calls `bsd_create_listen_socket` / `bsd_create_connect_socket`. uSockets internally handles DNS resolution and connect-retry logic. |
| **`triggers.zig`** | **REFACTORED** | Maps `tofu.Triggers` to uSockets constants (`LIBUS_SOCKET_READABLE`, `LIBUS_SOCKET_WRITABLE`). |

### 12.2 Implementation Strategy: The Template Approach
The existing `src/ampe/usockets/` folder serves as the **primary template**. 
1.  Implementation begins in the `usockets/` folder using a generic approach.
2.  Verified logic is then "ported" to `linux/`, `windows/`, and `mac/`.
3.  Platform-specific "glue" (like Windows-specific initialization or Linux-specific socket options) is added only within the respective folders.

### 12.3 Benefits of Preservation
- **Zero Runtime Overhead:** Zig's comptime selection ensures no penalty for the multi-file structure.
- **Strict Isolation:** Platform-specific bugs (e.g., a WinSock-specific race condition) are isolated to the `windows/` directory.
- **Developer Clarity:** Follows the established Version 050 architecture, making the transition predictable for both developers and AI agents.

## 13. Upstream uSockets on Windows: The "Forced Epoll" Strategy

The upstream uSockets library defaults to `libuv` on Windows. However, to maintain tofu's lightweight, single-threaded Reactor model without the overhead of libuv, tofu will employ a **"Forced Epoll"** strategy to utilize `wepoll`.

### 13.1 wepoll vs. libuv
- **Upstream Default:** `#define LIBUS_USE_LIBUV` on Windows.
- **Tofu Strategy:** Define `LIBUS_USE_EPOLL` on Windows and utilize the `src/ampe/windows/wepoll/` implementation.

### 13.2 The Shim Layer (sys/epoll.h)
Since upstream uSockets' `epoll_kqueue.c` assumes a POSIX environment when `LIBUS_USE_EPOLL` is defined, tofu must provide a shim layer in `src/ampe/windows/shims/`:

| Shim Header | Purpose |
| :--- | :--- |
| **`sys/epoll.h`** | Redirects `epoll_create1`, `epoll_ctl`, and `epoll_wait` to `wepoll` functions. |
| **`sys/timerfd.h`** | Emulates `timerfd` using `wepoll` and Windows timers to satisfy the uSockets Linux-style backend. |
| **`sys/eventfd.h`** | Emulates `eventfd` (for `us_wakeup_loop`) using a standard socket-pair or a manual event implementation. |

### 13.3 Build Configuration
The `build.zig` will be configured to:
1.  Add the `src/ampe/windows/shims/` directory to the include path for uSockets compilation on Windows.
2.  Define `LIBUS_USE_EPOLL` for the Windows target.
3.  Link against `ws2_32.lib` and the `wepoll` C code.

This strategy allows tofu to use the highly optimized `epoll_kqueue.c` logic from upstream uSockets even on Windows, ensuring architectural parity across all supported platforms.

## 14. Comparison: bun-usockets vs. Upstream uSockets

This section evaluates the two candidates for tofu's C-backend transition.

### 14.1 bun-usockets (Bun-vendored version)

| Pros | Cons |
| :--- | :--- |
| **Native "Tick" Support:** Includes `us_loop_run_bun_tick`, perfectly matching tofu's Reactor model. | **Divergence:** Maintenance risk if Bun's internal needs cause the fork to drift significantly from upstream. |
| **Zig Integration:** Battle-tested within the Bun runtime (written in Zig); proven compatibility. | **Shadow Dependencies:** May contain Bun-specific optimizations or assumptions that add hidden complexity. |
| **Windows Readiness:** Likely contains optimized paths for Windows (wepoll/io_uring) refined by the Bun team. | **Versioning:** Harder to track against official uSockets releases. |

### 14.2 Upstream uSockets (uNetworking)

| Pros | Cons |
| :--- | :--- |
| **Architectural Purity:** The lightest possible version; zero baggage from external runtimes. | **Implementation Effort:** tofu must implement its own `tick()` function and Windows `sys/epoll.h` shims. |
| **Long-term Independence:** tofu tracks official releases directly; no dependency on Bun's maintenance cycle. | **"Pure" POSIX:** Less "friendly" to Windows by default; requires more "Forced Epoll" glue code. |
| **Fine-grained Control:** tofu chooses exactly which features (SSL, UDP, etc.) to include and how they are shimmed. | **Initial Risk:** Requires manual verification of the "Hook-Back" pattern for each platform. |

### 14.3 Verdict for Tofu

- **For Speed of Delivery:** **bun-usockets** is superior. It eliminates the need to write the loop-wait logic and handle Windows shims manually.
- **For Long-term Health:** **Upstream uSockets** is superior. By implementing the `tick()` and shims itself, tofu gains total ownership of its networking stack and avoids becoming a "Bun-dependency" project.

**Recommendation:** Given tofu's goal of being a "simple, flavorless" library (like its namesake), the **Upstream uSockets** implementation is the preferred strategic path, despite the higher initial implementation cost.

---

## 15. Revised Decision: bun-usockets Is the Implementation Target

After source-level verification of both candidates (see `design/transition-2-usockets-verdict.md`),
**bun-usockets** (`vendor/bun-usockets/`) is the chosen implementation target for all platforms including Windows.

### 15.1 Decisive Factors

| Factor | bun-usockets | Upstream uSockets |
| :--- | :--- | :--- |
| `us_socket_local_address` (needed for `getPort()`) | ✅ Public API in `libusockets.h` | ❌ Absent from public header |
| Tick primitive | `us_loop_run_bun_tick` (exported symbol) | `us_internal_dispatch_ready_poll` (internal) |
| Windows forced-epoll | ✅ Battle-tested by Bun team | ⚠️ Requires writing all shims from scratch |
| Vendor status | ✅ Already at `vendor/bun-usockets/` | ❌ Not vendored |
| Internal header dependency | Required for `bsd_*` and `POLL_TYPE_CALLBACK` | Same requirement |

### 15.2 Headers Required Beyond `libusockets.h`

Since tofu vendors the full source, including internal headers is acceptable:

- `src/internal/internal.h` — for `POLL_TYPE_CALLBACK`, `us_internal_poll_set_type`
- `src/internal/networking/bsd.h` — for `bsd_recv`, `bsd_send`, `bsd_accept_socket`,
  `bsd_create_listen_socket`, `bsd_create_connect_socket`, `bsd_create_connect_socket_unix`,
  `bsd_create_listen_socket_unix`

These headers must be added to the include path in `build.zig` for the usockets backend.

### 15.3 Corrected API Mapping (bun-usockets, POLL_TYPE_CALLBACK path)

| Tofu operation | bun-usockets call | Notes |
| :--- | :--- | :--- |
| Loop create | `us_create_loop` | Public API |
| Loop tick | `us_loop_run_bun_tick(loop, timeout)` | Forward-declare; defined in `epoll_kqueue.c` |
| Poll create | `us_create_poll(loop, 0, ext_size)` | Public API; ext_size = `@sizeOf(*TriggeredChannel)` |
| Poll init | `us_poll_init(p, fd, POLL_TYPE_CALLBACK)` | `POLL_TYPE_CALLBACK` from `internal.h` |
| Poll arm | `us_poll_start(p, loop, events)` | Public API |
| Poll modify | `us_poll_change(p, loop, events)` | Public API |
| Poll remove | `us_poll_stop(p, loop)` | Public API |
| Get FD | `us_poll_fd(p)` | Public API |
| Get context | `us_poll_ext(p)` — cast to `**TriggeredChannel` | Public API |
| `posix.listen/bind` | `bsd_create_listen_socket` / `bsd_create_listen_socket_unix` | Internal header |
| `posix.connect` | `bsd_create_connect_socket` / `bsd_create_connect_socket_unix` | Internal header |
| `posix.accept` | `bsd_accept_socket(us_poll_fd(p), &addr)` | Internal header; called on READABLE event |
| `posix.send` | `bsd_send(fd, buf, len)` | Internal header |
| `posix.recv` | `bsd_recv(fd, buf, len, 0)` | Internal header |
| `posix.close` | `us_socket_close` or raw `close`/`closesocket` | Platform-dependent |
| `getsockname` (getPort) | `us_socket_local_address(s, buf, &len)` | Public API |

### 15.4 Windows Strategy (Unchanged)

The forced-epoll strategy from §5.1 and §13 applies unchanged:
- Compile bun-usockets with `LIBUS_USE_EPOLL` on Windows.
- Provide `src/ampe/windows/shims/` with `sys/epoll.h`, `sys/timerfd.h`, `sys/eventfd.h`.
- The `eventfd` and `timerfd` shims are required because bun-usockets creates these
  internally at loop init (not because tofu calls `us_wakeup_loop`).

### 15.5 Implementation Sequence

1. **Linux first** — implement `src/ampe/usockets/` backend, verify against contract tests.
2. **Windows second** — add shim headers, verify forced-epoll path compiles and passes tests.
3. **macOS third** — kqueue path in bun-usockets; verify.
4. **Linux sandwich** — re-run full test suite on Linux after all platforms verified.
5. **4-mode verification** — Debug, ReleaseSafe, ReleaseFast, ReleaseSmall on each platform.

---

## 16. Folder Structure After usockets Migration

### 16.1 The posix folders do not change

`src/ampe/linux/`, `src/ampe/mac/`, and `src/ampe/windows/` are the **posix backend**.
They remain complete and unchanged. They are compiled only under `-Dnetwork=posix`.

### 16.2 The usockets backend is a single folder for all platforms

`src/ampe/usockets/` is selected for all OS targets under `-Dnetwork=portable`.
Because `bsd.c` absorbs OS differences internally, the Zig files in `usockets/` are
**mostly unified** — one implementation for Linux, Windows, and macOS.

What `bsd.c` handles internally (no per-OS Zig code needed):

- `bsd_accept_socket` — `accept4` on Linux, `accept` + fcntl on Windows/macOS.
- `bsd_create_listen_socket` — `getaddrinfo`, socket creation, all `setsockopt` variants per OS.
- `bsd_create_connect_socket` — Windows loopback fast-fail (`SIO_TCP_INITIAL_RTO`) and all connect variants.
- `bsd_recv` / `bsd_send` — EINTR retry, `MSG_NOSIGNAL` compat, `MSG_DONTWAIT` on all platforms.
- Abstract UDS sockets — detects `sun_path[0] == 0`, adjusts `addrlen` correctly.
- UDS long-path workaround — macOS 104-byte `sun_path` limit handled via `chdir` inside bsd.c.

### 16.3 What remains platform-specific in usockets/

Three small comptime branches stay in `usockets/Skt.zig`:

| Concern | Platform | How handled |
| :--- | :--- | :--- |
| Error code mapping | Windows: `WSAGetLastError()`; Linux/macOS: `errno` | `comptime if (builtin.os.tag == .windows)` in `mapError()` |
| Abstract UDS path prefix | Linux only: `path[0] = 0` before passing to `bsd_*` | `comptime if (builtin.os.tag == .linux)` already in `Notifier.zig` |
| `WSAStartup` / `WSACleanup` | Windows only | Stays in `Reactor.zig` (comptime branch already there) |

### 16.4 Windows build infrastructure (not Zig code)

`src/ampe/windows/shims/` provides C headers needed to compile bun-usockets on Windows:

| File | Purpose |
| :--- | :--- |
| `sys/epoll.h` | Redirects epoll calls to wepoll |
| `sys/timerfd.h` | Emulates timerfd (used by bun-usockets loop init internally) |
| `sys/eventfd.h` | Emulates eventfd (used by bun-usockets loop init internally) |

These shims are compile-time only. They make `bsd.c` and `epoll_kqueue.c` compile on Windows
without any changes to the bun-usockets source. They are added to the include path in `build.zig`
for Windows + usockets targets.

### 15.6 FdType Alignment (Implementation Constraint)

All poller backends declare `register`/`modify`/`unregister` with a platform fd parameter.
The usockets backend must use `common.FdType` (not `std.posix.fd_t`) because it compiles
on all platforms:

| Platform | `common.FdType` | `LIBUS_SOCKET_DESCRIPTOR` |
| :--- | :--- | :--- |
| Linux / macOS | `std.posix.fd_t` (`i32`) | `int` (`i32`) |
| Windows | `usize` | `uintptr_t` (`usize`) |

- `core.zig` already passes `common.toFd()` → `FdType` to all backend calls.
- `usockets_backend.zig` signatures updated to `common.FdType` (was `std.posix.fd_t`).
- `internal.zig` `Socket` type for usockets = `common.FdType` (replaces `std.posix.fd_t` placeholder).

---

### 16.5 Final file structure (usockets backend)

```
src/ampe/
├── internal.zig          # Facade: selects usockets/ under -Dnetwork=portable
├── poller.zig            # Facade: selects usockets/usockets_backend.zig
├── Notifier.zig          # Shared, platform-independent (already complete)
├── linux/                # Posix backend — unchanged, -Dnetwork=posix only
├── mac/                  # Posix backend — unchanged, -Dnetwork=posix only
├── windows/
│   ├── ...               # Posix backend — unchanged, -Dnetwork=posix only
│   └── shims/            # C headers for Windows usockets compilation
│       ├── sys/epoll.h
│       ├── sys/timerfd.h
│       └── sys/eventfd.h
└── usockets/             # Single unified backend for all platforms
    ├── Skt.zig           # bsd_* wrappers + mapError() comptime branch
    ├── SocketCreator.zig # bsd_create_listen/connect_socket wrappers
    ├── triggers.zig      # Triggers → LIBUS_SOCKET_READABLE/WRITABLE (same on all OS)
    └── usockets_backend.zig  # us_create_loop, us_create_poll, us_loop_run_bun_tick
```

---

## 17. Poller Test Portability + initPlatform/deinitPlatform

### 17.1 Platform environment lifecycle: `initPlatform` / `deinitPlatform`

WSA initialization (Windows only) was previously private to `Reactor.zig`
(`initPlatform`/`deinitPlatform`). Now promoted to a canonical location:

```zig
// src/ampe/internal.zig — exported via tofu.zig as tofu.initPlatform / tofu.deinitPlatform
pub fn initPlatform() AmpeError!void { ... }  // WSAStartup on Windows; no-op elsewhere
pub fn deinitPlatform() void { ... }          // WSACleanup on Windows; no-op elsewhere
```

`Reactor.zig` calls `internal.initPlatform()`/`internal.deinitPlatform()` — single implementation,
no duplication. Tests call `tofu.initPlatform()`/`tofu.deinitPlatform()`.
On Linux/macOS the comptime-false `if (.windows)` branch is pruned by the compiler.

### 17.2 Test layer summary

All three poller test files now run on all platforms (no OS guards):

| File | Level | What it tests | OS guard |
| :--- | :--- | :--- | :--- |
| `tests/ampe/poller_tests.zig` | Backend (`poller_instance.backend.*`) | 8 backend contract tests — register, wait, modify, unregister, seqN isolation | **None — all platforms** |
| `tests/pollercore_tests.zig` | PollerCore (`attachChannel`, `waitTriggers`, `trgChannel`) | 2 integration tests — Notifier wakeup, TCP accept/recv/send | **None — all platforms** |

### 17.3 Conversion from windows_poller_tests.zig

`tests/windows_poller_tests.zig` was a Windows-only file (skip guard on non-Windows).
`tests/pollercore_tests.zig` is the platform-independent replacement:

| Change | Detail |
| :--- | :--- |
| Skip guard removed | No `if (os.tag != .windows) return error.SkipZigTest` |
| WSA lifecycle | `tofu.initPlatform()`/`tofu.deinitPlatform()` — canonical source implementation |
| Port allocation | Port 0 → `getPort().?` replaces `FindFreeTcpPort()` |
| Send method | `sendBuf()` replaces `send()` (correct `Skt` instance method name) |
| Connect | `connectWithRetry` loop replaces single non-retried `connect()` |

### 17.4 Future usockets backend

Both test files run unchanged when the usockets backend is complete:
- `poller_tests.zig` validates the backend contract (register/wait/modify/unregister).
- `pollercore_tests.zig` validates full PollerCore integration (Notifier, accept, recv/send).
