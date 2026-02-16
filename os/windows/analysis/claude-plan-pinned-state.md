# Plan: PinnedState — Solve Pointer Instability in Windows Poller

**Author:** Claude Code (Opus 4.6)
**Date:** 2026-02-16
**Status:** Proposed — awaiting review and approval

---

## Context

**Problem:** The Windows IOCP/AFD_POLL backend has a critical pointer instability bug.
`Reactor.trgrd_map` is an `std.AutoArrayHashMap(ChannelNumber, TriggeredChannel)` that stores
values inline. When the map grows (realloc moves all values) or calls `swapRemove` (last element
moves to fill gap), addresses change. But the Windows kernel holds long-lived pointers to
`IO_STATUS_BLOCK` and `AFD_POLL_INFO` from pending `NtDeviceIoControlFile` calls, and holds the
`ApcContext` pointer to `*TriggeredChannel`. These become dangling pointers — use-after-free — crash.

**Root cause confirmed:** `doc-reactor-poller-negotiation.md` and `plan-investigation-reactor-poller.md`.

**Approved solution:** "Indirection via ChannelNumber + Stable PinnedState Pool"
- Pass `ChannelNumber` (u16) as `ApcContext` instead of `*TriggeredChannel` pointer
- Heap-allocate a `PinnedState` struct per channel for kernel-facing memory
- On completion, look up current `TriggeredChannel` address by ID via `trgrd_map.getPtr(chn)`

**Why Linux doesn't have this bug:** Linux `poll()` is stateless — it takes a fresh `pollfd[]`
array each call, operates synchronously, and returns. The kernel never holds references across
calls. Windows AFD_POLL is async — the kernel holds `IO_STATUS_BLOCK` and `ApcContext` references
until the operation completes (potentially across multiple Reactor loop iterations).

---

## User Decisions

1. **POC approach:** Both — new `stage4_pinned.zig` + fix existing `SocketContext` bug
2. **Memory:** Start with simple `allocator.create/destroy` per PinnedState. Block-based pool
   (~128 per block) is a documented future optimization. Project "ready" only after pool impl.
3. **base_handle:** Stays in `Skt`. PinnedState accesses it through the `*Skt` pointer that is
   valid during `armSkt()` (same iteration — Skt address is stable within a single armFds pass).
4. **ChannelNumber:** `u16` (from `message.ChannelNumber`), range 1-65534. Cast to `usize` for
   `ApcContext` (PVOID). On completion, cast back: `@as(ChannelNumber, @intCast(@intFromPtr(entry.ApcContext.?)))`.

---

## Architecture Overview

```
BEFORE (current — pointer-based, unstable):
  armSkt:            ApcContext = @ptrCast(tc)           -> kernel holds *TriggeredChannel
                     IoStatusBlock = &skt.*.io_status    -> kernel holds *Skt field
  processCompletions: tc = @ptrCast(entry.ApcContext)    -> STALE if map moved

AFTER (new — ID-based, stable):
  armSkt:            ApcContext = @ptrFromInt(@as(usize, chn))  -> kernel holds integer ID
                     IoStatusBlock = &pinned.io_status          -> kernel holds *PinnedState (heap, stable)
  processCompletions: chn = @intCast(@intFromPtr(entry.ApcContext))
                      pinned = pinned_states.get(chn)           -> stable lookup
                      tc = iterator.getPtr(chn)                 -> safe current-address lookup
```

---

## Critical Files

| File | Change |
|------|--------|
| `src/ampe/os/windows/Skt.zig` | Remove `io_status`, `poll_info`, `is_pending`, `expected_events` |
| `src/ampe/os/windows/poller.zig` | Add `PinnedState` struct, `pinned_states` HashMap, refactor `armSkt`/`processCompletions` |
| `src/ampe/os/windows/afd.zig` | Fix `SocketContext.arm()` io_status bug (stack local to struct field) |
| `src/ampe/Reactor.zig` | Extend `Iterator` with `map` field and `getPtr(chn)` method |
| `poc/windows/stage3_stress.zig` | Use fixed `SocketContext` (with io_status as field) |
| `poc/windows/poc.zig` | Add `stage4_pinned` import |
| `tests/os_windows_tests.zig` | Add `stage4_pinned` test |
| NEW: `poc/windows/stage4_pinned.zig` | POC validating PinnedState pattern |

---

## Execution Steps

### Phase 0: POC — Validate Pattern Before Production

#### Step 0a: Fix SocketContext.arm() io_status Bug

**File:** `src/ampe/os/windows/afd.zig` (line 85)

**Bug:** `var io_status: windows.IO_STATUS_BLOCK = undefined;` is a stack local. The kernel
holds `&io_status` for async operations, but it goes out of scope when `arm()` returns.
Works in POC by luck (synchronous completion or stack not yet overwritten).

**Fix:** Move `io_status` to a struct field:
```zig
pub const SocketContext = struct {
    skt: *Skt,
    poll_info: ntdllx.AFD_POLL_INFO,
    io_status: windows.IO_STATUS_BLOCK = undefined,  // NEW: persistent field
    is_pending: bool = false,

    pub fn init(skt: *Skt) SocketContext {
        return SocketContext{
            .skt = skt,
            .poll_info = undefined,
        };
    }

    pub fn arm(self: *SocketContext, events: u32, apc_context: ?*anyopaque) !void {
        self.*.poll_info = ntdllx.AFD_POLL_INFO{
            .Timeout = @as(windows.LARGE_INTEGER, @bitCast(@as(u64, 0x7FFFFFFFFFFFFFFF))),
            .NumberOfHandles = 1,
            .Exclusive = 0,
            .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
                .{ .Handle = self.*.skt.*.base_handle, .Events = events, .Status = .SUCCESS },
            },
        };

        const status: ntdllx.NTSTATUS = windows.ntdll.NtDeviceIoControlFile(
            self.*.skt.*.base_handle,
            null,
            null,
            apc_context,
            &self.*.io_status,    // Stable struct field, not stack local
            ntdllx.IOCTL_AFD_POLL,
            &self.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
            &self.*.poll_info,
            @sizeOf(ntdllx.AFD_POLL_INFO),
        );

        if (status != .SUCCESS and status != .PENDING) return error.AfdPollFailed;
        self.*.is_pending = true;
    }
};
```

**Verify:** Full 4-step sequence. All 35 existing tests must still pass.

#### Step 0b: Create stage4_pinned.zig — Validate Indirection Pattern

**New file:** `poc/windows/stage4_pinned.zig`

POC that demonstrates the full PinnedState indirection pattern:
- `PinnedState` struct: `io_status`, `poll_info`, `is_pending`
- `HashMap(u16, *PinnedState)` for ID-based lookup
- Use integer ID as `ApcContext` (not pointer)
- On completion: cast ApcContext -> ID -> look up PinnedState -> read poll_info.Events
- Stress test: multiple concurrent connections with connect/send/recv/disconnect cycles
- Deliberately trigger HashMap growth during operation to prove stability

**Also update:**
- `poc/windows/poc.zig` — add `stage4_pinned` import
- `tests/os_windows_tests.zig` — add stage4 test

**Verify:** Full 4-step sequence. New + existing tests pass.

#### Step 0c: Verify stage3_stress Still Passes

After Step 0a's SocketContext fix, verify that stage3_stress (which uses SocketContext) still
passes in both Debug and ReleaseFast.

---

### Phase 1: Production Refactoring

#### Step 1a: Extend Iterator with getPtr()

**File:** `src/ampe/Reactor.zig` (lines 1158-1183)

Add a `map` field and `getPtr` method to Iterator:
```zig
pub const Iterator = struct {
    itrtr: ?Reactor.TriggeredChannelsMap.Iterator = null,
    map: ?*Reactor.TriggeredChannelsMap = null,

    pub fn init(tcm: *Reactor.TriggeredChannelsMap) Iterator {
        return .{
            .itrtr = tcm.iterator(),
            .map = tcm,
        };
    }

    pub fn getPtr(itr: *Iterator, key: channels.ChannelNumber) ?*TriggeredChannel {
        if (itr.map) |m| {
            return m.getPtr(key);
        }
        return null;
    }

    pub fn next(itr: *Iterator) ?*TriggeredChannel {
        if (itr.itrtr != null) {
            const entry = itr.itrtr.?.next();
            if (entry) |entr| {
                return entr.value_ptr;
            }
        }
        return null;
    }

    pub fn reset(itr: *Iterator) void {
        if (itr.itrtr != null) {
            itr.itrtr.?.reset();
        }
        return;
    }
};
```

This is a backward-compatible addition. Linux poller doesn't use it. No behavior change.

**Verify:** Full 4-step + Linux cross-compile.

#### Step 1b: Add PinnedState to Poller

**File:** `src/ampe/os/windows/poller.zig`

Add PinnedState struct and HashMap to Poll:
```zig
const ChannelNumber = message.ChannelNumber;

pub const PinnedState = struct {
    io_status: windows.IO_STATUS_BLOCK = undefined,
    poll_info: ntdllx.AFD_POLL_INFO = undefined,
    is_pending: bool = false,
    expected_events: u32 = 0,
};

pub const Poll = struct {
    allocator: Allocator = undefined,
    afd_poller: AfdPoller = undefined,
    it: ?Reactor.Iterator = null,
    entries: std.ArrayList(ntdllx.FILE_COMPLETION_INFORMATION) = undefined,
    pinned_states: std.AutoArrayHashMap(ChannelNumber, *PinnedState) = undefined,

    pub fn init(allocator: Allocator) !Poll {
        return Poll{
            .allocator = allocator,
            .afd_poller = try AfdPoller.init(allocator),
            .it = null,
            .entries = try std.ArrayList(ntdllx.FILE_COMPLETION_INFORMATION).initCapacity(allocator, 256),
            .pinned_states = std.AutoArrayHashMap(ChannelNumber, *PinnedState){},
        };
    }

    pub fn deinit(pl: *Poll) void {
        // Free all remaining PinnedStates
        for (pl.pinned_states.values()) |state| {
            pl.allocator.destroy(state);
        }
        pl.pinned_states.deinit(pl.allocator);
        pl.afd_poller.deinit();
        pl.entries.deinit(pl.allocator);
    }
    // ... rest of methods
};
```

#### Step 1c: Thin Skt — Remove Kernel-State Fields

**File:** `src/ampe/os/windows/Skt.zig`

Remove these fields (they move to PinnedState):
- `io_status: windows.IO_STATUS_BLOCK`
- `poll_info: ntdllx.AFD_POLL_INFO`
- `is_pending: bool`
- `expected_events: u32`

Skt becomes:
```zig
pub const Skt = @This();
socket: ?ws2_32.SOCKET = null,
address: std.net.Address = undefined,
server: bool = false,
base_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
```

Also remove the `ntdllx` import from Skt.zig (no longer needed).

#### Step 1d: Refactor armFds/armSkt

**File:** `src/ampe/os/windows/poller.zig`

`armFds` changes:
```zig
fn armFds(pl: *Poll) !void {
    // First: clean up orphaned PinnedStates (channel removed, no pending I/O)
    pl.cleanupOrphans();

    var tcptr: ?*TriggeredChannel = pl.it.?.next();
    while (tcptr != null) {
        const tc: *TriggeredChannel = tcptr.?;
        tcptr = pl.it.?.next();
        tc.*.disableDelete();

        const exp: Triggers = try tc.*.tskt.triggers();
        tc.*.exp = exp;
        tc.*.act = .{};
        if (exp.off()) continue;

        const skt: *Skt = switch (tc.*.tskt) {
            .notification => tc.*.tskt.notification.skt,
            .accept => &tc.*.tskt.accept.skt,
            .io => &tc.*.tskt.io.skt,
            .dumb => continue,
        };

        // Register socket with IOCP if not yet registered
        if (skt.*.base_handle == windows.INVALID_HANDLE_VALUE) {
            _ = try pl.*.afd_poller.register(skt);
        }

        const chn: ChannelNumber = tc.*.acn.chn;
        const events: u32 = afd.toAfdEvents(exp);

        // Get or create PinnedState
        const gop = try pl.*.pinned_states.getOrPut(pl.*.allocator, chn);
        if (!gop.found_existing) {
            gop.value_ptr.* = try pl.*.allocator.create(PinnedState);
            gop.value_ptr.*.* = PinnedState{};
        }
        const state: *PinnedState = gop.value_ptr.*;

        // Arm if not pending or if interest changed
        if (!state.*.is_pending or state.*.expected_events != events) {
            try pl.*.armSkt(skt, events, chn, state);
        }
    }
}
```

`armSkt` changes — uses PinnedState for kernel memory, ChannelNumber as ApcContext:
```zig
fn armSkt(pl: *Poll, skt: *Skt, events: u32, chn: ChannelNumber, state: *PinnedState) !void {
    _ = pl;
    state.*.poll_info = ntdllx.AFD_POLL_INFO{
        .Timeout = @as(windows.LARGE_INTEGER, @bitCast(@as(u64, 0x7FFFFFFFFFFFFFFF))),
        .NumberOfHandles = 1,
        .Exclusive = 0,
        .Handles = [_]ntdllx.AFD_POLL_HANDLE_INFO{
            .{ .Handle = skt.*.base_handle, .Events = events, .Status = .SUCCESS },
        },
    };

    const status: ntdllx.NTSTATUS = windows.ntdll.NtDeviceIoControlFile(
        skt.*.base_handle,
        null,
        null,
        @ptrFromInt(@as(usize, chn)),  // ApcContext = ChannelNumber as integer
        &state.*.io_status,             // Stable address (heap-allocated PinnedState)
        ntdllx.IOCTL_AFD_POLL,
        &state.*.poll_info,
        @sizeOf(ntdllx.AFD_POLL_INFO),
        &state.*.poll_info,
        @sizeOf(ntdllx.AFD_POLL_INFO),
    );

    if (status != .SUCCESS and status != .PENDING) {
        return AmpeError.CommunicationFailed;
    }
    state.*.is_pending = true;
    state.*.expected_events = events;
}
```

#### Step 1e: Refactor processCompletions

**File:** `src/ampe/os/windows/poller.zig`

```zig
fn processCompletions(pl: *Poll, removed: u32) !Triggers {
    var ret: Triggers = .{};

    for (pl.*.entries.allocatedSlice()[0..removed]) |entry| {
        if (entry.ApcContext == null) continue;

        const chn: ChannelNumber = @intCast(@intFromPtr(entry.ApcContext.?));

        // Look up PinnedState (stable heap memory)
        const state: *PinnedState = pl.*.pinned_states.get(chn) orelse continue;
        state.*.is_pending = false;

        // Look up TriggeredChannel by ID (safe — gets current address)
        const tc: *TriggeredChannel = pl.*.it.?.getPtr(chn) orelse {
            // Channel was removed — free orphaned PinnedState
            pl.*.allocator.destroy(state);
            _ = pl.*.pinned_states.swapRemove(chn);
            continue;
        };

        if (tc.*.tskt == .dumb) continue;

        if (entry.IoStatus.u.Status != .SUCCESS) {
            tc.*.act = Triggers{ .err = .on };
            ret = ret.lor(tc.*.act);
            continue;
        }

        const events: u32 = state.*.poll_info.Handles[0].Events;
        const act: Triggers = afd.fromAfdEvents(events, tc.*.exp);
        tc.*.act = act.lor(.{ .pool = tc.*.exp.pool });
        ret = ret.lor(tc.*.act);
    }

    return ret;
}
```

#### Step 1f: Orphan Cleanup

**File:** `src/ampe/os/windows/poller.zig`

For PinnedStates where the channel was removed AND is_pending is false (no cancellation
completion will arrive):

```zig
fn cleanupOrphans(pl: *Poll) void {
    var i: usize = 0;
    const keys: []const ChannelNumber = pl.*.pinned_states.keys();
    const vals: []*PinnedState = pl.*.pinned_states.values();
    while (i < pl.*.pinned_states.count()) {
        if (!vals[i].*.is_pending and pl.*.it.?.getPtr(keys[i]) == null) {
            pl.*.allocator.destroy(vals[i]);
            pl.*.pinned_states.swapRemoveAt(i);
            // don't increment — swapRemove moved last element here
        } else {
            i += 1;
        }
    }
}
```

Called at the start of `armFds()` before iterating channels.

---

### Phase 2: Verification

1. **Debug build:** `zig build -Doptimize=Debug`
2. **Debug test:** `zig build test -freference-trace --summary all -Doptimize=Debug`
3. **ReleaseFast build:** `zig build -Doptimize=ReleaseFast`
4. **ReleaseFast test:** `zig build test -freference-trace --summary all -Doptimize=ReleaseFast`
5. **Linux cross-compile:** `zig build -Dtarget=x86_64-linux`

All 5 must pass after each step. After Phase 1 is complete, enable reactor_tests on Windows
and verify `handle reconnect single threaded` (1000 cycles) without crashes.

---

### Phase 3: Enable Reactor Tests on Windows

After Phase 1 passes all existing tests, enable reactor tests:
1. Modify `tests/tofu_tests.zig` to include `reactor_tests.zig` on Windows
2. Fix any compilation or runtime issues that arise
3. Run full 4-step verification

---

### Phase 4: Documentation Update

Update these files with results:
- `os/windows/CHECKPOINT.md` — new task state
- `os/windows/ACTIVE_KB.md` — technical state, session hand-off
- `os/windows/decision-log.md` — PinnedState decision, memory strategy decision
- `os/windows/CONSOLIDATED_QUESTIONS.md` — resolved questions, new questions

---

## Key Design Decisions

### PinnedState Lifecycle
- **Created:** In `armFds()` via `getOrPut` when a channel first needs to be armed
- **Freed (normal):** In `processCompletions()` when completion arrives for a removed channel
- **Freed (non-pending orphan):** In `cleanupOrphans()` at start of `armFds()`
- **Freed (shutdown):** In `Poll.deinit()` — frees all remaining states

### Why Not Free PinnedState Eagerly on Channel Removal?
When a channel is removed, `closesocket()` triggers kernel cancellation of pending AFD_POLL.
The cancellation posts STATUS_CANCELLED to IOCP. If we free PinnedState immediately after
closesocket(), there's a theoretical window where the kernel might still be writing to
`io_status`. The safe approach: let the cancellation completion arrive in the next `poll()`
cycle, THEN free PinnedState.

### Memory Strategy
**Phase 1 (now):** Simple `allocator.create(PinnedState)` / `allocator.destroy(state)`.
One heap allocation per channel.

**Phase 2 (future, required for "ready"):** Block-based pool allocator. Allocate PinnedState
objects in blocks of ~128. Track per-block usage count. Free empty blocks. This reduces
allocation overhead for workloads with many short-lived channels.

### base_handle Access Pattern
`base_handle` stays in `Skt`. During `armSkt()`, the `*Skt` pointer is valid (obtained from
the TriggeredChannel in the same `armFds()` iteration — no map mutations happen during this
pass). PinnedState does NOT store a reference to Skt — it reads `skt.base_handle` once to
populate `poll_info.Handles[0].Handle` and pass to `NtDeviceIoControlFile`.

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Cancellation completion timing | Deferred PinnedState cleanup — never free while kernel might hold reference |
| ChannelNumber reuse after removal | processCompletions checks getPtr — if channel was reused with same number, PinnedState was already freed/recreated |
| Iterator.getPtr not finding channel | Returns null -> skip completion (channel removed between arm and completion) |
| pinned_states HashMap growth | This HashMap stores `*PinnedState` (pointers, 8 bytes each). Growth moves pointers, not PinnedState objects. Kernel holds references to PinnedState heap objects, not to HashMap entries. Safe. |
| Linux cross-compile regression | Iterator.getPtr is additive. Skt field removal is Windows-only (comptime). Poller changes are Windows-only. |

---

## Success Criteria

1. All existing 35 tests pass on Windows (Debug + ReleaseFast)
2. New stage4 POC test passes
3. Reactor tests enabled and passing on Windows
4. `handle reconnect single threaded` (1000 cycles) passes without crashes
5. Linux cross-compile passes
6. All documentation updated

---

## Appendix: Key Source References

- `os/windows/analysis/doc-reactor-poller-negotiation.md` — root cause analysis
- `os/windows/analysis/plan-investigation-reactor-poller.md` — approved fix strategy
- `os/windows/decision-log.md` — settled architectural decisions
- `os/windows/spec-v6.1.md` — authoritative IOCP/AFD specification
- `docs_site/docs/mds/channel-group.md` — ChannelNumber semantics (1-65534)
- `docs_site/docs/mds/key-ingredients.md` — Reactor architecture overview
