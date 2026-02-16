**AGENT HANDOVER CHECKPOINT**
**Current Date:** 2026-02-16
**Last Agent:** Gemini CLI (Investigation of Pointer Stability)
**Active Phase:** Phase III (Windows Implementation)
**Active Stage:** Critical Bug Fix - Addressing Pointer Stability

## Current Status
- **Structural Refactoring (Phase II) COMPLETE.**
- **Windows Poller Implementation (v1) DONE:** Implemented `waitTriggers` using IOCP and `AFD_POLL`.
- **CRITICAL ISSUE IDENTIFIED:** Identified a fundamental architectural mismatch between the Reactor's use of `std.AutoArrayHashMap` (which moves `TriggeredChannel` objects in memory) and Windows IOCP/AFD_POLL (which holds pointers to these objects in the kernel). This causes random panics and memory corruption during map growth or `swapRemove`.
- **Documentation:** Created `os/windows/analysis/doc-reactor-poller-negotiation.md` detailing the issue and proposed solutions (Stable Pointers vs. Indirection).

## Latest Work (2026-02-16 â€” Investigation & Planning)

### What Was Done
- **User Manual Changes:** Reactor tests were removed from the Windows test suite and the overall test execution order was modified.
- **Root Cause Analysis:** Traced "union field access" panics to pointer instability in `TriggeredChannelsMap`.
- **Attempted (and Reverted) Fix:** Experimented with synchronous multi-polling. Reverted because it blocked the single reactor thread, preventing `Notifier` wakeups.
- **Restored IOCP Architecture:** Reverted `poller.zig` and `Skt.zig` to the async IOCP model, but added a `.dumb` tag check in `processCompletions` as a temporary safety measure.
- **Architectural Documentation:** Wrote a comprehensive guide on Reactor-Poller negotiation for both Linux and Windows.
- **Investigation Plan:** Created `os/windows/analysis/plan-investigation-reactor-poller.md` for future agents.

### Verification (CURRENT STATE)
```
Windows Debug build+test (41/46)   â€” FAIL (Random Panics due to instability)
Linux cross-compile (Build only) â€” PASS
```

## Next Steps for Successor
1.  **Solve Pointer Instability:** Implement one of the strategies from `doc-reactor-poller-negotiation.md`.
    *   *Option A (Stable Map):* Modify `Reactor.trgrd_map` to store pointers `*TriggeredChannel` instead of values.
    *   *Option B (Indirection):* Update `waitTriggers` to pass unique IDs (e.g. Channel Numbers) as `ApcContext` and look them up upon completion.
2.  **Verify Stability:** Run `reactor_tests.test.handle reconnect single threaded` (which has 1000 retries and triggers many map removals) to confirm the fix.
3.  **Fix Windows UDS:** Address the `createUDSListenerSocket failed` error by fixing or bypassing `std.net.Address.initUnix` on Windows.

## Critical Context for Successor
- **DO NOT** attempt synchronous waiting on `IOCTL_AFD_POLL` inside the reactor loop; it will hang the `Notifier`.
- **Pointer Stability is the #1 priority.** The current `ApcContext` passing `&tc` is unsafe because `tc` moves.
- **Log Management:** Use `zig build test --summary all -- -f "reconnect"` to isolate the stability tests.

## Verification Commands
```
zig build test --summary all -Doptimize=Debug -- -f "reconnect"
zig build test --summary all -Doptimize=ReleaseFast -- -f "reconnect"
```
