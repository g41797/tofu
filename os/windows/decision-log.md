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
- **Standard Library First:** Before adding a new definition (struct, constant, or function) to a custom binding file (`ntdllx.zig`, `wsax.zig`), always check if it already exists in the Zig standard library (`std.os.windows.*`). Use the standard library definition if available. Custom files should only contain what is truly missing.
- Prefer Zig Standard Library for OS-independent functionality: If an existing OS-independent standard library function can achieve the required functionality, use it instead of OS-dependent APIs (e.g., use `std.net` for sockets instead of `ws2_32`). Only resort to OS-dependent APIs when the standard library does not support the required functionality.

---

## 4. Pending Decisions (To be resolved during POC)

- **Memory ownership for AFD_POLL_INFO:** To be finalized during Stage 2 POC (Full Echo).
- **Completion key design:** To be finalized during Stage 2 POC.

## 5. Git usage

- Git usage **disabled**

---

## 6. Build & Test Commands

All builds and tests MUST use the following commands from the project root:

- **Build (Debug):** `zig build -Doptimize=Debug`
- **Build (ReleaseFast):** `zig build -Doptimize=ReleaseFast`
- **Test (Debug):** `zig build test -freference-trace --summary all -Doptimize=Debug`
- **Test (ReleaseFast):** `zig build test -freference-trace --summary all -Doptimize=ReleaseFast`

These are the only sanctioned build/test invocations. Do not omit flags or invent alternatives.

---

## 7. Mandatory Testing & Verification Rule

**Every change** to the codebase MUST be validated against **both** optimization levels before being considered complete:

1. **Build before test:** Always run `zig build` first. Only proceed to `zig build test` after the build succeeds. A failing build means tests must not be attempted.
2. **Debug first:** Always build and test with `-Doptimize=Debug` first. Debug mode enables safety checks, bounds checking, and produces clear error messages. All debugging MUST be done in Debug mode.
3. **ReleaseFast second:** After Debug passes, build and test with `-Doptimize=ReleaseFast` to catch optimization-sensitive issues (undefined behavior, uninitialized memory, miscompilations).
4. **Both must pass:** A change is only valid if both Debug and ReleaseFast builds and tests succeed. If either fails, the change must be fixed before proceeding.
5. **No exceptions:** This rule applies to POC code, production code, refactoring, and any other modification.

**Full verification sequence (in order):**
```
zig build -Doptimize=Debug
zig build test -freference-trace --summary all -Doptimize=Debug
zig build -Doptimize=ReleaseFast
zig build test -freference-trace --summary all -Doptimize=ReleaseFast
```
Each step must succeed before proceeding to the next.

---
*End of Decision Log*
