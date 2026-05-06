# Agent State & Handover

**Current Version:** 065
**Last Updated:** 2026-05-06
**Last Agent:** Claude Code (Sonnet 4.6)
**Active Phase:** Implementation — Stage 0.5 is next

---

- **RULE:** For every stub in the `usockets/` folder, use the corresponding file under the `linux/` (or `mac/` / `windows/`) subfolder as the primary reference for logic and structure.


## Constraints for Next Agent (MANDATORY)

- **Git disabled.** Do NOT run any git commands. Author manages version control manually.
- **NO POSIX.** Never use `std.posix` or raw POSIX APIs and structs in new code . Use `bsd_` wrappers from `bun-usockets`. Raise attention if you can not find related struct
- **GitHub workflows exist** (`linux.yml`, `mac.yml`, `windows.yml`). Add the network matrix per plan §14 at the correct stage only — do NOT modify workflows for any other reason.
- **Doc and comments style** — see `design/RULES.md` §5. Short sentences. Bullet lists for sequences. No marketing language. Plain English for non-native speakers. Tech terms are fine.
- **"allows to verb"** is a grammar error in English. Restructure any such phrase found in docs.
- **Architectural changes** require explicit author approval before implementation.

---

## Current Status

**Update this section at the start and end of every session.**

- Design complete. `design/transition-2-bun-usockets-plan.md` is the single authoritative implementation plan.
- Stage -1 (std.posix/std.net → bsd_* mapping scan) is COMPLETE. Full mapping table in plan §12.5. No blockers.
- Stage 0 (VSCode config) is COMPLETE.
- Stage 0.5 (`build.zig` C sources + `posix_net/` subfolder + `posix_net.zig` facade + 22 tests) is the next task.
- **Note:** For every stub in the `usockets/` folder, use the corresponding file under the `linux/` (or `mac/` / `windows/`) subfolder as the primary reference for logic and structure.
- All 64 tests pass on Linux (Debug + ReleaseSafe) with the default `-Dnetwork=posix` backend.
- Cross-compilation verified: `x86_64-windows-gnu`, `x86_64-macos`, `aarch64-macos` all compile clean.

---

## Architecture (after OS Folder Flattening)

### File Structure
```
src/ampe/
├── poller.zig                    # Facade: comptime selects backend
├── internal.zig                  # Facade: Skt, Socket, Notifier, SocketCreator
├── common.zig                    # Shared: TcIterator, isSocketSet, toFd, constants
├── core.zig                      # Shared struct fields + PollerCore generic
├── Notifier.zig                  # Shared: platform-independent (replaces 3 identical copies)
├── linux/
│   ├── Skt.zig, SocketCreator.zig, triggers.zig
│   └── epoll_backend.zig
├── windows/
│   ├── Skt.zig, SocketCreator.zig, triggers.zig
│   ├── wepoll_backend.zig
│   └── wepoll/                   # vendored copy (wepoll.c, wepoll.h)
├── mac/
│   ├── Skt.zig, SocketCreator.zig, triggers.zig
│   └── kqueue_backend.zig
└── usockets/
    ├── Skt.zig, SocketCreator.zig, triggers.zig
    └── usockets_backend.zig
```

### Key Design Decisions
1. **Comptime Selection (Zero Overhead):** Backend selected at compile time based on OS
2. **Each Backend is Complete:** No comptime branches inside functions, whole functions per OS
3. **Shared Logic via Composition:** PollerCore generic composes with backend-specific implementations
4. **Backward Compatibility:** `PollerOs(backend)` wrapper maintained for existing consumers
5. **Override Strategy:** Overriding `us_internal_dispatch_ready_poll` to maintain manual I/O control.

---

## Session History

### Template — use for every session entry

Add new entries at the top of Session History (newest first). Bump version and update date in the file header.

```
### YYYY-MM-DD: <Agent Name> — <Short Title>

#### Summary
One paragraph. What was done and why.

#### Changes
- `path/to/file` — what changed

#### Verification

| Check | Result |
| :---- | :----- |
| `zig build test -Doptimize=Debug` | ✅ PASS (N/N) |
| `zig build test -Doptimize=ReleaseSafe` | ✅ PASS (N/N) |
| `zig build -Dtarget=x86_64-windows-gnu` | ✅ PASS |
| `zig build -Dtarget=x86_64-macos` | ✅ PASS |
| `zig build -Dtarget=aarch64-macos` | ✅ PASS |
```

---

### 2026-05-06: Claude Code (Sonnet 4.6) — Plan Update: posix_net/ Architecture

#### Summary
Replaced single-file `bsd.zig` with a `posix_net/` subfolder architecture in the plan. Key decisions: folder named `posix_net/`, facade file `posix_net.zig`, Zig wrappers use plain camelCase (no prefix), callers use `const pn = @import("posix_net.zig")`. `posix_net/ffi.zig` holds all raw C externs and is never imported directly by consumers. Added Stage 0.5 (posix_net/ + 22 tests). Updated all `bsd.*` references throughout the plan to `pn.*` with camelCase wrapper names.

#### Changes
- `design/transition-2-bun-usockets-plan.md` — §2 table/description; §2.5 replaced with posix_net/ structure, naming table, two-layer example; §4.5 dispatch fn uses `pn.poll.pollExt`; §7.1 replaced extern block with import note; §7.3/7.4/7.5 use `pn.poll.*`; §8 import + method table + mapErrno use `pn.*`; §9.2 code uses `pn.createListenSocketUnix`; §9.3 code uses `pn.createConnectSocket`; §12 Stage 0.5 added; §12.5 mapping table updated to `pn.*`; §16 bsd.zig rows replaced with posix_net/ rows
- `design/AGENT_STATE.md` — v064→065; Stage 0.5 as next task

#### Verification

| Check | Result |
| :---- | :----- |
| Plan-only session | No code written |

---

### 2026-05-06: Claude Code (Sonnet 4.6) — Plan Update: UDS/Notifier Clarifications

#### Summary
Added three clarifications to `design/transition-2-bun-usockets-plan.md` from Gemini's implementation-phase findings. (1) `connect()` in `usockets/Skt.zig` always returns `true` — `bsd_create_connect_socket` doesn't distinguish immediate vs EINPROGRESS. (2) Linux abstract namespace UDS: pass `\x00`-prefixed path with full `pathlen` to `bsd_create_listen_socket_unix`; bsd.c handles it internally. (3) Notifier: no `bsd_socketpair` needed — Manual Pair approach via SocketCreator is already POSIX-free once SocketCreator uses `bsd_*`.

#### Changes
- `design/transition-2-bun-usockets-plan.md` — §8 connect() note; §9.2 abstract namespace section (new); §9.3 renamed; §10 Notifier note
- `design/AGENT_STATE.md` — v063→064; session entry added

#### Verification

| Check | Result |
| :---- | :----- |
| Plan-only session | No code written |

---

### 2026-05-06: Claude Code (Sonnet 4.6) — Plan Update: Rules, bsd.zig, Mapping Table

#### Summary
Updated `design/transition-2-bun-usockets-plan.md` with three new pre-implementation requirements. Added "Use linux/ as reference" and "NO POSIX" rules to §0. Added `bsd.zig` as a new centralized externs file to §2 and §2.5. Scanned `linux/Skt.zig` and `linux/SocketCreator.zig` for all `std.posix` / `std.net` usage — 27 entries mapped to `bsd_*` replacers with no blockers. Added mapping table as §12.5. Updated §7, §8, §12, §16 to use `bsd.zig` and remove inline externs. Replaced `std.posix.timespec` with `std.c.timespec` in `wait()`. This is Stage -1 (pre-implementation scan) — COMPLETE.

#### Changes
- `design/transition-2-bun-usockets-plan.md` — §0 rules; §2 bsd.zig row; §2.5 bsd.zig content; §7.1 bsd import; §8 bsd import + mapErrno fix; §12 Step -1; §12.5 mapping table; §16 bsd.zig row
- `design/AGENT_STATE.md` — v062→063; Stage -1 marked complete; Stage 1 updated to include bsd.zig

#### Verification

| Check | Result |
| :---- | :----- |
| Stage -1 scan | ✅ COMPLETE — 27 usages mapped, no blockers |
| No code written | Plan-only session |

---

### 2026-05-06: Gemini CLI — Stage 0: VSCode Configuration

#### Summary
Completed Stage 0 of the implementation plan. Updated VSCode configuration files (`launch.json` and `tasks.json`) to support building, testing, and debugging with the `usockets` backend. Added C source stepping support to the debugger.

#### Changes
- `.vscode/launch.json` — added C source support and `usockets` debug config
- `.vscode/tasks.json` — added `usockets` build and test tasks
- `design/AGENT_STATE.md` — v061→062; updated status to Implementation Phase

#### Verification
No code changes. Acceptance criterion: configurations correctly added to files.

---

### 2026-05-06: Gemini CLI — Research, Planning, and Verdict for bun-usockets

#### Summary
Deep dive into `bun-usockets` integration and comparison between upstream and Bun-vendored versions. Documented detailed mapping for all network operations (Listen, Connect, Accept, I/O, Address Resolution). Formulated the "Manual Pull Reactor" strategy using `POLL_TYPE_SOCKET` with a weak-symbol dispatch override. Approved the Final Implementation Plan via a formal verdict and updated platform-specific receipts for Linux, macOS, and Windows.

#### Changes
- `design/transition-2-usockets.md` — mapping for upstream and bun-usockets, folder structure proposal, Windows "Forced Epoll" strategy
- `design/bun-usockets-zig.md` — deep dive into Zig-C bridge, "Receipts Book" for operations, step-by-step Reactor flow
- `design/transition-2-bun-usockets-plan-verdict.md` — authoritative verdict approving the final plan
- `design/AGENT_STATE.md` — v060→061; current status and architecture notes updated

#### Verification
Analysis only. Verified structural compatibility with `PollerCore` and `SeqnTrcMap` in `src/ampe/poller.zig`.

---
... rest of file ...
