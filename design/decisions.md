# Architectural Decision Log

This document tracks the settled architectural and technical decisions for the tofu cross-platform port.

---

## 1. Project Scope & Targets

- **Platform Support:** Linux, macOS/BSD, Windows 10+.
- **Zig Version:** 0.15.2.
- **Target Scale:** < 1,000 connections.
- **Transports:** TCP + AF_UNIX.
- **Internal Model:** Single-threaded I/O thread (Reactor) with queue-based application interface (no public callbacks).

---

## 2. Technical Decisions

- **Event Notification (Linux):** Use native **epoll**.
- **Event Notification (Windows):** Use **wepoll** (C shim over AFD_POLL, exposes epoll-like API). IOCP was evaluated via POC work and rejected in favor of wepoll for its simpler integration path.
- **Event Notification (macOS/BSD):** Use **kqueue**.
- **Comptime Selection:** Backend selected at compile time in `poller.zig` — zero runtime overhead.
- **AFD_POLL Re-arming (Windows Critical):** wepoll handles re-arming internally.
- **Cross-thread Signaling:** `Notifier.zig` uses UDS socket pairs on all platforms (Linux uses abstract sockets, Windows/macOS use filesystem paths).
- **No Callbacks:** All backends populate `TriggeredChannel.act` flags directly, allowing the existing loop logic to remain platform-agnostic.

---

## 3. Implementation Philosophy

- **Reactor Pattern Preservation:** Do NOT switch to a native IOCP Proactor model.
- **Triggers Abstraction:** The `Triggers` packed struct expresses *intent*, not *mechanism*. All Reactor logic is platform-agnostic — OS-specific translation happens in `triggers.zig`.
- **Consolidated Spec:** `design/spec.md` is the authoritative reference.
- **Explicit Typing:** Always specify the type in a constant or variable declaration. Do not rely on type inference.
- **Explicit Dereferencing:** Always dereference pointers explicitly with `.*`.
- **Standard Library First:** Before adding a new definition to a custom binding file, always check if it already exists in the Zig standard library.

---

## 4. Notifier Refactoring (2026-02-15)

- **Single Unified File:** `src/ampe/Notifier.zig` is a single file using `@This()` pattern with comptime branches for 2 platform differences. NOT a facade — no separate backend files.
- **Why Not Facade:** Initially implemented as facade + backends, but the two backends had only 2 trivial differences (abstract sockets, connect ordering). Collapsed back to single file to avoid unnecessary complexity.
- **Comptime Branches:** (1) Abstract sockets on Linux only. (2) Connect ordering: Windows calls `Skt.connect()` before `waitConnect()`; Linux calls `waitConnect()` before `posix.connect()`.
- **UDS Restored:** Both platforms use UDS socket pairs. Linux uses abstract sockets. Windows/macOS use filesystem paths.
- **WSAStartup Ownership:** The `Reactor` owns `WSAStartup` and `WSACleanup` on Windows. `Reactor.create` calls `WSAStartup(0x0202, &wsa_data)`, `Reactor.destroy` calls `WSACleanup()`.

---

## 5. PinnedState Design Decisions (2026-02-16)

### 5.1 PinnedState Struct
- **Fields:** `io_status: IO_STATUS_BLOCK`, `poll_info: AFD_POLL_INFO`, `is_pending: bool`, `expected_events: u32`.
- **Allocation:** Heap-allocated per channel via `allocator.create(PinnedState)`.
- **Rationale:** These fields must have stable addresses while the kernel holds references.

### 5.2 ChannelNumber as ApcContext
- **Encoding:** `@ptrFromInt(@as(usize, chn))` where `chn` is `u16` (ChannelNumber).
- **Decoding:** `@as(ChannelNumber, @intCast(@intFromPtr(entry.ApcContext.?)))`.
- **Rationale:** Replaces `*TriggeredChannel` pointer which becomes stale on map growth/swapRemove.

### 5.3 PinnedState Lifecycle
- **Created:** In `armFds()` via `getOrPut` when a channel first needs to be armed.
- **Freed (deferred):** In `processCompletions()` when completion arrives for a channel no longer in `trgrd_map`.
- **Freed (shutdown):** In `Poll.deinit()` — frees all remaining states.
- **NOT freed eagerly:** On channel removal, the kernel may still hold a reference to `io_status`.

### 5.4 Thin Skt
- **Removed from Skt:** `io_status`, `poll_info`, `is_pending`, `expected_events`.
- **Retained in Skt:** `socket`, `address`, `server`, `base_handle`.
- **Rationale:** Kernel-facing async state belongs in PinnedState (owned by Poller), not in Skt (owned by TriggeredChannel in the moving map).

---

## 6. Verified Technical Findings (from POC)

### 6.1 AFD_POLL Buffer: Same Buffer for Input and Output (Verified 2026-02-13)

`IOCTL_AFD_POLL` (0x00012024) uses `METHOD_BUFFERED`. All reference implementations (wepoll, c-ares, mio) pass the **same** `AFD_POLL_INFO` pointer for both the InputBuffer and OutputBuffer parameters of `NtDeviceIoControlFile`.

**Rule:** Always use the same `AFD_POLL_INFO` variable for both input and output in `NtDeviceIoControlFile`.

### 6.2 ApcContext Must Be Non-Null for IOCP Completion Posting (Verified 2026-02-13)

In the NT I/O model, when a file handle is associated with an IOCP:
- If `ApcContext` passed to `NtDeviceIoControlFile` is **non-null** → completion IS posted to IOCP.
- If `ApcContext` is **null** → completion is NOT posted.

**Rule:** When issuing `NtDeviceIoControlFile` for AFD_POLL with IOCP completion, always pass a non-null `ApcContext`.

### 6.3 IOCP-Integrated AFD_POLL_ACCEPT End-to-End (Verified 2026-02-13)

The full IOCP completion path for AFD_POLL_ACCEPT has been verified. Confirms that IOCP is a viable sole completion mechanism for AFD_POLL — no event handles needed. (Note: production uses wepoll, which handles this internally.)

---

*End of Decision Log*
