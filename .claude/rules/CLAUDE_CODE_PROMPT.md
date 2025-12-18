# Claude Code Prompt: Zig Project Refactoring

## Task Overview
Refactor all Zig files in the current project to:
1. Replace automatic pointer dereference with explicit `ptr.*` syntax
2. Add explicit types to all variable declarations

## Context
This refactoring improves code readability for developers without IDE type hints. The changes are purely syntactic with zero functionality changes.

---

## Refactoring Rules

### 1. Explicit Pointer Dereferencing

**Rule:** Replace automatic dereference with explicit `.*` syntax

```zig
// BEFORE (automatic dereference)
msg.?.bhdr.status = 0;
msg.?.copyBh2Body();
self.ptr.method();
result.destroy();

// AFTER (explicit dereference)
msg.?.*.bhdr.status = 0;
msg.?.*.copyBh2Body();
self.ptr.*.method();
result.*.destroy();
```

**Key Patterns:**
- `optional.?field` → `optional.?.*.field`
- `optional.?method()` → `optional.?.*.method()`
- `ptr.field` → `ptr.*.field`
- `ptr.method()` → `ptr.*.method()`

**Important:** Zig dereference is `ptr.*` (NOT `*ptr` like C)

### 2. Explicit Type Annotations

**Rule:** Add explicit types to all variable declarations

```zig
// BEFORE (type inference)
var rtr = try Reactor.Create(gpa, options);
const ampe = try rtr.ampe();
var msg = try ampe.get(strategy);
const allocator = engine.getAllocator();

// AFTER (explicit types)
var rtr: *Reactor = try Reactor.Create(gpa, options);
const ampe: Ampe = try rtr.ampe();
var msg: ?*Message = try ampe.get(strategy);
const allocator: Allocator = engine.getAllocator();
```

---

## Common Type Reference

Use these types when adding annotations:

```zig
// Engine/Reactor types
var rtr: *Reactor = try Reactor.Create(...)
const ampe: Ampe = try rtr.*.ampe()
const chnls: ChannelGroup = try ampe.create()

// Message types
var msg: ?*Message = try ampe.get(...)
var recvMsg: ?*Message = try chnls.waitReceive(...)
var next: ?*Message = msgq.dequeue()

// Protocol types
const bhdr: BinaryHeader = try chnls.enqueueToPeer(...)
const st: u8 = msg.?.*.bhdr.status
const sts: AmpeStatus = status.raw_to_status(...)
const lstChannel: message.ChannelNumber = bhdr.channel_number

// System types
const allocator: Allocator = engine.getAllocator()
const port: u16 = try tofu.FindFreeTcpPort()
const filePath: []u8 = try tup.buildPath(...)

// Thread types
const thread: std.Thread = try std.Thread.spawn(...)

// Client/Server types
var client: *TofuClient = try TofuClient.create(...)
var server: *TofuServer = try TofuServer.create(...)
const result: *Self = try allocator.create(Self)
```

---

## What NOT to Change

**DO NOT modify:**

1. **Module imports:**
   ```zig
   const std = @import("std");
   const tofu = @import("tofu");
   ```

2. **Type aliases:**
   ```zig
   pub const Ampe = tofu.Ampe;
   const Allocator = std.mem.Allocator;
   const MSGMailBox = mailbox.MailBoxIntrusive(Message);
   ```

3. **Struct definitions:**
   ```zig
   const TofuClient = struct { ... };
   pub const Services = struct { ... };
   ```

4. **Self-reference patterns:**
   ```zig
   const Self = @This();
   ```

5. **Array length inference (optional to keep):**
   ```zig
   var array = [_]Type{ ... };  // Can keep [_] or make explicit
   ```

---

## Execution Plan

### Phase 1: Discovery
1. Find all `.zig` files in the project
2. Analyze key files for type signatures
3. Create `TYPE_REFERENCE.md` with discovered types
4. Identify files that need refactoring

### Phase 2: Refactoring
For each `.zig` file:
1. Read the entire file
2. Apply pointer dereference fixes
3. Apply type annotation fixes
4. **VERIFY all comments are preserved**
5. Write to the same file (in-place editing)
6. Track statistics

### Phase 3: Documentation
1. Create `REFACTORING_SUMMARY.md` with:
   - Total files processed
   - Total changes made
   - File-by-file breakdown
2. List any files that need manual review

---

## Critical Requirements

### ⚠️ MUST PRESERVE COMMENTS
- **NEVER remove or modify any comments**
- Comments are essential documentation
- Verify comment preservation after each file

### ⚠️ ZERO FUNCTIONALITY CHANGES
- Only syntax/readability changes
- No logic modifications
- No behavioral changes

### ⚠️ IN-PLACE EDITING
- Modify files directly (don't create copies)
- This is a terminal workflow, not browser-based

---

## Implementation Strategy

### Suggested Approach

```bash
# 1. List all .zig files
find . -name "*.zig" -type f

# 2. For each file, apply refactoring
# Use your code editing capabilities to:
#   a) Read file
#   b) Apply pointer dereference fixes
#   c) Apply type annotations
#   d) Write back to file

# 3. Track changes and create summary
```

### File Processing Order
1. Start with utility/helper files
2. Then core modules (reactor, message, etc.)
3. Then high-level modules (services, client/server)
4. Finally main files

### Verification After Each File
- Check syntax (no compilation errors)
- Verify comments preserved
- Confirm directory structure unchanged

---

## Example Changes

### Example 1: MultiHomed.zig

**Before:**
```zig
const allocator = mh.*.allocator.?;
var next = mh.*.msgq.dequeue();
```

**After:**
```zig
const allocator: Allocator = mh.*.allocator.?;
var next: ?*Message = mh.*.msgq.dequeue();
```

### Example 2: services.zig

**Before:**
```zig
const allocator = self.*.gpa;
msg.?.copyBh2Body();
```

**After:**
```zig
const allocator: Allocator = self.*.gpa;
msg.?.*.copyBh2Body();
```

### Example 3: cookbook.zig

**Before:**
```zig
var rtr = try Reactor.Create(gpa, options);
const ampe = try rtr.ampe();
var msg = try ampe.get(tofu.AllocationStrategy.always);
msg.?.bhdr.proto.mtype = .bye;
```

**After:**
```zig
var rtr: *Reactor = try Reactor.Create(gpa, options);
const ampe: Ampe = try rtr.ampe();
var msg: ?*Message = try ampe.get(tofu.AllocationStrategy.always);
msg.?.*.bhdr.proto.mtype = .bye;
```

---

## Pattern Recognition Guide

### Pattern 1: Optional Pointer Field Access
```zig
// Find: optional.?.<field>
// Replace: optional.?.*.<field>

msg.?.bhdr → msg.?.*.bhdr
self.ptr.?.data → self.ptr.?.*.data
```

### Pattern 2: Optional Pointer Method Call
```zig
// Find: optional.?.<method>()
// Replace: optional.?.*.<method>()

msg.?.copyBh2Body() → msg.?.*.copyBh2Body()
client.?.destroy() → client.?.*.destroy()
```

### Pattern 3: Variable Assignment from Function
```zig
// Find: var <name> = try <function>
// Replace: var <name>: <Type> = try <function>

var rtr = try Reactor.Create(...) → var rtr: *Reactor = try Reactor.Create(...)
var msg = try ampe.get(...) → var msg: ?*Message = try ampe.get(...)
```

### Pattern 4: Const Assignment from Property
```zig
// Find: const <name> = <expr>.<property>
// Replace: const <name>: <Type> = <expr>.<property>

const st = msg.?.*.bhdr.status → const st: u8 = msg.?.*.bhdr.status
const allocator = gpa → const allocator: Allocator = gpa
```

---

## Output Format

### REFACTORING_SUMMARY.md Template

```markdown
# Zig Project Refactoring Summary

## Statistics
- Total .zig files found: X
- Files modified: Y
- Pointer dereferences added: Z
- Type annotations added: W

## Changes by File

### src/main.zig
- Pointer dereferences: +5
- Type annotations: +3
- Lines modified: 8

### src/reactor.zig
- Pointer dereferences: +12
- Type annotations: +7
- Lines modified: 19

[... continue for all files ...]

## Type Reference

Common types discovered:
- `Reactor.Create()` returns `*Reactor`
- `ampe.get()` returns `?*Message`
- `chnls.waitReceive()` returns `?*Message`
[... etc ...]

## Verification

✅ All files compile successfully
✅ All comments preserved
✅ No functionality changes
✅ Directory structure unchanged

## Files Requiring Manual Review

[List any files with complex patterns that need manual attention]

## Next Steps

1. Run `zig build` to verify compilation
2. Run test suite if available
3. Review git diff for sanity check
4. Commit changes
```

---

## Workflow Commands

When executing, use commands like:

```bash
# List all Zig files
ls -R **/*.zig

# For each file (in your code):
# 1. Read file content
# 2. Apply transformations
# 3. Write back to file
# 4. Verify syntax

# Final verification
zig build

# Check git diff
git diff --stat
```

---

## Edge Cases to Handle

### Complex Expressions
```zig
// May need manual review:
result.?.data.?.array[0].field
self.*.chnls.?.enqueueToPeer(&msg).channel_number

// Apply refactoring step by step:
result.?.*.data.?.*.array[0].field
self.*.chnls.?.enqueueToPeer(&msg).channel_number  // method calls return values
```

### Already Explicit
```zig
// Don't double-apply:
msg.?.*.bhdr  // Already explicit - don't change to msg.?.*.*.bhdr
var msg: ?*Message = ...  // Already typed - don't change
```

### Method Chains
```zig
// Be careful with chaining:
obj.method1().method2()  // Only obj needs dereference if it's a pointer
obj.*.method1().method2()  // Correct if obj is a pointer
```

---

## Success Criteria

✅ All `.zig` files processed
✅ All pointer dereferences explicit (`ptr.*` before field/method access)
✅ All variables have explicit types (except allowed exceptions)
✅ All comments preserved exactly
✅ `zig build` succeeds
✅ No functionality changes
✅ Summary document created
✅ Type reference document created

---

## Start Command

To begin refactoring, execute:

**"Please refactor all Zig files in this project following the rules above. Start by listing all .zig files, then process them one by one, and finally create the summary documents."**

---

## Notes for Claude Code

- You have full file system access - use it
- Edit files in-place (terminal workflow)
- Show progress as you go
- Ask for clarification if types are unknown
- Report any files that need manual review
- Create comprehensive documentation

This is a code quality improvement task. Take your time and be thorough!
