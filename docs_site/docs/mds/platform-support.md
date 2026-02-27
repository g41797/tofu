# Platform Support

Tofu runs on Linux, macOS/BSD, and Windows 10+. Platform selection is **automatic** — the same application code runs on all platforms with zero changes.

---

## Platform Matrix

| Platform | Event Backend | TCP | UDS | Notes |
|----------|--------------|-----|-----|-------|
| Linux | epoll | ✅ | ✅ | Full support |
| Windows 10 RS4+ | wepoll | ✅ | ⚠️ | UDS works, TCP recommended under load |
| macOS / BSD | kqueue | ✅ | ✅ | Full support |

The backend is selected at **compile time** with zero runtime overhead:

```zig
pub const Poller = switch (builtin.os.tag) {
    .windows => @import("poller/wepoll_backend.zig").Poller,
    .linux   => @import("poller/epoll_backend.zig").Poller,
    .macos, .freebsd, .openbsd, .netbsd =>
               @import("poller/kqueue_backend.zig").Poller,
    else     => @import("poller/poll_backend.zig").Poller,
};
```

---

## What Is wepoll?

**wepoll** is a C shim that exposes an `epoll`-like API on top of Windows' native `AFD_POLL` mechanism. It is the event backend used by many cross-platform networking libraries (libuv, curl, etc.).

For tofu, wepoll means:
- The Reactor loop code is **identical** on Linux and Windows — only the backend module differs.
- No IOCP proactor pattern, no callbacks — the Reactor pattern is fully preserved.
- Requires Windows 10 build 17063 (RS4, Redstone 4) or later for Unix socket support.

---

## Windows Notes

- **Minimum version:** Windows 10 RS4 (build 17063) or later. Required for Unix Domain Socket support (`AF_UNIX`). The build system sets this version automatically when cross-compiling.
- **UDS stability:** Unix Domain Sockets work for basic use cases but may exhibit erratic behavior under heavy concurrent load on Windows. TCP is recommended for high-throughput scenarios on Windows.
- **Abortive closure:** Tofu applies `SO_LINGER=0` to all sockets on Windows automatically. This sends an RST on close, bypassing `TIME_WAIT` and preventing "Address already in use" errors in high-frequency connection loops.
- **No abstract sockets:** Windows does not support the Linux abstract socket namespace. Tofu handles this automatically — UDS paths are always filesystem paths on Windows.

---

## macOS / BSD Notes

- **Abstract Unix sockets:** The Linux abstract socket namespace (`socket_file[0] = 0`) is not supported on macOS/BSD. Tofu restricts this to Linux automatically — no action required by the user.
- **LLD linker:** The LLVM LLD linker does not support the Mach-O binary format. Tofu's `build.zig` disables LLD when targeting macOS automatically.
- **UDS path size:** macOS/BSD limits Unix socket paths to 104 bytes (vs 108 on Linux/Windows). Tofu uses a comptime check to enforce the correct limit per platform.

---

## All Platforms

- **Abortive socket closure** (`SO_LINGER=0`) is applied automatically by tofu on all platforms, not just Windows. This prevents stale `TIME_WAIT` states from interfering with test loops and reconnection scenarios.
- **4-mode verification:** The test suite passes in all four optimization modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) on Linux. Cross-compilation to Windows and macOS (x86_64 and aarch64) is verified.
