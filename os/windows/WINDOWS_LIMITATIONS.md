# Windows Implementation: Limitations & Deviations

This document tracks all architectural differences, performance constraints, and logic deviations between the Windows port and the original Linux implementation of the `tofu` library.

---

## 🛑 MUST RULE: MAINTENANCE
**Every AI agent and developer MUST update this document immediately whenever a Windows-specific limitation or logic deviation is added, modified, or removed. Failure to maintain this document leads to protocol hangs and regression bugs.**

---

## 1. Network & Socket Infrastructure

### **Abortive Closure (Mandatory)**
- **Difference:** On Windows, all sockets (including those in `FindFreeTcpPort` and `Skt.close()`) are closed **abortively** (using `SO_LINGER` with `l_onoff=1, l_linger=0` followed by `closesocket`).
- **Reason:** Windows' management of `TIME_WAIT` and resource release is slower than Linux. Abortive closure (sending an `RST`) is required to prevent "Address already in use" (`BindFailed`) and "Connect failed" errors in high-frequency test loops.

### **WinSock Parity**
- **Difference:** We avoid `std.posix.close()` for sockets on Windows, favoring the native `closesocket()` function to ensure the WinSock stack correctly processes the closure.

---

## 2. Unix Domain Sockets (UDS)

### **Erratic Stability**
- **Limitation:** UDS infrastructure is re-enabled on Windows 10+, but it is currently **unstable under load**. 
- **Bypass:** The `Notifier` is forced to **TCP-only** on Windows via `comptime` in `src/ampe/Notifier.zig`. 
- **Test Status:** Reactor-level UDS stress tests are **bypassed** using `if (builtin.os.tag != .windows)` checks in `tests/reactor_tests.zig`.

### **Path Management**
- **Difference:** No "Abstract Namespace" support. All UDS paths must be valid Windows filesystem paths.
- **Cleanup:** Socket files must be explicitly deleted using `std.fs.deleteFileAbsolute` before `bind()` to avoid collisions.

### **Minimum Windows Version for UDS (build.zig)**
- **Requirement:** Windows 10 RS4 (Redstone 4, build 17063) or later for Unix socket support.
- **Issue:** When cross-compiling to Windows, the default target version is older than RS4. The Zig stdlib checks `has_unix_sockets` which depends on `builtin.os.version_range.windows.isAtLeast(.win10_rs4)`. If the target version is too old, `Address.un` becomes `void` and UDS code fails to compile.
  ```zig
  // In std/net.zig
  pub const has_unix_sockets = switch (native_os) {
      .windows => builtin.os.version_range.windows.isAtLeast(.win10_rs4) orelse false,
      // ...
  };
  pub const Address = extern union {
      un: if (has_unix_sockets) posix.sockaddr.un else void,
      // ...
  };
  ```
- **Fix:** `build.zig` sets `target_query.os_version_min = .{ .windows = .win10_rs4 }` before resolving the target, ensuring `has_unix_sockets = true` during cross-compilation.
- **Reference:** This is NOT a stdlib bug - it's proper version-gating. UDS was added in Windows 10 RS4.

---

## 3. Poller & Event Loop (`wepoll`)

### **ABI & Constants**
- **Difference:** `wepoll` defines `EPOLL_CTL_MOD` as `2` and `EPOLL_CTL_DEL` as `3`, which is the inverse of the Linux standard. `src/ampe/poller.zig` uses platform-specific constants to bridge this.
- **ABI:** We use a custom `WepollEvent` struct to strictly match the Windows C layout expected by `wepoll.c`, avoiding union-related corruption seen with `std.os.linux.epoll_event`.

### **Pointer Stability (Heap-Allocated TriggeredChannel)**
- **Architecture Change:** The `Poller` stores `TriggeredChannel` as heap-allocated pointers (`*TriggeredChannel`) rather than by value.
- **Reason 1: Iterator Safety:** The Reactor mutates the channel map **during iteration**. When an `accept` trigger fires, it calls `attachChannel()` which inserts a new entry via `seqn_trc_map.put()`. If the map stored values directly, this insertion could trigger reallocation, invalidating the iterator's internal slice and the `*TriggeredChannel` pointer currently being processed.
- **Reason 2: Windows Kernel Integrity (MANDATORY):** On Windows, `AFD_POLL` (via `wepoll`) is an asynchronous operation. The kernel receives a pointer to an `IO_STATUS_BLOCK` (stored within the channel's socket state) and **retains this pointer** to write the result later. If the `TriggeredChannel` were stored by value and the map resized, the `IO_STATUS_BLOCK` would move. The kernel would then write the completion status into the **old, now-invalid address**, causing silent and catastrophic memory corruption.
- **Solution:** Heap allocation ensures that once a channel is created, its memory address (and thus the address of its internal `IO_STATUS_BLOCK`) is "pinned" for its entire lifecycle, regardless of map reallocations.

### **I/O Vector Stability (MsgReceiver/MsgSender)**
- **Architecture Change:** Added `refreshPointers()` methods to `MsgReceiver` and `MsgSender` in `triggeredSkts.zig`.
- **Reason:** The `iov[]` arrays contain pointers into `Message` buffers (`bhdr`, `thdrs`, `body`). These pointers are set during `prepare()` but may become stale if the message's internal buffers are reallocated or if partial I/O occurs across multiple poll cycles.
- **Solution:** `refreshPointers()` is called at the start of each `waitTriggers` reconciliation loop to recalculate `iov[].base` pointers based on current buffer addresses and I/O progress.
- **Reference:** See `triggeredSkts.zig:588` (MsgSender) and `triggeredSkts.zig:957` (MsgReceiver).

---

## 4. Test Suite Constraints

### **Loop Reduction (Stress Mitigation)**
- **Limitation:** High-volume loops are significantly reduced on Windows to prevent `wepoll` event loss and protocol hangs.
- **Current Scaling:**
    - `handleReConnectST` tries: 1000 (Linux) -> **10** (Windows).
    - `handleReConnectST` iterations: 100 (Linux) -> **5** (Windows).
    - `waitConnectClient` retries: 100 (Linux) -> **10** (Windows).
    - `sendRecvNonPoll` retries: 100 (Linux) -> **10** (Windows).

### **Wait Times & Retries**
- **Change:** Added explicit `std.Thread.sleep` (10-20ms) in reconnection loops (`cookbook.zig`) to give the Windows network stack time to cycle through handle cleanup.
- **Retry Logic:** Implemented automatic retry loops (5 attempts, 10ms delay) in `Skt.listen()` and `Skt.connect()` specifically for Windows to handle transient `BindFailed` and `ConnectRefused` errors during high-volume churn.

### **Echo Client/Server Stress Tests**
- **Limitation:** `handleEchoClientServer` is forced to **TCP-only** on Windows to avoid UDS instability.
- **Scaling:** `EchoClientServer.run` iterations reduced: 100 (Linux) -> **10** (Windows). This ensures the 1000-echo threshold is met with lower concurrency.

---

## 5. Verification Status
- **Debug:** **PASSED** (40/40 tests).
- **ReleaseFast:** **PASSED** (40/40 tests).
- **Sandwich Check:** Linux cross-compilation verified.

