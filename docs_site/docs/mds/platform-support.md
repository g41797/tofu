# Platform Support

Tofu compiles and runs on Linux, macOS/BSD, and Windows 10+. The event backend is selected **automatically at compile time** — no code changes required.

However, platforms are not at equal maturity. Read the status section carefully before choosing a deployment target.

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

**wepoll** — epoll emulator for Windows, internally based on IOCP.

For tofu, wepoll means:
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

## Reactor vs Proactor

To understand tofu's current architecture and its relationship to `Io.Evented`, it helps to know the difference between these two async I/O patterns.

### Reactor (tofu's current model)

The OS notifies *readiness*. The app performs I/O itself.

```
OS → "fd 7 is readable"
App → read(fd 7, buf)  — app does the I/O
App → process(buf)
```

Examples: `epoll`, `kqueue`, `wepoll`.

Tofu's `Reactor.zig` uses this model. `waitTriggers` asks "what is ready?" and acts on it.

### Proactor

The app submits I/O operations upfront. The OS performs them. The app is notified on completion.

```
App → submit read(fd 7, buf, n)  — app registers intent
OS  → performs the I/O
OS  → "read on fd 7 complete, 42 bytes transferred"
App → process(buf)
```

The app never calls `read`/`write` directly. It submits and harvests completions.
Examples: Windows IOCP, Linux `io_uring`.

---

## Future: Io.Evented Backend

When Zig's standard library `Io.Evented` matures and becomes available, tofu intends to adopt it as a unified event backend, replacing the current per-platform epoll/kqueue/wepoll implementations.

**In all cases, your application code will not change.**

The impact on tofu's internals depends on which model `Io.Evented` exposes.

### Scenario A: Io.Evented uses a Reactor model

If `Io.Evented` exposes readiness notification (the OS tells you *when* a fd is ready), the integration is straightforward:

- A new `io_evented_backend.zig` replaces the OS-specific backends.
- A new translation pair is added to `triggers.zig` (readiness flags ↔ `Triggers`).
- `Reactor.zig`, the protocol logic, and all application code remain **completely unchanged**.

Same kind of change as adding the kqueue backend alongside epoll.

### Scenario B: Io.Evented uses a Proactor model

If `Io.Evented` exposes completion notification (the OS tells you *when an I/O op finished*), the mismatch with tofu's Reactor is fundamental and requires partial internal rewriting:

- The `waitTriggers` loop in `Reactor.zig` must be rethought: instead of "check what is ready, then do I/O," it becomes "submit I/O ops, then harvest completions."
- The `PollerCore` and backends require significant rework — the concept of registering fd interest changes to submitting I/O requests.
- The `Triggers` abstraction may be recast: instead of expressing "I want to know when this fd is readable," it expresses "I am submitting a read operation."

**However, the public API layer is structurally untouched:**

- The `Ampe` / `ChannelGroup` vtable interface — what callers use to send and receive messages — does not change.
- `Message`, `OpCode`, `AmpeStatus`, `Address` — all stable.
- Channel lifecycle (Hello/Welcome/Bye) — unchanged.
- Application code that uses tofu does not need modification in either scenario.

More work for the maintainers. The API stays the same.
