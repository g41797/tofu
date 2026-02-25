# Strategy: wepoll Migration & Reactor Unification

**Date:** 2026-02-25
**Status:** COMPLETED (Baseline Implementation)

---

## 1. The Decision: wepoll as Bridge
To unify the Reactor backends for Linux and Windows, the project has moved to an `epoll`-style interface globally.
- **Windows:** Integrated `wepoll` C library as a git submodule in `src/ampe/os/windows/wepoll`.
- **Linux:** Migrated from `poll()` to native `epoll`.
- **Future:** Eventually replace the `wepoll` C dependency with a 100% native Zig implementation using the logic derived in the `PinnedState` analysis.

---

## 2. Technical Implementation

### A. Submodule Integration
The `wepoll` library is included as a git submodule. It is compiled into the `tofu` library and tests specifically for Windows targets.

### B. Unified Poller API
`src/ampe/poller.zig` (via `PollerOs`) now dynamically selects the backend:
- `.epoll` for Linux.
- `.wepoll` for Windows.
- `*anyopaque` is used for the port handle to accommodate both integer FDs and pointer HANDLEs.

### C. Build System Logic
`build.zig` automatically selects the appropriate ABI:
- **Host=Linux, Target=Windows:** Uses `gnu` ABI (avoids SDK requirements).
- **Host=Windows, Target=Windows:** Uses `msvc` ABI (native performance).

---

## 3. Verification Record

### A. The "Sandwich Build" (2026-02-25)
1. **Linux Build:** `zig build -Dtarget=x86_64-linux` -> **PASS**
2. **Windows Cross-Build:** `zig build -Dtarget=x86_64-windows` -> **PASS** (via `gnu` ABI)
3. **Linux Build:** `zig build -Dtarget=x86_64-linux` -> **PASS**

### B. Unit Testing
- Linux unit tests (`zig build test`) are fully functional on native `epoll`.
- Windows runtime verification is the next priority.

---

## 4. Current Constraints
- **UDS on Windows:** Temporarily disabled in `SocketCreator.zig` and `Notifier.zig` (TCP loopback fallback used for Notifier).
- **Outdated POCs:** Old Windows native AFD POCs are disabled in `build.zig` and `os_windows_tests.zig` as they are now obsolete.
- **Thin Skt:** The abstraction is maintained; `Skt` remains thin, with polling state managed by `PollerOs`.
