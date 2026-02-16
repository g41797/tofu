# Strategy: wepoll Migration & Reactor Unification

**Date:** 2026-02-16
**Status:** ACTIVE SHIFT

---

## 1. The Decision: wepoll as Bridge
To unify the Reactor backends for Linux and Windows, the project will move to an `epoll`-style interface globally.
- **Windows:** Integrate the `wepoll` C library as a git submodule. This provides a battle-tested `epoll` shim over `AFD_POLL`.
- **Linux:** Migrate from `poll()` to native `epoll`.
- **Future:** Eventually replace the `wepoll` C dependency with a 100% native Zig implementation using the logic derived in the `PinnedState` analysis.

---

## 2. Technical Logic (Synthesized from Architectural Review)

### A. The "Moving vs. Fixed" Target Problem
- **Problem:** `AutoArrayHashMap` moves `TriggeredChannel` objects on resize, invalidating kernel pointers.
- **Solution:** Use **PinnedState** (heap-allocated, stable memory) for all kernel-facing structs (`IO_STATUS_BLOCK`, `AFD_POLL_INFO`).
- **ApcContext:** Use the **Stable Heap Pointer** to the `PinnedState` as the completion context.

### B. Incarnation Safety (The Recycling Race)
- **The Risk:** `SocketHandle` (or `ChannelNumber`) reuse by the OS before a previous `AFD_POLL` completion arrives.
- **Defense 1 (Physical):** The **Zombie List**. Never `destroy` a `PinnedState` while `is_pending == true`. Move it to a cleanup list and wait for `STATUS_CANCELLED`.
- **Defense 2 (Logical):** The **Generation Check**. Store a unique `mid` (MessageID) in the `PinnedState`. On completion, verify `pinned.mid == current_channel.mid`. If they differ, it's a "ghost" completion from a previous life; discard it.

---

## 3. ChatGPT Advice (Architectural Alignment)
The Reactor logic is already "epoll-friendly" because it separates **Desired Interest** (`exp`) from **Activated Triggers** (`act`).
- **Refactor Surface:** Isolated to `Poller.waitTriggers()`. No change needed in `Reactor.zig`.
- **Strategy:** Start with "Option A" (Sync interest every loop via `epoll_ctl MOD`) to mimic `poll` behavior safely, then optimize to "Option B" (Lazy updates) later.

---

## 4. Operational Shifts
- **Windows IOCP Native Port:** Postponed in favor of `wepoll` integration.
- **GitHub CI:** Windows CI is to be disabled to focus on the local migration.
- **Dependencies:** Add `wepoll` as a git submodule.
