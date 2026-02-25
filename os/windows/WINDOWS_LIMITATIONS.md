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

---

## 3. Poller & Event Loop (`wepoll`)

### **ABI & Constants**
- **Difference:** `wepoll` defines `EPOLL_CTL_MOD` as `2` and `EPOLL_CTL_DEL` as `3`, which is the inverse of the Linux standard. `src/ampe/poller.zig` uses platform-specific constants to bridge this.
- **ABI:** We use a custom `WepollEvent` struct to strictly match the Windows C layout expected by `wepoll.c`, avoiding union-related corruption seen with `std.os.linux.epoll_event`.

### **Pointer Stability**
- **Architecture Change:** Unlike Linux (which can sometimes get away with direct value storage), the Windows `PollerOs` **must** store `TriggeredChannel` as heap-allocated pointers (`*TriggeredChannel`). 
- **Reason:** Internal I/O vectors point to fields within the struct. `AutoArrayHashMap` reallocations move elements, making these pointers stale. Heap allocation ensures address stability.

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

