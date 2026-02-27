# Tofu Cross-Platform Port: Master Roadmap

**Project:** tofu Linux/macOS/Windows support
**Date:** 2026-02-12 (last updated: 2026-02-27)
**Status:** Phase IV COMPLETE

---

## 1. Project Goal

Port the `tofu` messaging library from Linux (POSIX poll) to a fully cross-platform implementation supporting Linux (epoll), Windows 10+ (wepoll), and macOS/BSD (kqueue). The Reactor's single-threaded, queue-based architecture is maintained across all platforms.

---

## 2. Technical Documentation Index

1. **[Consolidated Specification](./spec.md)**
   - *The authoritative source of truth.* Resolves all prior architectural contradictions.
2. **[Decision Log](./decisions.md)**
   - *Focus:* Consolidated constraints and architectural choices.
3. **[Poller Design](./poller-design.md)**
   - *Focus:* Cross-platform poller architecture, dual-map indirection, backend comparison.
4. **[Windows Notes](./windows-notes.md)**
   - *Focus:* Windows-specific limitations, deviations, and verification status.
5. **[UDS Notes](./uds-notes.md)**
   - *Focus:* Unix Domain Socket support status per platform.
6. **[Reactor Knowledge Base](./reactor-kb.md)**
   - *Focus:* Deep-dive into Reactor internals.
7. **[Rules](./RULES.md)**
   - *Focus:* Mandatory rules for all contributors and AI agents.
8. **[Agent State](./AGENT_STATE.md)**
   - *Focus:* Current project status, session handover, and conceptual dictionary.
9. **[Open Questions](./QUESTIONS.md)**
   - *Focus:* Unresolved technical and architectural questions.

---

## 3. Execution Strategy (The Phased Path)

### Phase I: Feasibility (POC)
**Goal:** Prove `AFD_POLL` re-arming and `NtSetIoCompletion` wakeup logic works in Zig 0.15.2.
*Status:* **COMPLETE (2026-02-14)**.
- [x] Stage 0: Basic Wakeup (IOCP + NtSetIoCompletion)
- [x] Stage 1: TCP Listener Readiness (AFD_POLL)
- [x] Stage 1U: Unix Domain Sockets (UDS)
- [x] Stage 2: Concurrent TCP Connections
- [x] Stage 3: Full Stress (Non-blocking Send/Recv)

*Note:* POC files have been removed from the repo (they proved the IOCP path, which was superseded by wepoll). The outcome is captured in `decisions.md`.

### Phase II: Structural Refactoring
**Goal:** Prepare the codebase for multiple OS backends.
*Status:* **COMPLETE**.
- [x] Refactor Skt Facade: Extract Linux/Windows backends and encapsulate state.
- [x] Refactor Poller Facade: Extract Linux/Windows backends.
- [x] Implement `Notifier.zig` abstraction (single file with comptime branches).

### Phase III: Windows Implementation
**Goal:** Production-grade wepoll backend integrated and verified.
*Status:* **COMPLETE**.
- [x] wepoll integrated as Windows event backend
- [x] Abortive closure (`SO_LINGER=0`) on all Windows socket paths
- [x] Retry loops in `listen()` and `connect()` for Windows stability
- [x] Windows minimum version set to RS4 (build 17063) for UDS support

### Phase IV: Cross-Platform Poller Refactoring + Verification
**Goal:** Clean platform-agnostic architecture with kqueue (macOS/BSD) support.
*Status:* **COMPLETE (2026-02-26)**.
- [x] Created `src/ampe/poller/` directory with 7 files (common, triggers, core, 4 backends)
- [x] Updated `poller.zig` facade with comptime backend selection
- [x] macOS/BSD kqueue backend implemented
- [x] All cross-platform compilation fixes applied
- [x] Full sandwich verification: Linux tests + Windows/macOS cross-compile

---

## 4. Remaining Work (Post Phase IV)

1. **macOS CI Verification:** Trigger manual workflow to verify kqueue timeout fix + setLingerAbort fix.
2. **Native Windows Test:** Run full test suite on native Windows machine.
3. **UDS Stability on Windows:** Investigate AF_UNIX race conditions under high load.
4. **Legacy Cleanup:** Consider removing legacy `PollerOs()` wrapper after full verification.

---

## 5. Architectural Verdict

The project is **complete at the structural level**. The Reactor pattern in `tofu` is well-isolated via the `Triggers` abstraction — all OS-specific code is confined to the backends in `src/ampe/poller/`. Adding a new OS backend requires implementing one `*_backend.zig` file and one translation pair in `triggers.zig`. Nothing in the Reactor itself changes.

*End of Roadmap*
