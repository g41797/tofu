# Reactor-over-IOCP Analysis Report (002) - OS Independence & Refactoring

**Date:** 2026-02-12
**Subject:** Identification of POSIX/Linux Hard-coded Patterns and Refactoring Advice
**Target:** Porting `tofu` to Windows 10+ using IOCP

---

## 1. Architectural Strategy: Comptime vs. Separate Files

For a Zig project of this nature, I recommend a **Hybrid Approach** similar to the Zig Standard Library:

1.  **Separate Files for Heavy Lift (Backend Implementations):** Use a directory structure for components with fundamentally different OS primitives (e.g., `Poller`, `Notifier`).
2.  **Facaded Modules:** A top-level file (e.g., `poller.zig`) acts as a dispatcher using `@import` and `builtin.target.os`.
3.  **Comptime for Lightweight Wrappers:** Use `comptime` switches within shared files for simple type aliasing (e.g., `Socket` handle types).

### Recommended Folder Structure
```text
src/ampe/
├── os/
│   ├── linux/
│   │   ├── Notifier.zig
│   │   └── poller.zig
│   └── windows/
│       ├── Notifier.zig (IOCP-based)
│       └── poller.zig (AFD_POLL-based)
├── poller.zig (Public facade: switch (builtin.target.os.tag))
├── Notifier.zig (Public facade)
└── triggeredSkts.zig (Refactored to be OS-agnostic)
```

---

## 2. Hard-coded POSIX Locations & Refactoring Advice

### 2.1 Poller Implementation
**File:** `src/ampe/poller.zig`
**Snippet:**
```zig
pub const Poll = struct {
    pollfdVtor: std.ArrayList(std.posix.pollfd) = undefined,
    // ...
    fn poll(pl: *Poll, timeout: i32) !bool {
        const triggered = std.posix.poll(pl.pollfdVtor.items, timeout) catch {
            return AmpeError.CommunicationFailed;
        };
        return triggered == 0;
    }
}
```
**Problem:** Direct dependency on `std.posix.poll` and `std.posix.pollfd`.
**Advice:** 
- Move the current `Poll` struct to `src/ampe/os/linux/poller.zig`.
- Create `src/ampe/os/windows/poller.zig` implementing `AFD_POLL`.
- Change `src/ampe/poller.zig` to a union or a struct that selects the backend at compile time.

### 2.2 Notifier UDS Implementation
**File:** `src/ampe/Notifier.zig`
**Snippet:**
```zig
fn initUDS(allocator: Allocator) !Notifier {
    // ...
    socket_file[0] = 0; // Set as 'abstract socket' - linux only
    var listSkt: Skt = try SCreator.createUdsListener(allocator, socket_file);
    // ...
    const receiver_fd = try posix.accept(listSkt.socket.?, null, null, posix.SOCK.NONBLOCK);
```
**Problem:** Hard-coded Linux Abstract Namespace and `posix.accept` with `SOCK.NONBLOCK`.
**Advice:** 
- Abstract the `Notifier` into an interface. 
- On Linux, keep the UDS/eventfd logic.
- On Windows, implement `Notifier` using `NtSetIoCompletion`. The "sender" becomes a wrapper for the IOCP handle, and the "receiver" is the IOCP completion queue itself.

### 2.3 Socket Handle Aliasing
**File:** `src/ampe/triggeredSkts.zig` (and others)
**Snippet:**
```zig
const Socket = std.posix.socket_t;
// ...
pub inline fn getSocket(tsk: *TriggeredSkt) Socket {
    return switch (tsk.*) {
        .notification => tsk.*.notification.getSocket(),
        // ...
        inline else => return 0, // For Linux
    };
}
```
**Problem:** `std.posix.socket_t` is `i32` on Linux but `usize` (HANDLE) on Windows. Hard-coded `0` as a "null" socket.
**Advice:** 
- Create a central `types.zig` or update `internal.zig` to define `const Socket = if (isWindows) windows.HANDLE else posix.socket_t`.
- Replace `0` with an OS-agnostic `InvalidSocket` constant.

### 2.4 Message I/O (Send/Recv)
**File:** `src/ampe/triggeredSkts.zig` (`MsgSender`, `MsgReceiver`)
**Snippet:**
```zig
pub fn sendBuf(socket: std.posix.socket_t, buf: []const u8) AmpeError!?usize {
    wasSend = std.posix.send(socket, buf, 0) catch |e| {
        // ...
    }
}
```
**Problem:** Direct calls to `std.posix.send` and `std.posix.recv`.
**Advice:** 
- Move I/O primitives to a platform-specific `Skt.zig` or `os_io.zig`.
- Windows will need to handle `WSAEWOULDBLOCK` differently from POSIX `EWOULDBLOCK` in some Zig versions.

### 2.5 Reactor Loop Logic
**File:** `src/ampe/Reactor.zig`
**Snippet:**
```zig
fn createNotificationChannel(rtr: *Reactor) !void {
    // ...
    ntcn.tskt = .{
        .notification = internal.triggeredSkts.NotificationSkt.init(rtr.ntfr.receiver),
    };
```
**Problem:** Assumes the notification channel *must* be a socket (receiver end of a pipe/UDS).
**Advice:** 
- On Windows, the "Notification Channel" should be the IOCP completion itself.
- Refactor `TriggeredChannel` to support a `.virtual` or `.iocp` trigger type that doesn't require a physical file descriptor.

### 2.6 Socket Abstraction (Skt.zig)
**File:** `src/ampe/Skt.zig`
**Problem:** Hard-coded `std.posix` calls for `bind`, `listen`, `accept`, `connect`, and `setsockopt`. It also includes Linux-specific logic for `accept4` flags.
**Advice:** 
- Move `acceptOs` and `connectOs` to platform-specific backends.
- Abstract socket option setting (Linger, Nagle, Reuse) into a platform-agnostic interface.
- Replace `std.posix.socket_t` with an OS-agnostic `Socket` type.

### 2.7 Socket Creation (SocketCreator.zig)
**File:** `src/ampe/SocketCreator.zig`
**Problem:** `createUdsListener` and `createUdsSocket` assume POSIX path handling. Windows `AF_UNIX` requires actual file paths and has different lifecycle rules (e.g., file must be deleted before bind).
**Advice:** 
- Implement platform-specific `UDSHelper` to handle path normalization and cleanup.
- On Windows, ensure UDS paths are absolute and the file is unlinked before `bind`.

### 2.8 Test Utilities (testHelpers.zig)
**File:** `src/ampe/testHelpers.zig`
**Problem:** `TempUdsPath` uses `temp.port` pattern and assumes POSIX file deletion. `FindFreeTcpPort` uses `std.posix.SO.REUSEPORT`, which is not available/behave differently on Windows.
**Advice:** 
- Refactor `FindFreeTcpPort` to use a more portable method or handle `SO_REUSEPORT` unavailability on Windows.
- Update `TempUdsPath` to use a portable temp directory and handle Windows path separators.

---

## 3. OS-Independent References & Paths

To ensure compatibility between Linux, Windows, and Wine environments:

1.  **Relative Paths Only:** All documentation (`.md`) and configuration files MUST use relative paths (e.g., `./analysis/001.md` instead of `/home/...`).
2.  **Path Separators:** In Zig code, use `std.fs.path.sep` or `std.fs.path.join` instead of hard-coded `/` or `\\`.
3.  **Environment Mapping:** Acknowledge that `/home/g41797/` on Linux may map to `Z:\home\g41797\` in Wine. Always refer to the **Project Root** as the anchor.
4.  **Case Sensitivity:** Treat all filenames as case-sensitive to maintain Linux compatibility, even when developing on Windows.

---

## 4. Build System & CI Changes

1.  **build.zig Updates:**
    - Conditionally link `ws2_32` and `ntdll` for Windows targets.
    - Ensure `use_llvm = true` and `use_lld = true` are used for cross-compilation stability.
2.  **GitHub Actions:**
    - The existing `windows.yml` uses `runs-on: windows-latest`. Ensure it correctly installs the specific Zig 0.15.2 version.
    - Add a step to run the Windows-specific POC tests once implemented.

---

## 5. Recommended Refactoring Steps

1.  **Stage A (Infrastructure):** Define OS-agnostic types in `src/ampe/internal.zig`.
2.  **Stage B (Poller Extraction):** Move current `poll` logic to `os/linux/poller.zig` and verify Linux tests still pass.
3.  **Stage C (Notifier Interface):** Modularize `Notifier` to allow the Windows implementation to swap the loopback socket for IOCP completion packets.
4.  **Stage D (Poller Windows):** Implement the `AFD_POLL` backend in `os/windows/poller.zig`.

*End of Dedicated Section*
