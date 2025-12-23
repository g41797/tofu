# Tofu Implementation Review - Zig Perspective

## Document Purpose

This document analyzes tofu implementation from Zig programming language perspective. It identifies:
- What should be improved
- Questionable implementations
- Best practices alignment
- Safety concerns
- Performance considerations

**Target Audience:** Zig developers reviewing or contributing to tofu

**Analysis Date:** December 2025
**Zig Version:** 0.14.0+ (targeting 0.15.2)

---

## Executive Summary

**Overall Assessment:** Solid implementation with good understanding of Zig. Several areas need attention for safety, maintainability, and Zig idioms.

**Strengths:**
- Good use of intrusive data structures (zero allocation)
- Proper use of defer/errdefer patterns
- Clear separation of concerns
- Thread safety where needed
- Packed structs for wire protocol

**Areas Needing Improvement:**
- Extensive use of `?*anyopaque` reduces type safety
- Error handling mixes status bytes with Zig errors
- Some questionable pointer casting patterns
- TODOs and commented code in production
- Inconsistent naming conventions

---

## 1. Memory Management Analysis

### 1.1 Message Pool Pattern ✅ GOOD

**File:** `src/ampe/Pool.zig`

**What It Does:**
```zig
pub fn get(pool: *Pool, ac: AllocationStrategy) AmpeError!*Message {
    pool.mutex.lock();
    defer pool.*.inform();
    defer pool.mutex.unlock();
    // ...
}
```

**Strengths:**
- LIFO pool reduces allocation pressure
- Thread-safe with mutex
- Two strategies: `poolOnly` (return null) vs `always` (allocate)
- Proper defer usage for unlock and inform

**Concerns:**
- `defer pool.*.inform()` called even on error paths (intended?)
- `defer` order: inform → unlock (inform happens while locked)

**Recommendation:**
Consider if `inform()` should be called before or after unlock. Current order means inform runs while mutex is held.

---

### 1.2 Intrusive Lists ✅ EXCELLENT

**File:** `src/ampe/IntrusiveQueue.zig`

**Pattern:**
```zig
pub const Message = struct {
    prev: ?*Message = null,
    next: ?*Message = null,
    // ... rest of fields
};
```

**Strengths:**
- Zero allocation for queueing
- Cache-friendly (fields in same struct)
- Clean generic implementation with `comptime`

**No concerns.** This is textbook Zig.

---

### 1.3 Allocator Usage ⚠️ MIXED

**Good:**
```zig
pub fn Create(gpa: Allocator, options: Options) AmpeError!*Reactor {
    const rtr: *Reactor = gpa.create(Reactor) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer gpa.destroy(rtr);
    // ...
}
```
- Proper use of `errdefer` for cleanup
- Single allocator passed through

**Questionable:**
```zig
// src/message.zig:373
pub fn create(allocator: Allocator) AmpeError!*Message {
    var msg = allocator.create(Message) catch {
        return AmpeError.AllocationFailed;
    };
    msg.* = .{};
    msg.bhdr = .{};  // Redundant - already in .{}
    // ...
}
```

**Issue:** `msg.bhdr = .{};` is redundant since `msg.* = .{}` already zeroes everything.

**Recommendation:**
```zig
pub fn create(allocator: Allocator) AmpeError!*Message {
    var msg = allocator.create(Message) catch {
        return AmpeError.AllocationFailed;
    };
    msg.* = .{};  // This is enough
    errdefer allocator.destroy(msg);  // Add this
    // ...
}
```

---

## 2. Type Safety Analysis

### 2.1 Excessive Use of `?*anyopaque` ❌ MAJOR CONCERN

**Problem:** Type erasure used extensively

**Examples:**

1. **Vtable pattern** (`src/ampe.zig`):
```zig
pub const Ampe = struct {
    ptr: ?*anyopaque,  // Could be *Reactor
    vtable: *const vtables.AmpeVTable,
};
```

2. **Context pointer in Message** (`src/message.zig`):
```zig
pub const Message = struct {
    @"<ctx>": ?*anyopaque = null,  // Engine context
    @"<void*>": ?*anyopaque = null,  // User context
};
```

3. **Pointer casting everywhere** (`src/ampe/MchnGroup.zig`):
```zig
pub fn enqueueToPeer(ptr: ?*anyopaque, amsg: *?*Message) AmpeError!BinaryHeader {
    const grp: *MchnGroup = @ptrCast(@alignCast(ptr));  // DANGER
    // ...
}
```

**Why This Is Problematic:**
- Loses type information at compile time
- Runtime crashes instead of compile errors
- No compiler help with refactoring
- Easy to pass wrong type (crash only at runtime)

**Impact:** This is standard vtable pattern in Zig, but it's risky.

**Better Alternatives:**

**Option 1: Tagged Union** (if few implementations)
```zig
pub const Ampe = union(enum) {
    reactor: *Reactor,
    // future: other implementations

    pub fn get(self: Ampe, strategy: AllocationStrategy) !?*Message {
        return switch (self) {
            .reactor => |r| r._get(strategy),
        };
    }
};
```

**Option 2: Comptime Generics** (if performance critical)
```zig
pub fn Ampe(comptime Impl: type) type {
    return struct {
        impl: *Impl,

        pub fn get(self: @This(), strategy: AllocationStrategy) !?*Message {
            return self.impl.get(strategy);
        }
    };
}
```

**Recommendation:**
Current vtable approach is acceptable for library flexibility, but:
- Document the safety contract clearly
- Consider adding runtime type tags for debugging
- Add asserts in debug builds to catch type mismatches

---

### 2.2 Pointer Casting Patterns ⚠️ UNSAFE

**File:** `src/ampe/MchnGroup.zig`, `src/ampe/Reactor.zig`

**Pattern:**
```zig
const grp: *MchnGroup = @ptrCast(@alignCast(ptr));
```

**Problems:**
- No compile-time verification
- Wrong type = immediate crash
- Alignment issues possible

**When This Fails:**
```zig
// Wrong usage (compiles but crashes at runtime):
var wrong: u32 = 42;
var ptr: ?*anyopaque = &wrong;
// Later...
const grp: *MchnGroup = @ptrCast(@alignCast(ptr));  // BOOM
```

**Recommendation:**
Add runtime checks in debug builds:
```zig
const grp: *MchnGroup = @ptrCast(@alignCast(ptr));
if (tofu.DBG) {
    std.debug.assert(@intFromPtr(grp) % @alignOf(MchnGroup) == 0);
}
```

---

### 2.3 Packed Structs ✅ GOOD

**File:** `src/message.zig`

```zig
pub const BinaryHeader = packed struct {
    channel_number: ChannelNumber = 0,
    proto: ProtoFields = .{},
    status: u8 = 0,
    message_id: MessageID = 0,
    @"<thl>": u16 = 0,
    @"<bl>": u16 = 0,

    pub const BHSIZE = @sizeOf(BinaryHeader);  // 16 bytes
};
```

**Strengths:**
- Correct use of `packed struct` for wire protocol
- Explicit size verification with comptime
- Big-endian conversion for network byte order

**No concerns.** This is proper network protocol handling.

---

## 3. Error Handling Analysis

### 3.1 Dual Error System ❌ CONFUSING

**Problem:** Two parallel error systems

**System 1: Zig Errors** (`src/status.zig`)
```zig
pub const AmpeError = error{
    NotImplementedYet,
    WrongConfiguration,
    // ... 30+ errors
};
```

**System 2: Status Bytes** (u8 in message.bhdr.status)
```zig
pub const AmpeStatus = enum(u8) {
    success = 0,
    not_implemented_yet,
    // ... same errors as AmpeError
};
```

**Conversion Hell:**
```zig
// Convert raw byte -> status enum
pub inline fn raw_to_status(rs: u8) AmpeStatus { ... }

// Convert raw byte -> error (or void)
pub inline fn raw_to_error(rs: u8) AmpeError!void { ... }

// Convert status enum -> error
pub inline fn status_to_error(status: AmpeStatus) AmpeError!void { ... }

// Convert error -> status enum
pub fn errorToStatus(err: AmpeError) AmpeStatus { ... }
```

**Why This Exists:**
Status byte travels over wire. Zig errors don't. Need conversion.

**Problem:**
Easy to use wrong conversion function. No type safety between them.

**Example Confusion:**
```zig
const st: u8 = msg.bhdr.status;

// Which to use?
const status1 = status.raw_to_status(st);         // → AmpeStatus
try status.raw_to_error(st);                      // → void or error
try status.status_to_error(status1);              // → void or error
const status2 = status.errorToStatus(err);        // ← requires error
```

**Recommendation:**

**Option 1:** Use newtype pattern
```zig
pub const WireStatus = packed struct {
    value: u8,

    pub fn toError(self: WireStatus) AmpeError!void {
        if (self.value == 0) return;
        return raw_to_error(self.value);
    }

    pub fn fromError(err: AmpeError) WireStatus {
        return .{ .value = @intFromEnum(errorToStatus(err)) };
    }
};
```

**Option 2:** Simplify to single conversion function
```zig
pub const StatusConversion = struct {
    pub fn wireToZig(wire: u8) AmpeError!void { ... }
    pub fn zigToWire(err: AmpeError) u8 { ... }
};
```

---

### 3.2 Error Context Loss ⚠️ POOR DX

**File:** Many files

**Pattern:**
```zig
const msg: *Message = Message.create(pool.allocator) catch {
    return AmpeError.AllocationFailed;
};
```

**Problem:**
Original error thrown away. User sees only `AllocationFailed` but not WHY (OOM? Permission? Other?).

**Better:**
```zig
const msg: *Message = Message.create(pool.allocator) catch |err| {
    log.err("Message.create failed: {s}", .{@errorName(err)});
    return AmpeError.AllocationFailed;
};
```

Or use error trace (Zig 0.11+):
```zig
const msg: *Message = Message.create(pool.allocator) catch |err| {
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace.*);
    }
    return AmpeError.AllocationFailed;
};
```

**Recommendation:**
Add error context in at least debug builds. Silent failures hurt debugging.

---

### 3.3 typo in Error Name ⚠️ MINOR BUG

**File:** `src/status.zig:22`

```zig
pub const AmpeStatus = enum(u8) {
    // ...
    invelid_mchn_group,  // TYPO: should be "invalid_mchn_group"
    // ...
};
```

**Impact:** Minor, but breaks consistency.

**Recommendation:** Fix typo. Update everywhere it's used.

---

## 4. Threading Model Analysis

### 4.1 Thread Safety Documentation ✅ GOOD

**File:** `src/ampe.zig`

Clear documentation of what's thread-safe:
```zig
/// Thread-safe.
pub fn get(ampe: Ampe, strategy: AllocationStrategy) !?*Message { ... }

/// Call in a loop from **one thread only**.
pub fn waitReceive(chnls: ChannelGroup, timeout_ns: u64) !?*Message { ... }
```

**Strengths:**
- Clear documentation
- Reasonable model (most operations thread-safe)
- Single-threaded `waitReceive` simplifies receiver logic

**No concerns.**

---

### 4.2 Mutex Usage ⚠️ DOUBLE-CHECK NEEDED

**File:** `src/ampe/Reactor.zig`

**Pattern:**
```zig
sndMtx: Mutex = undefined,
crtMtx: Mutex = undefined,
```

**Two mutexes for different operations:**
- `sndMtx`: Protects send operations
- `crtMtx`: Protects create/destroy operations

**Concern:**
Are there scenarios where both mutexes needed? Potential for deadlock?

**Example:**
```zig
// Thread A:
crtMtx.lock();
// ... needs sndMtx?

// Thread B:
sndMtx.lock();
// ... needs crtMtx?
```

**Recommendation:**
- Document lock ordering if both can be held
- Or prove they never overlap
- Consider single coarse-grained lock if performance allows

---

### 4.3 Atomic Usage ✅ REASONABLE

**File:** `recipes/services.zig`

```zig
pub const EchoService = struct {
    cancel: Atomic(bool) = .init(false),

    pub inline fn setCancel(echo: *EchoService) void {
        echo.*.cancel.store(true, .monotonic);
    }

    pub inline fn wasCancelled(echo: *EchoService) bool {
        return echo.*.cancel.load(.monotonic);
    }
};
```

**Strengths:**
- Correct use of `Atomic` for cross-thread flags
- `.monotonic` ordering appropriate for flag

**No concerns.**

---

## 5. API Design Analysis

### 5.1 Ownership Transfer Pattern ✅ EXCELLENT

**File:** `src/ampe.zig`

**Pattern:**
```zig
pub fn enqueueToPeer(
    chnls: ChannelGroup,
    msg: *?*message.Message,  // Pointer to optional pointer
) AmpeError!message.BinaryHeader {
    // After success:
    msg.* = null;  // Ownership transferred
    return bhdr;
}
```

**Strengths:**
- Clear ownership transfer (caller loses message)
- Impossible to use message after send (it's null)
- Compiler helps prevent use-after-free

**This is excellent Zig API design.**

---

### 5.2 VTable Pattern ⚠️ STANDARD BUT VERBOSE

**File:** `src/ampe/vtables.zig`

```zig
pub const AmpeVTable = struct {
    get: *const fn (ptr: ?*anyopaque, strategy: AllocationStrategy) AmpeError!?*message.Message,
    put: *const fn (ptr: ?*anyopaque, msg: *?*message.Message) void,
    create: *const fn (ptr: ?*anyopaque) AmpeError!ChannelGroup,
    destroy: *const fn (ptr: ?*anyopaque, chnlsimpl: ?*anyopaque) AmpeError!void,
    getAllocator: *const fn (ptr: ?*anyopaque) Allocator,
};
```

**Pros:**
- Standard pattern for runtime polymorphism in Zig
- Allows multiple implementations
- No hidden costs

**Cons:**
- Verbose to implement
- Every function needs `@ptrCast(@alignCast(ptr))`
- Easy to mess up (type safety lost)

**Recommendation:**
Current approach is standard. Document this is modeled after Zig stdlib (std.mem.Allocator uses same pattern).

---

### 5.3 TODO Comment in Interface ❌ PRODUCTION CODE

**File:** `src/ampe.zig:7`

```zig
// 2DO - Define error set(s) for errors returned by ChannelGroup and Ampe
```

**Problem:**
This is core API. TODO should be resolved before 1.0.

**Recommendation:**
Either implement or remove comment. Current `AmpeError` seems sufficient.

---

## 6. Zig Idioms Analysis

### 6.1 Defer/Errdefer Usage ✅ MOSTLY GOOD

**Good Example:**
```zig
pub fn Create(gpa: Allocator, options: Options) AmpeError!*Reactor {
    const rtr: *Reactor = gpa.create(Reactor) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer gpa.destroy(rtr);  // ✓ Cleanup on error

    rtr.acns = ActiveChannels.init(rtr.allocator, 1024) catch {
        return AmpeError.AllocationFailed;
    };
    errdefer rtr.acns.deinit();  // ✓ Cleanup on error
    // ...
}
```

**Questionable Example:**
```zig
// src/ampe/Pool.zig:61
pub fn get(pool: *Pool, ac: AllocationStrategy) AmpeError!*Message {
    pool.mutex.lock();
    defer pool.*.inform();     // Runs even on error
    defer pool.mutex.unlock(); // Runs even on error
    // ...
}
```

**Question:** Should `inform()` run on error path?

**Recommendation:** Add comment explaining why `inform()` on error is intentional (or fix if it's not).

---

### 6.2 Explicit Types ✅ GOOD (per coding style)

**Pattern:**
```zig
var msg: ?*Message = try ampe.get(.always);  // Explicit type
```

**From CLAUDE.md:**
> Variables should have explicit type annotations for readability without IDE type hints

**Strengths:**
- Consistent with project style
- Helps non-IDE users
- Clear intent

**No concerns.** This is project convention.

---

### 6.3 Comptime Usage ✅ GOOD

**File:** `src/ampe/IntrusiveQueue.zig`

```zig
pub fn IntrusiveQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        first: ?*T = null,
        last: ?*T = null,
        // ...
    };
}
```

**Strengths:**
- Proper generic programming
- Type-safe
- Zero runtime cost

**No concerns.** Textbook Zig.

---

### 6.4 Sentinel Values ⚠️ QUESTIONABLE

**File:** `src/message.zig`

```zig
pub const SpecialMinChannelNumber = std.math.minInt(u16);  // 0
pub const SpecialMaxChannelNumber = std.math.maxInt(u16);  // 65535
```

**Used for:**
- 0: Unassigned channel (Hello/Welcome)
- 65535: Engine internal

**Problem:**
Reduces usable range to 1-65534. Not documented clearly.

**Better:**
```zig
pub const ChannelNumber = enum(u16) {
    unassigned = 0,
    engine_internal = std.math.maxInt(u16),
    _,  // Non-exhaustive
};
```

Then use `@enumFromInt` for normal channels.

**Recommendation:**
Document the special values clearly. Or use enum approach.

---

## 7. Safety Analysis

### 7.1 Undefined Behavior Risks ❌ CRITICAL

**Pattern Found:** Uninitialized fields

**File:** `src/ampe/Reactor.zig:29-47`

```zig
pub const Reactor = @This();

sndMtx: Mutex = undefined,
crtMtx: Mutex = undefined,
shtdwnStrt: bool = undefined,
allocator: Allocator = undefined,
options: tofu.Options = undefined,
msgs: [2]MSGMailBox = undefined,
ntfr: Notifier = undefined,
pool: Pool = undefined,
// ... many more undefined
```

**Then in Create:**
```zig
rtr.* = .{
    .sndMtx = .{},
    .crtMtx = .{},
    .shtdwnStrt = false,
    // ... initialize everything
};
```

**Problem:**
If Create forgets to initialize a field → undefined behavior.

**Safer:**
```zig
pub const Reactor = @This();

sndMtx: Mutex = .{},  // Default init
crtMtx: Mutex = .{},
shtdwnStrt: bool = false,
allocator: Allocator,  // No default - must provide
// ...
```

Then Create can omit fields with good defaults:
```zig
rtr.* = .{
    .allocator = gpa,  // Only provide required fields
};
```

**Recommendation:**
Provide sensible defaults. Only use `= undefined` for fields that MUST be set in init.

---

### 7.2 Assert vs Error Return ⚠️ INCONSISTENT

**Pattern 1: Assert** (crashes in debug, undefined in release)
```zig
// src/ampe/MchnGroup.zig:93
std.debug.assert(sendMsg.*.bhdr.channel_number != 0);
```

**Pattern 2: Error Return**
```zig
if (sendMsg.*.bhdr.channel_number == 0) {
    return AmpeError.InvalidChannelNumber;
}
```

**Problem:**
Inconsistent. When to use which?

**Guideline:**
- **Assert:** Programmer error (bug in tofu)
- **Error return:** User error (bad input)

**Recommendation:**
Document this guideline. Review all asserts to ensure they're programmer errors, not user errors.

---

### 7.3 Null Pointer Handling ✅ GOOD

**Pattern:**
```zig
var msg: ?*Message = try ampe.get(.poolOnly);
if (msg == null) {
    // Handle pool empty
}
defer ampe.put(&msg);  // put() handles null safely
```

**Strengths:**
- Explicit optionals
- Null handling in put()
- Compiler forces null checks

**No concerns.**

---

## 8. Performance Considerations

### 8.1 Intrusive Structures ✅ EXCELLENT

Zero allocation for queuing. Already covered. No concerns.

---

### 8.2 Pool LIFO vs FIFO ⚠️ CONSIDER

**File:** `src/ampe/Pool.zig`

**Current:** LIFO (stack)
```zig
pub fn put(pool: *Pool, msg: *Message) void {
    // ...
    msg.*.next = pool.first;
    pool.first = msg;  // Push to front
}
```

**Question:** Why LIFO?

**LIFO Pros:**
- Better cache locality (recently used message hot in cache)
- Simpler code

**FIFO Pros:**
- More fair distribution
- Avoids message "starvation"

**Recommendation:**
Current LIFO is probably better for performance. Document reasoning.

---

### 8.3 Mutex Contention ⚠️ POTENTIAL BOTTLENECK

**Files:** `Pool.zig`, `channels.zig`

Both use mutexes. Under high load, contention possible.

**Recommendation:**
- Consider lock-free data structures if profiling shows contention
- Or use sharded pools (multiple pools, hash to select)
- Current approach is fine for most workloads

---

### 8.4 Message Clone ⚠️ EXPENSIVE

**File:** `src/message.zig:386`

```zig
pub fn clone(self: *Message) !*Message {
    const alc = self.body.allocator;
    const msg: *Message = try alc.create(Message);
    errdefer msg.*.destroy();

    // Copy all fields
    // Clone body and thdrs
}
```

**Used in:** Reconnection logic (cookbook.zig)

**Problem:**
Full clone is expensive. Most reconnections probably don't need data.

**Recommendation:**
Consider shallow clone option (clone headers only, not body).

---

## 9. Code Quality Issues

### 9.1 Commented Code ❌ REMOVE

**File:** `src/ampe/Notifier.zig:144`

```zig
pub fn isReadyToSend(ntfr: *Notifier) bool {
    // _ = ntfr;
    // return true;
    return _isReadyToSend(ntfr.sender);
}
```

**Recommendation:** Remove commented code. Git history preserves old versions.

---

### 9.2 Magic Numbers ⚠️ SHOULD BE CONSTANTS

**Examples:**

**File:** `src/ampe/Reactor.zig:100`
```zig
rtr.acns = ActiveChannels.init(rtr.allocator, 1024) catch { ... }
```

**File:** `src/message.zig:359-360`
```zig
const blen: u16 = 256;
const tlen: u16 = 64;
```

**Better:**
```zig
pub const DEFAULT_ACTIVE_CHANNELS_CAPACITY: usize = 1024;
pub const DEFAULT_MESSAGE_BODY_LENGTH: u16 = 256;
pub const DEFAULT_MESSAGE_HEADERS_LENGTH: u16 = 64;
```

**Recommendation:**
Extract all magic numbers to named constants.

---

### 9.3 Naming Inconsistencies ⚠️ MINOR

**Mixed conventions:**
- `Create` vs `init` (functions that create instances)
- `Destroy` vs `deinit` (functions that clean up)

**Example:**
```zig
pub fn Create(gpa: Allocator, ...) !*Reactor  // Capital C
pub fn Destroy(rtr: *Reactor) void            // Capital D
```

vs

```zig
pub fn init(...) !Pool      // lowercase
pub fn deinit(...) void     // lowercase
```

**Zig Convention:**
- `init` / `deinit` for non-allocating
- `create` / `destroy` when allocating

**Recommendation:**
Follow Zig convention consistently:
- `Reactor.create()` not `Reactor.Create()`
- `reactor.destroy()` not `reactor.Destroy()`

---

## 10. Zig 0.14 → 0.15 Migration Concerns

### 10.1 Potential Breaking Changes

Based on Zig evolution, watch for:

**1. Error handling changes**
- Error return traces may change
- `anyerror` deprecated (tofu doesn't use it ✓)

**2. Packed struct alignment**
- May become stricter
- Test `BinaryHeader` size carefully

**3. Atomic API changes**
- `.monotonic` → may change
- Watch stdlib changes

**4. Build system**
- `build.zig` API changes likely
- Test after migration

**Recommendation:**
Run full test suite after Zig upgrade. Pay attention to packed structs and atomics.

---

## 11. Summary of Recommendations

### Critical (Fix Before 1.0)

1. **Reduce `?*anyopaque` usage** - Add runtime type checks at minimum
2. **Fix undefined field initialization** - Provide defaults where possible
3. **Fix typo** - `invelid_mchn_group` → `invalid_mchn_group`
4. **Remove TODOs from public API** - Resolve or remove `src/ampe.zig:7`

### High Priority

5. **Simplify error handling** - Consolidate status/error conversions
6. **Add error context** - Log original errors before converting to AmpeError
7. **Document mutex ordering** - Prevent potential deadlocks
8. **Review all asserts** - Ensure they're programmer errors not user errors

### Medium Priority

9. **Extract magic numbers** - Named constants improve maintainability
10. **Consistent naming** - `create`/`destroy` not `Create`/`Destroy`
11. **Remove commented code** - Clean up production code
12. **Document special channel numbers** - 0 and 65535 are special

### Low Priority (Nice to Have)

13. **Consider shallow clone** - Performance optimization for reconnection
14. **Profile mutex contention** - Optimize if needed
15. **Document LIFO pool choice** - Explain reasoning

---

## 12. Positive Highlights

What tofu does well:

1. **Intrusive data structures** - Zero allocation queuing
2. **Ownership transfer** - Excellent use of Zig pointers
3. **Thread safety documentation** - Clear what's safe where
4. **Packed structs** - Proper network protocol handling
5. **Defer/errdefer** - Good cleanup patterns
6. **Pool pattern** - Smart memory management
7. **Message-as-cube philosophy** - Clean architecture

---

## 13. Conclusion

Tofu is solid Zig code with good understanding of the language. Main concerns:

**Safety:**
- Too much `?*anyopaque` reduces type safety
- Undefined field initialization risky

**Maintainability:**
- Dual error system confusing
- TODOs and commented code in production

**Performance:**
- Generally good
- Watch for mutex contention under load

**Overall:** Fix critical items before 1.0. Rest can be iterative improvements.

---

## Files Analyzed

All source files under `src/` reviewed:
- `src/tofu.zig`
- `src/ampe.zig`
- `src/message.zig`
- `src/status.zig`
- `src/configurator.zig`
- `src/ampe/Reactor.zig`
- `src/ampe/Pool.zig`
- `src/ampe/MchnGroup.zig`
- `src/ampe/channels.zig`
- `src/ampe/Notifier.zig`
- `src/ampe/Skt.zig`
- `src/ampe/SocketCreator.zig`
- `src/ampe/IntrusiveQueue.zig`
- `src/ampe/vtables.zig`
- `src/ampe/poller.zig`
- `src/ampe/triggeredSkts.zig`
- `src/ampe/internal.zig`
- `src/ampe/testHelpers.zig`

**Review Complete**
