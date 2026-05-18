# Tofu Project Rules

Common rules for all contributors and AI agents working on the `tofu` repository.

---

## 0. Author's Directive (MANDATORY READING)

*Notes, requirements, and advice directly from the project author. All contributors and AI agents must follow these instructions over any conflicting defaults.*

### Verification Rule (MANDATORY)
You MUST run all tests in ALL 4 optimization modes. Successful completion of a task requires:
1. `zig build test` (Debug)
2. `zig build test -Doptimize=ReleaseSafe` (ReleaseSafe)
3. `zig build test -Doptimize=ReleaseFast` (ReleaseFast)
4. `zig build test -Doptimize=ReleaseSmall` (ReleaseSmall)

### Windows ABI Rule (MANDATORY)
- When building **on Linux** for Windows: Use the `gnu` ABI (`-Dtarget=x86_64-windows-gnu`).
- When building **on Windows** for Windows: Use the `msvc` ABI (`-Dtarget=x86_64-windows-msvc`).
- The `build.zig` automatically defaults to these based on the host if the ABI is not specified.

### Cross-Platform Compilation (MANDATORY)
You MUST verify that the codebase compiles for all platforms (Linux, Windows, macOS) before finishing a task.

### Architectural Approval (MANDATORY)
Any change to important architecture parts (e.g., changing the memory model, adding allocators to core structures like `Skt`, or shifting between event backends) MUST be explicitly approved by the author. Provide an explanation and intent for discussion before applying such changes.

### Log File Analysis (MANDATORY)
Build/Test outputs must be redirected to `zig-out/` log files. Analyze logs via files, not shell stdout. Do NOT write temporary files, log files, or session-specific artifacts in the project root. Always place them in the `zig-out/` directory.

### Coding Style (MANDATORY)
1. **Little-endian Imports:** Imports at the bottom of the file.
2. **Explicit Typing:** No `const x = ...` where type is known/fixed. Use `const x: T = ...`.
3. **Explicit Dereference:** Use `ptr.*.field` for pointer access.
4. **Standard Library First:** Before adding a new definition (struct, constant, or function) to a custom binding file, always check if it already exists in the Zig standard library. Use the standard library definition if available.

---

## 1. Git Rules

Git usage **disabled for AI agents — MANDATORY RULE:** AI agents MUST NOT execute any git commands (commit, push, add, status, etc.). The user manages version control manually.

---

## 2. AI Collaboration Protocol

### Session Start Protocol
Upon starting a session, every AI agent MUST:
1. **Read First:** Read `design/AGENT_STATE.md`, `design/spec.md`, `design/windows-notes.md`, and Section 0 of this file entirely.
2. **Read Roadmap:** Check `design/roadmap.md` for current phase status.
3. **Process Questions:** Read `design/QUESTIONS.md`. Analyze unresolved queries.

### Shared State Rules
1. **Checkpoint as Short-Term Memory:** `design/AGENT_STATE.md` is the authoritative "short-term memory" for current task progress.
2. **Read-Before-Act:** Every session MUST begin by reading `design/AGENT_STATE.md`.
3. **Atomic Updates:** Update `design/AGENT_STATE.md` immediately after completing an atomic sub-task.
4. **Final Hand-off:** On session end, update `design/AGENT_STATE.md` with current state and next steps.
5. **Limitation Rule:** Update `design/windows-notes.md` immediately whenever a Windows-specific limitation or logic deviation is added, modified, or removed.

---

## 3. Roles of Participants

### Author (g41797)
- Owns overall project architecture and final architectural decisions.
- Manages version control (git) manually.
- Defines and verifies the `Triggers` abstraction, Reactor design, and event backend strategy.
- Runs final verification on all platforms.

### AI Agent (Claude, Gemini, or other)
- Implements tasks as directed, within approved architectural constraints.
- Must not take unilateral architectural decisions — propose and get approval first.
- Must maintain `design/AGENT_STATE.md` as the handover document.
- Must not execute git commands.

### Code Change Approval (MANDATORY)
**Do not change any source file without explicit approval from the author.**

This rule applies to every change, including:
- Bug fixes
- Refactors
- Cleanups
- Changes the agent believes are "obviously correct"

The required sequence for every code change:
1. Propose the change. Describe what, why, and which files will be affected.
2. Wait for the author to say "yes", "approved", "do it", or equivalent.
3. Only then write or edit any source file.

Plan approval (ExitPlanMode) does NOT count as code change approval unless the plan explicitly states "implement immediately" or the author separately says "go ahead". Each fix in a multi-fix plan needs its own explicit approval before implementation.

---

## 4. Mandatory Testing Protocol

### Build Commands (All Sanctioned Invocations)
```
zig build -Doptimize=Debug
zig build test -freference-trace --summary all -Doptimize=Debug
zig build -Doptimize=ReleaseFast
zig build test -freference-trace --summary all -Doptimize=ReleaseFast
```

### Rules
1. **Build before test:** Always run `zig build` first. Only proceed to `zig build test` after the build succeeds.
2. **Debug first:** Always build and test with `-Doptimize=Debug` first. Debug mode enables safety checks, bounds checking, and produces clear error messages.
3. **ReleaseFast second:** After Debug passes, build and test with `-Doptimize=ReleaseFast` to catch optimization-sensitive issues.
4. **Both must pass:** A change is only valid if both Debug and ReleaseFast builds and tests succeed.
5. **No exceptions:** This rule applies to POC code, production code, refactoring, and any other modification.

### Sandwich Verification Rule
If you fix a Windows build error after a successful Linux build, you MUST repeat the Linux build to ensure no regression was introduced. The sequence is:
```
Linux Build → Windows Build (and fix) → Linux Build
```

### 4-Mode Full Verification
All 4 optimization modes must pass for a task to be considered complete:
- `zig build test` (Debug)
- `zig build test -Doptimize=ReleaseSafe` (ReleaseSafe)
- `zig build test -Doptimize=ReleaseFast` (ReleaseFast)
- `zig build test -Doptimize=ReleaseSmall` (ReleaseSmall)

The `zbta.sh` script (and platform variants) automates this sequence.

---

## 5. Documentation Style

- **Short sentences.** Several short sentences are better than one long one.
- **Bullet lists for sequences.** Use bullets for multi-step flows and multi-part descriptions. One item per line. Don't pack multiple steps into one sentence.
- **Plain English.** Simple words understood by non-native English speakers. No high-register vocabulary.
- **No marketing language.** No "enables", "empowers", "bridges the gap", "seamless", "robust", "high-performance" unless technically precise.
- **No AI filler.** No triple adjectives ("bounded, mechanical, and isolated"), no summary sentences that repeat what the paragraph already said.
- **Tech terms are fine.** `epoll`, `kqueue`, `TriggeredChannel`, `comptime` — use them as-is. Precision over simplification.
- **Grammar matters.** "Allows to verb" is not English. Write "Allows X to verb" or restructure.
- **Terminology: no "shim".** Use "adapter" instead. A shim implies a hack; an adapter describes the role precisely.

---

## 6. Portable Backend Alignment Rules

### Addendum A Maintenance (MANDATORY)
`design/transition-2-bun-usockets-plan.md` contains Addendum A: four tables comparing `Skt` and `SocketCreator` across linux/mac, windows, and portable backends.

Every time any posix backend (linux, mac, windows) or the portable backend is changed, Addendum A must be updated to reflect the new state of all four tables before the task is considered complete.

### Portable Mirrors Posix Structure (MANDATORY)
The portable backend (`src/ampe/portable/`) must mirror the structure of the posix backends (linux, mac, windows) — not only public functions but also private/internal helpers.

Every private function that exists in linux, mac, or windows (`createListenerSocket`, `createConnectSocket`, `deleteUDSPath`, `connectOs`, `acceptOs`, etc.) must have an equivalent in portable, even if its body delegates to `pn.*` instead of Zig stdlib or syscalls.

Rule: **same shape, different engine.** Posix uses Zig stdlib/syscalls. Portable delegates to `posix_net` C wrappers. The function names and call structure must match so that line-by-line comparison is always possible.

When a new private helper is added to any posix backend, a matching function must be added to portable in the same session.

### No Silent No-ops or Stubs (MANDATORY)
Every function that has a real implementation in any posix backend (linux, mac, windows) must have a real implementation in portable — not a no-op, not a stub returning `NotImplementedYet`.

If a real implementation is not possible because the `posix_net`/`bsd.c` layer has no equivalent, the AI agent MUST:
1. Stop.
2. Explicitly report the gap to the author, naming the function and the missing capability.
3. Wait for the author's decision before leaving any no-op or stub in place.

Silently leaving a no-op where posix does real work is a bug, not a known limitation.

### Per-OS Subfolder Build Verification (MANDATORY)
When adding a new OS subfolder under `portable/` (e.g. `portable/linux/`), the first step before writing any logic is to verify that the build system correctly resolves all module imports from the new location.

Steps:
1. Create the subfolder.
2. Create minimal `Skt.zig` and `SocketCreator.zig` stubs (compiling but empty structs).
3. Add the redirect in `portable/Skt.zig` and `portable/SocketCreator.zig` for that OS.
4. Run `zig build` (Debug) for all three platforms (Linux, Windows, macOS cross-compile).
5. Only after all builds pass — start writing actual logic.

A build failure at step 4 means the module path or build.zig wiring is wrong. Fix it before proceeding.

### Proposal: Per-OS Subfolders Under portable/ (NOT DECIDED — for discussion)

Currently `src/ampe/portable/` is a flat folder. A possible future direction: create subfolders `portable/linux/`, `portable/mac/`, `portable/windows/` mirroring the top-level backend layout.

Motivation: as portable grows to mirror posix structure (public + private), OS-specific divergence inside portable (e.g. `setLingerAbort` differences, `accept` flags, UDS path handling) may become large enough that per-OS files are cleaner than `comptime` branches inside single files.

Open questions before deciding:
- Does the divergence inside portable justify per-OS files, or are `comptime` branches sufficient?
- Would per-OS subfolders duplicate too much of the top-level backend structure, making the portable layer redundant?
- At what point does portable become indistinguishable from the native backends?

**Discuss after the full alignment fix is complete and the scope of OS-specific divergence inside portable is known.**

### Per-Stage Diff Check (MANDATORY)
At the end of every implementation stage, the Addendum A tables must be reviewed line by line.
For each remaining difference, confirm one of two things:
1. The difference is intentional — a known architectural difference (e.g. portable delegates to C, posix uses Zig stdlib).
2. The difference is a gap — not yet fixed, and must be tracked as an open task.

No stage is complete while unintentional gaps remain unmarked.

---

*End of Rules*
