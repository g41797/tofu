# Windows Port: Questions & Clarifications (003)

**Date:** 2026-02-12
**Status:** Stage 0 POC Complete

---

## 1. Progress Update

- **Stage 0 POC:** The IOCP wakeup mechanism has been implemented in `os/windows/poc/stage0_wake.zig`. It successfully uses `NtCreateIoCompletion`, `NtRemoveIoCompletionEx`, and `NtSetIoCompletion`.
- **Infrastructure:** The `build.zig` has been updated to link `ntdll`, and a new test entry point `tests/os_windows_tests.zig` has been created.

---

## 2. New Questions & Concerns

### Q3.1: AFD_POLL Structure Definitions
The `AFD_POLL_INFO` and related structures are not available in the Zig standard library. I plan to define them manually in `os/windows/poc/stage1_accept.zig`. 
- **Do you have a preferred reference for these definitions (e.g., specific ReactOS headers or other open-source implementations)?**

### Q3.2: SIO_BASE_HANDLE Usage
To use `AFD_POLL` directly on a socket, we need the "base handle" via `WSAIoctl(SIO_BASE_HANDLE)`. 
- **Is it acceptable to add this `WSAIoctl` call to the `Skt.zig` or should it be handled entirely within the Windows-specific Reactor/Poller logic?**

### Q3.3: POC Execution
Since the current environment is Linux, I cannot verify the Windows POC tests.
- **Do you have a way to run the `zig build test` on a Windows machine or via CI to confirm the Stage 0 POC passes before we move to Stage 1?**

---

## 3. Notes for Developer
- The `ACTIVE_KB.md` has been updated to Version 004.
- The next goal is Stage 1: Detecting an incoming connection via `AFD_POLL_ACCEPT`.
