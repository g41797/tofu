# Reactor-over-IOCP Specification v6.1
**Project:** tofu Windows 10+ Port  
**Version:** 6.1  
**Date:** 2026-02-12  
**Status:** Final consolidated specification (resolves all prior contradictions)

## 1. Project Goal & Core Mantra

**tofu** is a message-oriented networking library in Zig that strictly follows the **Reactor pattern**:
- Single dedicated I/O thread
- Readiness-based event loop
- Queue-based API (no callbacks exposed to application code)
- Message pool with strict memory limits (max 128 KiB per message)

**Goal:** Add native Windows 10+ support **without changing the public API or core philosophy**.

**Development Environment:** 
- Cross-platform development on **Linux** and **Windows 10**.
- The codebase must always build and pass tests on Linux while Windows work is in progress.
- Windows-specific artifacts (POCs, linkage, tests) must be **conditionally included** in `build.zig` to avoid breaking non-Windows environments.

**Chosen approach:** Use **IOCP + AFD_POLL** to emulate Reactor semantics (readiness notifications) on top of Windows’ native Proactor model.

**Non-negotiable constraints:**
- 100% native Zig (Zig 0.15.2), no C dependencies
- NT-first philosophy (prefer ntdll where appropriate)
- Preserve exact same threading and queue model as Linux
- Must pass existing `tests/ampe/` suite on Windows without modification

## 2. Resolved Contradictions (v6.1 Decisions)

This section explicitly closes all contradictions identified in prior analysis:

### 2.1 Polling Mechanism
- **Old assumption:** tofu uses epoll  
- **Reality:** Uses `std.posix.poll`  
- **v6.1 Decision:** Irrelevant for Windows. We use AFD_POLL. Linux remains on poll.

### 2.2 Internal Reactor Wakeup / Notifier
- **Old assumption:** `updateReceiver()` signals the Reactor thread  
- **Reality:** It signals application threads. Reactor wakeup uses a loopback socket pair.  
- **v6.1 Decision:** On Windows, replace socket-based Notifier with direct `NtSetIoCompletion` posting to the Reactor’s IOCP handle.

### 2.3 API Style (Callbacks vs Loop-driven)
- **Old assumption:** ReadinessCallback-based API  
- **Reality:** tofu Reactor owns the loop and processes `TriggeredChannel` objects internally.  
- **v6.1 Decision:** **No callbacks.** AFD_POLL completions must populate existing `TriggeredChannel.act` fields.

### 2.4 Re-arming Semantics
- **Old assumption:** Not deeply specified  
- **Reality:** poll recalculates every iteration; AFD_POLL is one-shot.  
- **v6.1 Decision:** See detailed rule in section 4.4.

### 2.5 AF_UNIX / Abstract Namespace
- **Old assumption:** Portable  
- **Reality:** Linux-specific abstract namespace  
- **v6.1 Decision:** Internal Notifier on Windows uses IOCP posting (no socket). External AF_UNIX support is deprioritized (TCP first).

### 2.6 Command Injection Redundancy
- **Old assumption:** New "Command" tagged union  
- **Reality:** Existing `submitMsg` + `SpecialMaxChannelNumber` mechanism  
- **v6.1 Decision:** Integrate all cross-thread commands into the existing message flow using distinguished completion keys.

**All contradictions are now resolved.**

## 3. Architecture (Windows Backend)

- **Poller abstraction:** `src/ampe/poller.zig` becomes a facade (`builtin.target.os.tag`).
  - Linux → `os/linux/poller.zig` (existing)
  - Windows → `os/windows/poller.zig` (IOCP + AFD_POLL)
- **Notifier abstraction:** Platform-specific.
  - Linux → socket pair
  - Windows → `NtSetIoCompletion` on Reactor IOCP
- **Socket type:** OS-agnostic `Socket` with `InvalidSocket` constant.
- **TriggeredChannel:** Remains central. Windows backend populates `.act` flags.

## 4. Core Technical Design (Windows)

### 4.1 IOCP Setup
One IOCP per Reactor (`NtCreateIoCompletion` or `CreateIoCompletionPort`). All sockets associated with it.

### 4.2 AFD_POLL Usage
- Use **direct per-socket AFD_POLL** on the base socket handle (no `\Device\Afd`).
- Obtain base handle via `WSAIoctl(SIO_BASE_HANDLE)`.
- Fail loudly if `SIO_BASE_HANDLE` fails (LSP incompatibility).
- Each socket maintains its own `IO_STATUS_BLOCK`.

### 4.3 Event Loop Flow
1. Wait on IOCP (`NtRemoveIoCompletionEx`).
2. For each completion:
   - User key → internal command / wakeup
   - AFD_POLL → map events → re-arm → process I/O

### 4.4 Re-arming Rule (Critical)

AFD_POLL is one-shot but level-triggered in semantics.

**Rule:**
- Upon AFD_POLL completion, **immediately re-issue a new AFD_POLL** for the socket **before** processing the I/O events.
- Then perform non-blocking I/O (recv/send) based on the events from the just-completed poll.
- Never leave a socket without a pending AFD_POLL unless intentionally removed.

Because the kernel maintains the true readiness state, any events that occur during I/O processing will cause the newly re-armed AFD_POLL to complete immediately (often synchronously). In tofu’s single-threaded, message-oriented loop the unprotected window is negligible.

### 4.5 Cancellation & Cleanup
Use `NtCancelIoFileEx` when removing sockets. Wait for cancellation before freeing state.

## 5. Implementation Stages (Mandatory Gates)

**Phase I – Feasibility (POC)**
- Stage 0: Wakeup via `NtSetIoCompletion` (done)
- Stage 1: AFD_POLL_ACCEPT on listener
- Stage 2: Full echo (receive + send + correct re-arming)
- Stage 3: Stress + cancellation

**Phase II – Refactoring**  
Extract platform backends (`os/linux/`, `os/windows/`).

**Phase III – Production Implementation**  
Full WindowsReactor.

**Phase IV – Verification**  
Run full test suite on Windows.

## 6. Key Decisions (Consolidated)

- Windows 10+ only
- TCP first; AF_UNIX later
- Fail on SIO_BASE_HANDLE failure
- Use existing message pool
- Prefer NT APIs where stable
- All POCs in `os/windows/poc/` as `win_poc` module

## 7. References

- **Zig Issue #31131**: [Prefer the Native API over Win32](https://github.com/ziglang/zig/issues/31131)
- **TigerBeetle Windows IO**: [Implementation Reference](https://github.com/tigerbeetle/tigerbeetle/blob/main/src/io/windows.zig)
- **Zig Devlog**: [NT-first Philosophy](https://ziglang.org/devlog/2026/#2026-02-03)
- **Zig Issue #1840**: [Platform Policy](https://github.com/ziglang/zig/issues/1840)
- **Len Holgate**: [Socket readiness without \Device\Afd](https://lenholgate.com/blog/2024/06/socket-readiness-without-device-afd.html)
- **wepoll**: [AFD_POLL reference](https://github.com/piscisaureus/wepoll)

**This document (v6.1) supersedes all previous specifications, questions, and analysis files.**  
All future work must align with it.

## 8. Glossary of Architectural Terms

To ensure consistent implementation across backends, the following terms are strictly defined:

- **Interest (Declarative Interest):** The set of events (READ, WRITE, etc.) the business logic *currently* desires for a socket. In `tofu`, interest is recalculated from scratch every loop iteration. If the message pool is full, read interest is not declared (**Backpressure**).
- **One-Shot:** A notification mechanism (like `AFD_POLL`) that is consumed upon completion. The kernel provides no further updates until a new request is issued.
- **Re-arm:** The act of issuing a new `AFD_POLL` request immediately after a completion. This "re-arms" the notification for the next event.
- **Level-Triggered (LT):** A trigger that fires as long as the condition is met (e.g., data is in the buffer). `AFD_POLL` is LT; if re-armed while data remains, it completes immediately.
- **Edge-Triggered (ET):** A trigger that fires only when state *changes* (e.g., new data arrives). Requires **Draining** the socket to avoid "missing" the next trigger.
- **Drain:** The process of calling `recv`/`send` repeatedly until it returns `WouldBlock` or `EAGAIN`.
- **Readiness vs. Completion:** `tofu` is a **Readiness** (Reactor) system. It uses Windows **Completion** (IOCP) primitives solely to deliver readiness notifications via `AFD_POLL`, rather than using overlapped I/O.

*End of Specification v6.1*
