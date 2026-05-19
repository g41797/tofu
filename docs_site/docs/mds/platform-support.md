# Platform Support

Tofu compiles and runs on Linux, macOS/BSD, and Windows 10+. The event backend is selected **automatically at compile time** — no code changes required.

However, platforms are not at equal maturity. Read the status section carefully before choosing a deployment target.

---

## Two Network Backends

Tofu offers two distinct network backends for I/O:

- **`stdposix`** (default): Uses Zig's standard library and native POSIX/Windows syscalls.
- **`posixnet`**: Uses the high-performance vendored usockets C wrapper.

### When to choose `posixnet`
- When targeting environments where Zig's standard library socket API is rapidly evolving (see below).
- When targeting Windows with a unified backend that mirrors Linux behavior closely.
- When you require a C FFI layer for stability.

> **Zig 0.16 Roadmap Note**: In Zig 0.16, `std.net` is slated for major changes. The `stdposix` backend depends directly on these types. The `posixnet` backend uses vendored usockets types instead, making it the forward-compatible choice for Zig 0.16 and beyond.

---

## Readiness Status

| Platform | Event Backend | Status | TCP | UDS |
|----------|--------------|--------|-----|-----|
| **Linux** | epoll | ✅ **Production ready** | ✅ | ✅ |
| **macOS / BSD** | kqueue | 🔶 **Experimental** | ✅ | ✅ |
| **Windows 10 RS4+** | wepoll | 🔶 **Experimental** | ✅ | ⚠️ |

### Linux — Production Ready

The Linux backend using native `epoll` is the primary, battle-tested target:

- All 35 tests pass in all four optimization modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`).
- Full TCP and Unix Domain Socket support verified under stress.
- This is the recommended deployment platform.

### macOS / BSD — Experimental

The kqueue backend is structurally complete and cross-compiles cleanly from Linux, but **has not yet been verified on native macOS hardware**:

- Cross-compilation to `x86_64-macos` and `aarch64-macos` passes.
- Key fixes applied: `setLingerAbort()` raw syscall (avoids macOS `EINVAL` panic), abstract socket restriction, kqueue timeout handling, `EV_RECEIPT` error safety.
- Native hardware testing is pending to confirm these fixes hold at runtime.
- **Do not use in production** until native verification is complete.

### Windows — Experimental

The [wepoll](https://github.com/piscisaureus/wepoll) backend is structurally complete and cross-compiles cleanly from Linux, but the **full test suite has not been run on native Windows**:

- Cross-compilation to `x86_64-windows-gnu` passes.
- Core TCP scenarios are verified. UDS works for basic cases but is unstable under heavy concurrent load — TCP is recommended.
- Loop counts and timing parameters in the test suite are reduced on Windows relative to Linux.
- **Do not use in production** until native Windows verification is complete.

---

## Comptime Backend Selection

The backend is selected at compile time with zero runtime overhead:

```zig
pub const Poller = switch (build_options.network) {
    .posixnet => @import("../platform/posixnet/posixnet_backend.zig").Poller,
    .stdposix => switch (builtin.os.tag) {
        .windows => @import("../platform/stdposix/windows/wepoll_backend.zig").Poller,
        .linux   => @import("../platform/stdposix/linux/epoll_backend.zig").Poller,
        .macos, .freebsd, .openbsd, .netbsd =>
                   @import("../platform/stdposix/mac/kqueue_backend.zig").Poller,
        else     => @compileError("unsupported platform"),
    },
};
```

---

## What Is wepoll?

**wepoll** — epoll emulator for Windows, internally based on IOCP.

For tofu, wepoll is a managed dependency declared in `build.zig.zon`. It means:
- The Reactor loop code is **identical** on Linux and Windows — only the backend module differs.
- No IOCP proactor pattern, no callbacks — the Reactor pattern is fully preserved.
- Requires Windows 10 RS4 (build 17063) or later for Unix Domain Socket support.

---

## Windows Notes

- **Minimum version:** Windows 10 RS4 (build 17063) or later, required for `AF_UNIX` support. Set automatically by `build.zig` when cross-compiling.
- **UDS stability:** Works for basic cases; unstable under heavy concurrent load. Use TCP for high-throughput scenarios on Windows.
- **Abortive closure:** Tofu applies `SO_LINGER=0` automatically on all Windows socket paths to prevent `TIME_WAIT` stalls and `BindFailed` errors in reconnection loops.
- **No abstract sockets:** Windows does not support the Linux abstract Unix socket namespace. Tofu handles this automatically — UDS paths are always filesystem paths on Windows.

---

## macOS / BSD Notes

- **Abstract Unix sockets:** Not supported on macOS/BSD (Linux-only feature). Tofu restricts abstract socket usage to Linux automatically.
- **LLD linker:** LLD does not support the Mach-O binary format. `build.zig` disables LLD for macOS targets automatically.
- **UDS path size:** macOS/BSD limits socket paths to 104 bytes (vs 108 on Linux/Windows). Tofu enforces the correct limit per platform at compile time.

---

## All Platforms

- **Abortive socket closure** (`SO_LINGER=0`) is applied on all platforms to prevent stale `TIME_WAIT` states from interfering with test loops and reconnection scenarios.

---
