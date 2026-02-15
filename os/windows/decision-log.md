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

- **Memory ownership for AFD_POLL_INFO:** Each `Channel` (or socket context) owns its own `AFD_POLL_INFO` and `IO_STATUS_BLOCK` structures. These must remain valid for the duration of the asynchronous operation. In the production implementation, these will be fields within the `WindowsChannel` or equivalent structure. (Finalized 2026-02-13)
- **Completion key design:** (Finalized 2026-02-13)
  - **CompletionKey:** Used to distinguish between different sources of completion.
    - `0`: AFD_POLL readiness notifications.
    - `1`: Internal Reactor signals (Wakeup, Notifier) via `NtSetIoCompletion`.
  - **ApcContext:** Used to pass the pointer to the specific `Channel` or context structure for the operation. This allows direct access to the `AFD_POLL_INFO` and `IO_STATUS_BLOCK` for re-arming.

- **Re-arming Timing (Refined 2026-02-13):** While Spec v6.1 suggested re-arming BEFORE I/O processing, Stage 2 POC showed that re-arming AFTER the I/O call (`accept`, `recv`) is more efficient as it avoids "double completions" (where the new poll completes immediately because the condition wasn't cleared yet). Since AFD_POLL is level-triggered in semantics, re-arming AFTER still catches any events that occurred during the I/O call.

## 5. Git usage

- Git usage **disabled** — MANDATORY RULE: AI agents MUST NOT execute any git commands (commit, push, add, status, etc.). The user manages version control manually.

---

## 6. Build & Test Commands

All builds and tests MUST use the following commands from the project root:

- **Build (Debug):** `zig build -Doptimize=Debug`
- **Build (ReleaseFast):** `zig build -Doptimize=ReleaseFast`
- **Test (Debug):** `zig build test -freference-trace --summary all -Doptimize=Debug`
- **Test (ReleaseFast):** `zig build test -freference-trace --summary all -Doptimize=ReleaseFast`

These are the only sanctioned build/test invocations. Do not omit flags or invent alternatives.

---

## 7. Mandatory Multi-Agent Coordination Rule

To ensure seamless handover between different AI agents (Gemini, Claude, etc.):

1.  **Shared State:** `CHECKPOINT.md` is the authoritative "short-term memory" for current task progress.
2.  **Read-Before-Act:** Every session MUST begin by reading `CHECKPOINT.md`.
3.  **Atomic Updates:** Update `CHECKPOINT.md` immediately after completing an atomic sub-task (e.g., successful compilation of a new POC).
4.  **Final Hand-off:** On session end, update `CHECKPOINT.md` with the "Interrupt Point" and "Next Immediate Steps".
5.  **Synchronization:** Ensure `ACTIVE_KB.md` is updated for long-term technical state, while `CHECKPOINT.md` stays focused on the immediate task loop.

---

## 8. Mandatory Testing & Verification Rule

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

## 8. Verified Technical Findings (from POC)

### 8.1 AFD_POLL Buffer: Same Buffer for Input and Output (Verified 2026-02-13)

`IOCTL_AFD_POLL` (0x00012024) uses `METHOD_BUFFERED`. All reference implementations (wepoll, c-ares, mio) pass the **same** `AFD_POLL_INFO` pointer for both the InputBuffer and OutputBuffer parameters of `NtDeviceIoControlFile`. Using separate buffers causes the output to never be populated — the kernel writes results back into the system buffer which maps to the input/output address. This was verified when Debug mode passed by accident (Zig `0xAA` undefined fill had the `AFD_POLL_ACCEPT` bit set) while ReleaseFast failed (`0x0`).

**Rule:** Always use the same `AFD_POLL_INFO` variable for both input and output in `NtDeviceIoControlFile`.

### 8.2 ApcContext Must Be Non-Null for IOCP Completion Posting (Verified 2026-02-13)

In the NT I/O model, when a file handle is associated with an IOCP:
- If `ApcContext` passed to `NtDeviceIoControlFile` is **non-null** → completion IS posted to IOCP.
- If `ApcContext` is **null** → completion is NOT posted (skip completion port behavior).

This is the NT equivalent of Win32's rule: pass an `OVERLAPPED*` for async I/O. The standard pattern is to pass `@ptrCast(&io_status_block)` as the ApcContext.

The `FILE_COMPLETION_INFORMATION` entry returned by `NtRemoveIoCompletionEx` will contain:
- `Key`: the CompletionKey set during `CreateIoCompletionPort` association.
- `ApcContext`: the pointer passed to `NtDeviceIoControlFile`.
- `IoStatus`: the completion status from the kernel.

**Verified:** `stage1_accept_integrated_iocp.zig` confirmed that the `ApcContext` pointer round-trips correctly — the value returned in `FILE_COMPLETION_INFORMATION.ApcContext` matches the `&io_status_block` pointer passed to `NtDeviceIoControlFile`. Tested in both Debug and ReleaseFast.

**Rule:** When issuing `NtDeviceIoControlFile` for AFD_POLL with IOCP completion, always pass a non-null `ApcContext` (typically `&io_status_block`). Pass `Event = null` so the completion goes to IOCP only.

### 8.3 IOCP-Integrated AFD_POLL_ACCEPT End-to-End (Verified 2026-02-13)

The full IOCP completion path for AFD_POLL_ACCEPT has been verified in `stage1_accept_integrated_iocp.zig`:

1. **Setup:** Create IOCP via `NtCreateIoCompletion`, obtain base socket handle via `SIO_BASE_HANDLE`, associate with IOCP via `CreateIoCompletionPort`.
2. **Issue AFD_POLL:** Call `NtDeviceIoControlFile` with `Event=null`, `ApcRoutine=null`, `ApcContext=@ptrCast(&io_status_block)`, same buffer for input/output.
3. **Wait:** `NtRemoveIoCompletionEx` with a 10-second relative timeout (`LARGE_INTEGER = -10 * 10_000_000`).
4. **Result:** Completion entry received with `Events=0x80` (AFD_POLL_ACCEPT), `IO_STATUS_BLOCK.Status=SUCCESS`, correct `ApcContext` round-trip.

This confirms that IOCP is a viable sole completion mechanism for AFD_POLL — no event handles needed. Verified in both Debug and ReleaseFast modes.

---

## 9. Notifier Refactoring (Decided 2026-02-15)

- **Facade Pattern:** `src/ampe/Notifier.zig` is a facade exporting shared types (`Notification`, `Alerter`, `Alert`, etc.) and switching to platform backend via `builtin.os.tag`. Same pattern as `poller.zig`.
- **Backend Location:** `src/ampe/os/linux/Notifier.zig` and `src/ampe/os/windows/Notifier.zig`.
- **Skt Storage:** Both backends store `Skt` objects (not raw `socket_t`). Uniform resource management via `Skt.deinit()`.
- **UDS Restored:** Both platforms use UDS socket pairs. Linux uses abstract sockets (`socket_file[0] = 0`). Windows uses filesystem paths (no abstract namespace support).
- **Windows Connect Ordering:** On Windows, `Skt.connect()` must be called BEFORE `waitConnect()` (initiates non-blocking connect, then poll for completion). On Linux, `waitConnect()` before `posix.connect()` works because POLLOUT fires on non-connected sockets.
- **Windows Accept:** Use `listSkt.accept()` (returns `?Skt`) instead of raw `posix.accept()`. Handles Windows non-blocking accept correctly.
- **TCP Removed:** `initTCP` removed. Both platforms use `initUDS` exclusively.
- **NotificationSkt:** Takes `*Skt` (pointer to receiver Skt) instead of raw `Socket`. `Socket` type in `triggeredSkts.zig` fixed to `internal.Socket`.
- **WSAStartup:** Required before any Windows socket test. Every test entry point must call `WSAStartup(0x0202, &wsa_data)` with matching `WSACleanup()`.

---

## 10. Plans

Implementation plans are stored as separate files for cross-agent reference:
- [Stage 1 IOCP Reintegration Plan](./plan-stage1-iocp-reintegration.md) — **Completed** (2026-02-13)

---
*End of Decision Log*
