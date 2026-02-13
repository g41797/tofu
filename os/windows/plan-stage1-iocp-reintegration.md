# Plan: Stage 1 Accept Test with Integrated IOCP Completion

**Date:** 2026-02-13
**Status:** Completed (2026-02-13) — all 4 verification steps passed (Debug + ReleaseFast)
**Predecessor:** Stage 1 event-based accept (stage1_accept.zig) — passing both Debug and ReleaseFast

---

## Context

Stage 1 POC currently uses a temporary event-based mechanism (`CreateEventA` + `WaitForSingleObject`) to verify AFD_POLL_ACCEPT works. The next step (per ACTIVE_KB.md Section 4) is to reintegrate IOCP — replace the event with `NtRemoveIoCompletionEx` so that AFD_POLL completions post directly to the IOCP. This is implemented in a **separate file**, preserving the existing event-based implementation untouched.

---

## Changes

### 1. Create `os/windows/poc/stage1_accept_integrated_iocp.zig`

New file implementing `Stage1AcceptIocp` struct. Key differences from event-based version:

- **No `event_handle` field** — IOCP is the sole completion mechanism.
- **`NtDeviceIoControlFile` called with `Event = null`** — forces completion to post to IOCP instead of signaling an event.
- **`ApcContext = @ptrCast(&io_status_block)`** — must be non-null for IOCP to receive the completion (see Technical Detail below).
- **Wait via `NtRemoveIoCompletionEx`** with a 10-second timeout to prevent test hangs.
- **Validate completion entry**: check `IoStatus.u.Status == .SUCCESS`, then read `afd_poll_info.Handles[0].Events` for `AFD_POLL_ACCEPT`.
- **Same buffer for input/output** in `NtDeviceIoControlFile` (METHOD_BUFFERED IOCTL — matching wepoll, c-ares, mio).

Reuses from existing code:
- `ntdllx.zig` — all NT bindings, AFD structures, `NtRemoveIoCompletionEx`, `NtCreateIoCompletion`.
- `Skt` and `SocketCreator` from `tofu` module — socket creation.
- `address` from `tofu` module — address configuration.
- Same client thread pattern from `stage1_accept.zig`.

### 2. Update `os/windows/poc/poc.zig`

Add: `pub const stage1_iocp = @import("stage1_accept_integrated_iocp.zig");`

### 3. Update `tests/os_windows_tests.zig`

Add new test:
```zig
test "Windows Stage 1 IOCP: Accept Test" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const win_poc = @import("win_poc");
    try win_poc.stage1_iocp.runTest();
}
```

### 4. Update `os/windows/ACTIVE_KB.md`

- Update "Session Context & Hand-off" with work done.
- Update "Technical State of Play" to record IOCP-integrated accept verification.
- Update "Next Steps" to point to Stage 2 (Echo).

### 5. No changes to `build.zig`

The `win_poc` module root is `poc.zig` which transitively imports the new file. No new library linkage needed — `ntdll`, `ws2_32`, and `kernel32` are already linked.

---

## Critical Technical Detail: ApcContext Must Be Non-Null

In the NT I/O model, when a file handle is associated with an IOCP via `CreateIoCompletionPort` or `NtSetInformationFile(FileCompletionInformation)`:

- If `ApcContext` passed to `NtDeviceIoControlFile` is **non-null** → completion IS posted to IOCP.
- If `ApcContext` is **null** → completion is NOT posted (skip completion port behavior).

This is the NT equivalent of Win32's rule: "pass an OVERLAPPED* for async, NULL for sync." We pass `@ptrCast(&io_status_block)` as the ApcContext, matching the standard pattern used by mio, libuv, and wepoll.

The `FILE_COMPLETION_INFORMATION` entry returned by `NtRemoveIoCompletionEx` will contain:
- `Key`: the CompletionKey set during `CreateIoCompletionPort` association (we use 0).
- `ApcContext`: the pointer we passed (`&io_status_block`).
- `IoStatus`: the completion status from the kernel.

---

## Critical Technical Detail: Same Buffer for Input/Output

`IOCTL_AFD_POLL` (0x00012024) uses `METHOD_BUFFERED`. The I/O Manager:
1. Allocates a system buffer of `max(InputBufferLength, OutputBufferLength)`.
2. Copies InputBuffer → system buffer.
3. AFD driver processes the system buffer (reads input, writes results in-place).
4. I/O Manager copies system buffer → OutputBuffer.

All reference implementations (wepoll, c-ares, mio) pass the **same** `AFD_POLL_INFO` pointer for both input and output buffers. Using separate buffers caused a bug where the output was never populated (fixed in this session — see ACTIVE_KB.md).

---

## NtDeviceIoControlFile Parameter Mapping (Event-Based vs IOCP)

| Parameter | Event-Based (current stage1_accept.zig) | IOCP-Integrated (new file) |
|---|---|---|
| FileHandle | base_socket_handle | base_socket_handle |
| Event | self.event_handle | **null** |
| ApcRoutine | null | null |
| ApcContext | null | **@ptrCast(&io_status_block)** |
| IoStatusBlock | &io_status_block | &io_status_block |
| IoControlCode | IOCTL_AFD_POLL | IOCTL_AFD_POLL |
| InputBuffer | &afd_poll_info | &afd_poll_info |
| OutputBuffer | &afd_poll_info | &afd_poll_info |

Key change: `Event = null` + `ApcContext != null` → completion posts to IOCP.

---

## Verification

Run the full mandatory sequence (Decision Log Section 7):
```
zig build -Doptimize=Debug
zig build test -freference-trace --summary all -Doptimize=Debug
zig build -Doptimize=ReleaseFast
zig build test -freference-trace --summary all -Doptimize=ReleaseFast
```
All 4 steps must pass. The new test should print `Events returned: 0x80` (AFD_POLL_ACCEPT) in both modes.

---
*End of Plan*
