# Analysis 004: Unix Domain Sockets (AF_UNIX) on Windows

## Overview
Windows 10 (Build 1803+) and Windows Server 2019+ introduced native support for Unix Domain Sockets (`AF_UNIX`). For the `tofu` Reactor, we must ensure that `AFD_POLL` correctly handles readiness for these sockets and identifies any platform-specific quirks regarding non-blocking I/O.

## Technical Findings

### 1. Addressing and Path Limits
- **Path Format:** Windows UDS uses standard filesystem paths (e.g., `C:\Users\Name\socket.sock`).
- **No Abstract Namespace:** Windows does **not** support the Linux abstract namespace (paths starting with `\0`).
- **Path Length:** Limited to 108 characters (`UNIX_PATH_MAX`), consistent with POSIX.
- **Unlinking:** Like POSIX, the socket file remains on disk after `close()`. The Reactor must manually `DeleteFile` the path before a new `bind()`.

### 2. AFD_POLL Compatibility
- **Provider:** `AF_UNIX` on Windows is implemented as a WinSock Layered Service Provider (LSP) or a direct kernel-mode provider (via `afunix.sys`).
- **Readiness:** `AFD_POLL` works identically for `AF_UNIX` as it does for `AF_INET`.
- **SIO_BASE_HANDLE:** Crucial for UDS. Many LSPs wrap UDS handles. We must use `SIO_BASE_HANDLE` to get the raw provider handle for `AFD_POLL`.

### 3. Non-Blocking Behavior
- **WSAEventSelect vs AFD:** While `WSAEventSelect` is common for Windows UDS, `AFD_POLL` remains the superior choice for our Reactor because it allows us to unify the completion port logic for all socket types.
- **Connect Behavior:** Non-blocking `connect()` on UDS may return `WSAEWOULDBLOCK`. The Reactor must wait for `AFD_POLL_OUT` (ready to write) to confirm the connection is established.

### 4. Comparison: Windows vs. Linux UDS
| Feature | Linux | Windows |
| :--- | :--- | :--- |
| **Abstract Path** | Supported (`\0name`) | **Unsupported** |
| **Permissions** | `chmod` on socket file | NTFS ACLs |
| **Credential Passing** | `SCM_CREDENTIALS` | `SIO_AF_UNIX_GETPEERPID` (Recent builds) |
| **Reactor Trigger** | epoll (Ready) | AFD_POLL (Ready) |

## Implementation Strategy for Stage 1U (POC)
1. **Handle Extraction:** Ensure `SIO_BASE_HANDLE` works for `AF_UNIX`.
2. **Listener Readiness:** Verify `AFD_POLL_ACCEPT` triggers.
3. **Loopback Stress:** Verify throughput/latency of the AFD Reactor over UDS.

### Final Verification Results (2026-02-14)
- **Readiness Parity:** `AFD_POLL` provides identical readiness semantics for `AF_UNIX` as it does for TCP.
- **Base Handle Requirement:** **Crucial.** Accepted UDS sockets return a layered handle. Attempting to associate this handle with an IOCP fails silently or triggers `INVALID_PARAMETER` if already associated with a different port. Always extract the base handle.
- **Stress Stability:** Zero packet loss and correct completion routing under concurrent load.
- **Performance:** UDS loopback exhibits significantly lower overhead than TCP loopback on Windows, matching POSIX expectations.

## Risk Assessment
- **Minimum OS Version:** Verification fails if the environment is older than Windows 10 1803.
- **Path Conflicts:** If a previous run crashed, the socket file might prevent binding. Implementation must include robust `tryDelete` logic.
