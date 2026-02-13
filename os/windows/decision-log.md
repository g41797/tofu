# Windows Port Decision Log

This document tracks the settled architectural and technical decisions for the tofu Windows port project.

---

## 1. Project Scope & Targets

- **Platform Support:** Windows 10+ only.
- **Goal:** Port the `tofu` Reactor from Linux (POSIX poll) to Windows (IOCP + AFD_POLL).
- **Zig Version:** 0.15.2.
- **Target Scale:** < 1,000 connections.
- **Transports:** TCP first; AF_UNIX later.
- **Internal Model:** Single-threaded I/O thread (Reactor) with queue-based application interface (no public callbacks).

---

## 2. Technical Decisions (v6.1)

- **Event Notification:** Use **IOCP** as the core mechanism (`NtCreateIoCompletion`).
- **Readiness Detection:** Use **AFD_POLL** issued directly on socket handles (no `\Device\Afd`).
- **AFD_POLL Re-arming (Critical):** **Immediately re-issue** a new AFD_POLL upon completion, **before** processing any I/O. This ensures the readiness state is always tracked by the kernel.
- **Cross-thread Signaling:** Map `updateReceiver()` and internal Notifier to manual IOCP completion packets (`NtSetIoCompletion`).
- **LSP Compatibility:** Use `SIO_BASE_HANDLE` to obtain the real NT handle for AFD operations. **Fail loudly** if the base handle cannot be obtained.
- **No Callbacks:** The Windows backend will populate `TriggeredChannel.act` flags directly, allowing the existing loop logic to remain platform-agnostic.
- **POC Infrastructure:** Use a dedicated `win_poc` module (defined in `os/windows/poc/poc.zig`) for feasibility gates.
- **Extended NT Bindings:** Create and maintain `os/windows/ntdllx.zig` to house `extern` definitions for NT APIs (e.g., `NtCreateIoCompletion`) and related structures not available in the standard library. This file is the central source for low-level, non-standard Windows API calls.

---

## 3. Implementation Philosophy

- **NT-First:** Prefer Native NT APIs (`ntdll.dll`) over Win32, following the Zig standard library and Spec v6.1.
- **Reactor Pattern Preservation:** Do NOT switch to a native IOCP Proactor model.
- **Consolidated Spec:** Spec v6.1 is the authoritative reference, superseding all previous analysis documents (001-003).
- **Binding Naming Convention:** For custom NT API bindings (e.g., in `ntdllx.zig`), `extern` declarations should use `camelCase` (e.g., `ntCreateIoCompletion`). These are then exposed publicly via wrappers using `PascalCase` (e.g., `NtCreateIoCompletion`) to maintain consistency with Zig's standard library conventions.
- **Explicit Typing:** Always specify the type in a constant or variable declaration. Do not rely on type inference (e.g., `const x: u32 = 1;` instead of `const x = 1;`).
- **Explicit Dereferencing:** Always dereference pointers explicitly with `.*`. Do not rely on implicit dereferencing.

---

## 4. Pending Decisions (To be resolved during POC)

- **Memory ownership for AFD_POLL_INFO:** To be finalized during Stage 2 POC (Full Echo).
- **Completion key design:** To be finalized during Stage 2 POC.

## 5. Git usage

- Git usage **disabled**

---
*End of Decision Log*
