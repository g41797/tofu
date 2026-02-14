# Windows Port: Questions & Clarifications (004)

**Date:** 2026-02-13
**Status:** Stage 2 POC Complete

---

## 1. Progress Update

- **Stage 2 POC Complete:** `os/windows/poc/stage2_echo.zig` successfully demonstrates a full echo server/client cycle using IOCP + AFD_POLL.
- **Key Findings:**
    - **ApcContext Round-trip:** Passing `self` as `ApcContext` in `NtDeviceIoControlFile` works perfectly for retrieving the socket context in the event loop.
    - **Re-arming Timing:** Re-arming `AFD_POLL` *after* the I/O call (`accept`/`recv`) is more efficient on Windows as it prevents immediate "double" completions while still maintaining level-triggered semantics.
    - **Verification:** All current POCs (Stage 0, 1, 2) pass in both **Debug** and **ReleaseFast** modes.

---

## 2. New Questions & Concerns

### Q4.1: Stage 3 Stress Parameters
For Stage 3 (Stress & Cancellation), how many concurrent connections should the POC handle? Is 20-50 enough to prove feasibility, or should we aim higher (e.g., 100+)?

### Q4.2: NtCancelIoFileEx
I plan to add `NtCancelIoFileEx` to `ntdllx.zig` for Stage 3. This is essential for graceful shutdown and socket removal. Any objections?

### Q4.3: Memory Management for Channels
In Stage 2, I used a simple heap allocation for connection contexts. For the production Reactor, I intend to use a pre-allocated pool of `Channel` structures (matching the message pool size). Does this align with the intended architecture?

---

## 3. Notes for Developer
- `ACTIVE_KB.md` updated to Version 010.
- `Decision Log` updated with finalized memory and completion key designs.
- Ready to proceed to Stage 3.
