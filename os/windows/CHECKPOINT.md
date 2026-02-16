**AGENT HANDOVER CHECKPOINT**
**Current Date:** 2026-02-16
**Last Agent:** Gemini CLI
**Active Phase:** Phase III (Windows Implementation)
**Active Stage:** Implementation of Stable Poller Pool

## Current Status
- **Root Cause Identified:** Pointer instability in `Reactor.trgrd_map` (`AutoArrayHashMap`) causes memory corruption when Windows Kernel (`AFD.sys`) holds pointers to objects that move.
- **Approved Strategy:** Indirection via `ChannelNumber` + Stable `PinnedState` pool in the `Poller`.
- **Code State:** IOCP baseline restored. `Skt` and `Poller` are ready for refactoring to the new strategy.
- **Tests:** `reactor_tests` are manually disabled on Windows by the user. Other tests pass.

## Implementation Details for Successor
- **Target File:** `src/ampe/os/windows/poller.zig`
- **Target File:** `src/ampe/os/windows/Skt.zig`
- **Lookup:** Use `rtr.trgrd_map.getPtr(returned_id)` in `processCompletions` to find the channel after it has potentially moved.
- **Stability:** The `PinnedState` objects must be allocated in a way that their address is stable (e.g. heap allocation per channel or a stable indexed pool).

## Documentation
- Read `os/windows/analysis/doc-reactor-poller-negotiation.md` for the technical explanation.
- Read `os/windows/analysis/plan-investigation-reactor-poller.md` for the finalized plan.

## Verification Goals
- Pass `reactor_tests.test.handle reconnect single threaded` (1000 cycles) without panics.
- Maintain Linux cross-compile compatibility.

## Latest Work (2026-02-16 — Reorganization & Lifecycle Management)

### What Was Done
- **Repository Reorganization:** Decoupled production code from POCs.
    - Moved all Windows stage POCs and `poc.zig` to `poc/windows/`.
    - Production files (Reactor, Skt, Poller, Notifier) remain in `src/ampe/`.
- **Winsock Lifecycle Management:** 
    - `Reactor.create` now calls `WSAStartup` on Windows.
    - `Reactor.destroy` now calls `WSACleanup` on Windows.
    - Manual Winsock setup was removed from `tests/reactor_tests.zig`.
- **Build System Update:** `build.zig` updated to point the `win_poc` module to its new location in `poc/windows/`.
- **Bug Fix:** Resolved `base_handle` registration issue in `afd.zig` that caused `CommunicationFailed` errors.

### Verification (CURRENT STATE)
```
Windows Debug build+test (35/35)   — PASS
Windows ReleaseFast build+test (35/35) — PASS
Linux cross-compile (Build only) — PASS
```
