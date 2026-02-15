
# tofu Cross-Platform Reactor Architecture – External AI Review Brief

**Project:** tofu  
**Language:** Zig 0.15.2  
**Date:** 2026-02-15  
**Status:** Active Windows Port (IOCP + AFD_POLL)

---

# 1. Project Overview

`tofu` is a message-oriented networking library written in Zig.

Core characteristics:

- Single dedicated I/O thread
- Strict Reactor pattern
- No callbacks exposed to application code
- Queue-based API
- Fixed memory pool (max message size 128 KiB)
- Hard memory limits
- Deterministic behavior

The design goal is to support:

- Linux
- Windows 10+
- macOS (future)

Without changing public API or core philosophy.

---

# 2. Current Linux Backend (poll-based)

Linux implementation currently uses:

```
std.posix.poll
```

Behavior:

- Every loop iteration:
    - For each socket:
        - Recompute interest flags:
            - POLLIN if memory available
            - POLLOUT if send queue not empty
    - Call poll()
- No persistent registration
- No per-socket “armed” state
- Interest is derived purely from business logic

Important property:

> Interest is recomputed every loop from real business state.

There is no dependency on prior readiness state.

---

# 3. Windows Backend (Reactor over IOCP + AFD_POLL)

Windows 10+ only.

Architecture:

- One IOCP per reactor
- Each socket associated with IOCP
- Use AFD_POLL to emulate readiness semantics
- No overlapped WSARecv/WSASend completion model
- No callbacks
- Maintain TriggeredChannel abstraction

Important characteristics:

- AFD_POLL is one-shot
- Must be re-issued after completion
- Kernel readiness state persists
- Notification does not persist
- Non-blocking sockets only

Re-arming rule (current spec):

Upon AFD_POLL completion:
1. Immediately re-issue new AFD_POLL
2. Then process I/O

Unless read interest intentionally disabled.

---

# 4. Backpressure Requirement

Business rule:

Sometimes we must NOT read from socket if:

- No free memory in message pool

This is intentional backpressure.

Desired behavior:

- If memory exhausted:
    - Disable read interest
    - Do NOT re-arm AFD_POLL for READ
- When memory available:
    - Re-enable read interest
    - Re-issue AFD_POLL

Data must not be lost.  
Readiness notifications may be delayed.

---

# 5. Architectural Tension

Linux poll model:

- Interest recalculated each iteration
- No persistent kernel state
- No risk of forgetting to re-arm

Windows AFD_POLL:

- Requires persistent tracking
- Must reconcile desired interest with armed interest
- Can accidentally lose events if not re-armed

This introduces asymmetry between backends.

---

# 6. Possible Linux Migration

There is consideration to move Linux from:

```
poll → epoll (EPOLLET)
```

Reasons:

- Performance
- Align semantics with Windows AFD_POLL
- Enforce strict draining discipline
- Prepare for macOS kqueue

However:

Windows port is currently in active development.

Question:

Should epoll migration be postponed until Windows backend is complete?

---

# 7. Design Constraints

- Single-threaded reactor only
- No callbacks
- No hidden completion model
- Must preserve queue-based architecture
- Must preserve deterministic behavior
- No C dependencies
- Prefer NT APIs on Windows
- All platforms must pass same test suite

---

# 8. Core Questions for Review

Please analyze and answer:

## Q1 — Backpressure Semantics

Is it architecturally correct to:

- Leave a socket unarmed (no AFD_POLL pending)
- While memory is exhausted
- And re-arm later when memory becomes available?

Are there hidden race conditions or fairness risks?

---

## Q2 — Interest Derivation Model

Is this correct architectural rule?

```
Business logic computes desired interest each loop.
Backend reconciles kernel state to match desired interest.
```

Rather than:

```
Backend implicitly manages interest.
```

Is this the cleanest cross-platform abstraction?

---

## Q3 — Linux Migration Timing

Given:

- Windows backend is mid-development
- Linux poll backend is stable

Is it better to:

A) Finish Windows backend first, then migrate Linux to epoll  
or  
B) Migrate Linux to epoll now for semantic alignment

Evaluate from systems engineering risk perspective.

---

## Q4 — Readiness Emulation Correctness

Does:

IOCP + AFD_POLL + immediate re-arm

Correctly emulate readiness semantics equivalent to:

- epoll (edge-triggered)
- kqueue (EV_CLEAR)

Under single-threaded reactor constraints?

---

## Q5 — Lost Wakeup Risk

If:

- AFD_POLL completion occurs
- Business logic disables read interest
- Later re-enables and re-issues AFD_POLL

Can readiness be permanently lost?

Or does kernel readiness state guarantee eventual completion?

---

## Q6 — Cross-Platform Contract

Proposed unified contract:

- Non-blocking sockets
- Drain fully until EAGAIN
- Interest derived from business state
- Backend ensures kernel matches interest
- No reliance on implicit repeated readiness

Is this contract sufficient and minimal?

---

# 9. Expected Depth of Review

Please analyze at:

- Kernel semantics level
- Reactor theory level
- Race-condition analysis level
- Systems architecture level

Focus on correctness, not style.

---

# 10. Additional Context

Windows design uses:

- NtCreateIoCompletion
- NtRemoveIoCompletionEx
- NtCancelIoFileEx
- AFD_POLL with base socket handle
- No \Device\Afd open

Linux uses:

- std.posix.poll (currently)

macOS not yet implemented.

---

# 11. Objective

The goal is to ensure:

- No hidden correctness flaws
- No lost wakeups
- No fairness starvation
- No deadlocks under backpressure
- Clean cross-platform abstraction

---

# End of Brief
````
