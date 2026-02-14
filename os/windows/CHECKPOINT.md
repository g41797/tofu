**AGENT HANDOVER CHECKPOINT**
**Current Date:** 2026-02-14
**Last Agent:** Claude Code (Opus 4.6)
**Active Phase:** Phase II (Structural Refactoring)
**Active Stage:** Fixing Stage 3 Stress Test Hang

## Current Status
- **Phase I (Feasibility) COMPLETE for TCP and UDS.**
- **Structural Refactoring (Phase II) STAGE 1 COMPLETE.**
- **Architecture:** `Skt` and `Poller` are fully modularized. Windows-specific state (`IO_STATUS_BLOCK`, `base_handle`) is encapsulated inside `Skt`.
- **Cross-Platform Compilation:** Previously verified for BOTH Linux and Windows.
- **POCs:** Stages 0-2 pass. **Stage 3 still hangs** (see below).

## Interrupt Point — Stage 3 Hang Fix (INCOMPLETE)

### Root Cause Analysis (CONFIRMED)
The Stage 3 stress test hangs at "Polling... (handled 0/50)" because **client threads silently fail to connect**. On Windows, calling `connect()` again on a non-blocking socket mid-connection returns `WSAEALREADY` (or other implementation-dependent errors). The old `Skt.connect()` didn't handle this — the error fell to the `else` branch, returned `PeerDisconnected`, the client caught it and silently returned, so 0 messages were ever sent.

**Microsoft warning**: "error codes returned from connect while a connection is already pending may vary among implementations. It is not recommended that applications use multiple calls to connect to detect connection completion."

**Correct Windows pattern**: After first `connect()` returns `WSAEWOULDBLOCK`, use `WSAPoll(POLLWRNORM, 0ms)` to non-blockingly check completion. No retry-connect needed.

### What Was Done (Step 1 of plan — APPLIED but NOT YET WORKING)
- **File `src/ampe/os/windows/Skt.zig`** — Three changes applied:
  1. Added `connecting: bool = false` field (line 9)
  2. Rewrote `connect()` (lines 68-109): On first call, `connect()` returns `WSAEWOULDBLOCK` → sets `connecting = true`, returns `false`. On subsequent calls, uses `WSAPoll(@ptrCast(&pfd), 1, 0)` with `POLL.WRNORM` to check completion without re-calling `connect()`.
  3. Added `skt.connecting = false;` reset at top of `close()` (line 161)

- **File `src/ampe/os/windows/stage3_stress.zig`** — Three changes (applied in earlier sessions):
  1. Client connect loop uses `Skt.connect()` retry (lines 81-85)
  2. Message counting: `messages_handled += @divFloor(...)` (line 163)
  3. Consecutive idle timeout tracking with break after 3 (lines 109-127)

### Test Result After Step 1
- `zig build -Doptimize=Debug` — **PASSES** (compiles clean)
- `zig build test -freference-trace --summary all -Doptimize=Debug` — **STILL HANGS** at "Polling... (handled 0/50)"
- The WSAPoll approach compiled successfully but **did not fix the hang**.

### Diagnosis of Why It Still Fails
The client threads are still not getting through. Possible reasons to investigate:
1. **WSAPoll may not work reliably for connect completion on Windows 10** — Microsoft docs have caveats about WSAPoll bugs on older Windows. May need `select()` instead, or `getsockopt(SO_ERROR)` after `WSAPoll`.
2. **The server socket uses `listen()` but the server poll loop uses AFD_POLL_ACCEPT on IOCP** — the clients may be connecting fine, but the **server never sees the ACCEPT event** from AFD. Need to add diagnostic prints inside the client thread to confirm whether `connect()` returns `true`.
3. **Timing**: The server's `listen()` + IOCP arm may not be ready by the time clients try to connect. The 10ms sleep in the retry loop may not be enough, or the listen socket may need to be fully armed before spawning clients.
4. **The poll timeout in the server is 5000ms** but is being called in a tight loop — check if `AfdPoller.poll()` is actually blocking or returning immediately with 0.

### Recommended Next Steps
1. **Add diagnostic prints** to the client thread: print after `connect()` returns `true`, print if `connect()` returns error, print before/after `send`. This will reveal whether clients connect at all.
2. **Add diagnostic prints** to the server: print when `clients_accepted` increments, print raw `removed` count from `poll()`.
3. If clients DO connect but server doesn't see ACCEPT: the issue is in `AfdPoller` / AFD arming, not in `Skt.connect()`.
4. If clients DON'T connect: try replacing `WSAPoll` with `select()` for the writability check, or try `getsockopt(SOL_SOCKET, SO_ERROR)` after WSAPoll reports writable.

### Key API References (verified in zig 0.15.2 stdlib)
- `ws2_32.WSAPoll(fdArray: [*]WSAPOLLFD, fds: u32, timeout: i32) i32` — at `ws2_32.zig:2204`
- `ws2_32.pollfd` = `WSAPOLLFD` — `{ fd: SOCKET, events: SHORT, revents: SHORT }` at `ws2_32.zig:1177`
- `ws2_32.POLL.WRNORM = 16`, `.ERR = 1`, `.HUP = 2` — at `ws2_32.zig:847`

## Verification Commands
```
zig build -Doptimize=Debug
zig build test -freference-trace --summary all -Doptimize=Debug
zig build -Doptimize=ReleaseFast
zig build test -freference-trace --summary all -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-linux
```

## Critical Context for Successor
- **Author's Directive:** Read **Section 0** of `os/windows/ACTIVE_KB.md` first.
- **NEVER use git commands** — user manages version control manually.
- **Verification:** Maintain the "Debug build -> Debug test -> ReleaseFast build -> ReleaseFast test" rule.
- **Sandwich verification:** Also verify Linux cross-compile after Windows fixes.
