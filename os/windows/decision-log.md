# Windows Port Decision Log

This document tracks the settled architectural and technical decisions for the tofu Windows port project.

---

## 1. Project Scope & Targets

- **Platform Support:** Windows 10+ only.
- **Goal:** Port the `tofu` Reactor from Linux (POSIX poll) to Windows (IOCP + AFD_POLL).
- **Zig Version:** 0.15.2.
- **Target Scale:** < 1,000 connections.
- **Message Size Limit:** 128 KiB per message.
- **Transports:** TCP and Unix Domain Sockets (AF_UNIX).
- **Internal Model:** Single-threaded I/O thread (Reactor) with queue-based application interface (no public callbacks).

---

## 2. Technical Decisions

- **Event Notification:** Use **IOCP** as the core mechanism.
- **Readiness Detection:** Use **AFD_POLL** issued directly on socket handles (no `\Device\Afd`).
- **Timers:** Use the `timeout` parameter of the IOCP wait function (`NtRemoveIoCompletionEx`).
- **Cross-thread Signaling:** Map `updateReceiver()` and engine notifications to manual IOCP completion packets (`NtSetIoCompletion`).
- **Memory Management:** Utilize the existing `tofu` Message Pool to manage and limit memory usage.
- **LSP Compatibility:** Attempt to use `SIO_BASE_HANDLE` to bypass Layered Service Providers; fail clearly if the base handle cannot be obtained for AFD operations.
- **POC Infrastructure:** Use a dedicated `win_poc` module (defined in `os/windows/poc/poc.zig`) to manage Proof-of-Concept implementations. This avoids Zig module boundary violations when importing POCs into the main test suite.

---

## 3. Implementation Philosophy

- **NT-First:** Prefer Native NT APIs (`ntdll.dll`) over Win32 where feasible, following the Zig standard library's direction.
- **Reactor Pattern Preservation:** Maintain the Reactor (readiness-based) model despite IOCP's native Proactor design to ensure minimal impact on the existing `tofu` messaging logic.
- **Staged Validation:** Mandatory Proof-of-Concept (POC) phases for core primitives before integration into the production codebase.

---

## 4. Pending Decisions (To be resolved during POC)

- **Memory ownership for AFD_POLL_INFO:** Decision deferred until Stage 2 POC.
- **Completion key design:** Decision deferred until Stage 2 POC.
- **AF_UNIX Priority:** TCP implementation first; UDS implementation to follow once core IOCP logic is stable.

---
*End of Decision Log*
