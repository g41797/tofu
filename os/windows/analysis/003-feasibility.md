# Reactor-over-IOCP Analysis Report (003) - Feasibility & Strategic Roadmap

**Date:** 2026-02-12
**Subject:** Feasibility Gates, POC Strategy, and Risk Mitigation
**Goal:** Prevent "Obsolete Work" by validating the core technical premise before implementation.

---

## 1. The "Feasibility First" Mantra

Building a Reactor (readiness-based) on top of IOCP (completion-based) using `AFD_POLL` is an "off-road" path in Windows development. While battle-tested in `libuv` and `mio`, doing it from scratch in Zig 0.15.2 carries high risk due to:
- **ntdll definitions**: Zig's `std.os.windows` may have incomplete or slightly differing signatures for the necessary undocumented APIs.
- **One-shot re-arming**: If the re-arming logic for `AFD_POLL` is flawed, the event loop will "go dark" or spin at 100% CPU.
- **Handle behavior**: The behavior of `AFD_POLL` when issued directly on a socket handle (without `\Device\Afd`) must be verified on the specific Windows versions targeted.

---

## 2. Staged Feasibility Testing (The "Proof-of-Concept" Gates)

**Do not start refactoring `tofu` until Stage 2 is green.**

### Stage 0: The "Wakeup" Test (Manual Completion)
- **Goal:** Verify Zig can create an IOCP, block on it, and be woken up by another thread using a manual packet.
- **Why:** Confirms `NtCreateIoCompletion`, `NtRemoveIoCompletionEx`, and `NtSetIoCompletion` are correctly bound and functional.
- **Success Criteria:** A thread blocks in a loop; another thread calls `wake()`; the loop unblocks immediately.

### Stage 1: The "Accept" Test (The First Reactor Event)
- **Goal:** Use `AFD_POLL` to detect an incoming TCP connection.
- **Why:** `AFD_POLL_ACCEPT` is the simplest readiness event. It doesn't involve complex buffer management.
- **Success Criteria:** A listener socket is registered; a client connects; the IOCP returns a completion packet with the `AFD_POLL_ACCEPT` bit set.

### Stage 2: The "Echo" Test (Bidirectional Readiness)
- **Goal:** Detect `AFD_POLL_RECEIVE` and `AFD_POLL_SEND` and perform non-blocking I/O.
- **Why:** This is the core of the Reactor. We must prove we can:
  1. Detect data. 2. `recv()` it. 3. Detect writability. 4. `send()` it. 5. **RE-ARM** the poll correctly.
- **Success Criteria:** A 1MB stream is echoed back and forth without hanging or dropping bytes.

### Stage 3: The "Stress & Leak" Test
- **Goal:** Rapidly register/deregister sockets and spam `NtCancelIoFileEx`.
- **Why:** Handles and `IO_STATUS_BLOCK` memory management in `AFD_POLL` are notoriously tricky to get right during cancellation.
- **Success Criteria:** 10,000 connections/disconnections without a handle leak or memory growth.

---

## 3. POC vs. Production Code Strategy

### The "Quick and Dirty" POC
**Recommendation:** Create a **standalone, single-file POC** (e.g., `tools/win_iocp_poc.zig`).
- **Style:** Procedural, "dirty" code is acceptable here. Focus on the syscall logic, not the `tofu` architecture.
- **Discardability:** This code **will not** be used in production. Its only purpose is to generate a "Working Knowledge" of the binary structures and syscall behavior.
- **Why?** It is much easier to debug a 200-line POC than a refactored 5,000-line library.

### The Production Implementation
Once the POC works, implement the code in `src/ampe/os/windows/` using the verified patterns. This code will follow `tofu`'s coding standards, error handling, and memory management.

---

## 4. Test Placement & Implementation

### 1. POC Location: `os/windows/poc/`
- Implement core logic in separate Zig files for each stage.
- These implementations are "Proof of Concept" and will be refined during production integration.

### 2. Implementation Tests: `tests/os_windows_tests.zig`
- Create a dedicated test runner file in the `tests/` directory.
- This file should conditionally import and run the POC tests when `builtin.os.tag == .windows`.
- This ensures the `zig build test` command can run these tests in the Windows CI environment.

### 3. Integration Tests: `tests/ampe/`
- Once the Windows backend is plugged in, run the **existing** Linux test suite.
- If `tofu` is truly Reactor-abstracted, the same tests that pass on Linux should now pass on Windows without modification.

---

## 5. Final Verdict: Is it worth it?

**Yes.**
The Reactor pattern is the soul of `tofu`. Converting it to a Proactor (native IOCP) would require a total rewrite of the messaging logic. The `AFD_POLL` trick allows `tofu` to keep its "Mantra" (Single-threaded Reactor, queue-based) while gaining the performance and scalability of Windows IOCP.

**Action Plan:**
1. Create `tools/poc/windows/stage0_wake.zig`.
2. Create `tools/poc/windows/stage1_accept.zig`.
3. Create `tools/poc/windows/stage2_echo.zig`.
4. Only then, begin the architectural refactoring identified in `reactor-analasys-002.md`.

*End of Report*
