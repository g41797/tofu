# Using Claude Code for Zig Refactoring

## What is Claude Code?

Claude Code is a terminal-based AI coding assistant that can:
- ✅ Edit files directly in your project
- ✅ Run shell commands
- ✅ Execute terminal operations
- ✅ Work with entire codebases

Perfect for project-wide refactoring tasks!

---

## Quick Start (3 Steps)

### Step 1: Navigate to Your Project

```bash
cd /path/to/your/zig/project
```

### Step 2: Start Claude Code

```bash
claude-code
```

### Step 3: Paste This Prompt

```
Refactor all Zig files in this project:

1. Replace automatic pointer dereference with explicit ptr.* syntax
2. Add explicit types to all variable declarations

[Copy the rest from CLAUDE_CODE_QUICK.txt]
```

**That's it!** Claude Code will process your entire project.

---

## Detailed Walkthrough

### Installation (If Needed)

```bash
# Install Claude Code (if not already installed)
# Follow instructions from Anthropic's documentation
```

### Pre-Refactoring Checklist

- [ ] Project compiles: `zig build`
- [ ] Git repo clean: `git status`
- [ ] Create backup branch: `git checkout -b refactor-explicit-types`
- [ ] In project root directory

### Starting Claude Code Session

```bash
# Navigate to project
cd ~/my-zig-project

# Start Claude Code
claude-code

# Claude Code will initialize and be ready for your prompt
```

### The Refactoring Conversation

```
You: Refactor all Zig files in this project:
     1. Replace automatic pointer dereference with explicit ptr.* syntax
     2. Add explicit types to all variable declarations
     
     [Include rules from CLAUDE_CODE_PROMPT.md or CLAUDE_CODE_QUICK.txt]

Claude: I'll refactor your Zig project. Let me start by finding all .zig files...
        
        [Lists files found]
        
        Found 15 .zig files. Creating TYPE_REFERENCE.md...
        
        [Analyzes code and extracts types]
        
        Processing src/main.zig...
        - Added 12 pointer dereferences
        - Added 8 type annotations
        ✓ Comments preserved
        ✓ Syntax valid
        
        Processing src/reactor.zig...
        - Added 23 pointer dereferences
        - Added 15 type annotations
        ✓ Comments preserved
        ✓ Syntax valid
        
        [... continues for all files ...]
        
        All files processed. Creating REFACTORING_SUMMARY.md...
        
        Summary:
        - 15 files processed
        - 187 pointer dereferences added
        - 142 type annotations added
        
        Running zig build to verify...
        ✓ Build successful
        
        Refactoring complete! Review the changes:
        - TYPE_REFERENCE.md - All types discovered
        - REFACTORING_SUMMARY.md - Detailed statistics

You: Great! Can you show me what changed in src/main.zig?

Claude: [Shows git diff or file comparison]

You: Perfect! Let me review the changes.
```

### Post-Refactoring Steps

```bash
# Review changes
git diff --stat

# Check specific file
git diff src/main.zig

# Build and test
zig build
zig test tests/all.zig

# Review summary
cat REFACTORING_SUMMARY.md

# If satisfied, commit
git add -A
git commit -m "refactor: add explicit types and pointer dereferencing"

# If not satisfied, revert
git checkout .
```

---

## Example Claude Code Session

### Initial Prompt (Copy/Paste Ready)

```
I need you to refactor all Zig files in this project. Apply these two changes:

1. EXPLICIT POINTER DEREFERENCING
   Replace: msg.?.field → msg.?.*.field
   Replace: msg.?.method() → msg.?.*.method()
   Replace: ptr.field → ptr.*.field

2. EXPLICIT TYPE ANNOTATIONS
   Replace: var rtr = try Reactor.Create(...) → var rtr: *Reactor = try Reactor.Create(...)
   Replace: var msg = try ampe.get(...) → var msg: ?*Message = try ampe.get(...)
   Replace: const allocator = engine.getAllocator() → const allocator: Allocator = engine.getAllocator()

Common types: *Reactor, Ampe, ChannelGroup, ?*Message, BinaryHeader, u8, Allocator, []u8

DO NOT change:
- Module imports
- Type aliases
- Struct definitions
- Comments (CRITICAL: preserve all)

Process:
1. Find all .zig files
2. Create TYPE_REFERENCE.md
3. Refactor each file in-place
4. Create REFACTORING_SUMMARY.md
5. Verify with zig build

Start now.
```

### Follow-Up Commands

```
# If Claude asks about specific types:
You: The function signatures are:
     - MyClass.create() returns *MyClass
     - MyClass.getData() returns []const u8

# If you want to check progress:
You: Show me the current status

# If you want to see changes in a specific file:
You: Show me what changed in src/reactor.zig

# If something looks wrong:
You: Wait, don't modify the comments in that file. 
     The comments should stay exactly as they were.

# To verify a specific file:
You: Can you verify that src/main.zig compiles?
```

---

## Advanced Usage

### Custom Type Definitions

If your project has custom types, provide them upfront:

```
Additional type signatures for this project:

// Custom types
var client: *TofuClient = TofuClient.create(...)
var server: *TofuEchoServer = TofuEchoServer.create(...)
const config: Config = Config.init(...)
var buffer: [256]u8 = undefined
const status: ConnectionStatus = connection.getStatus()

Please use these when refactoring.
```

### Selective Refactoring

To refactor specific files only:

```
Refactor only these files:
- src/main.zig
- src/reactor.zig
- lib/utils.zig

Apply the same rules as before.
```

### Incremental Approach

For large projects:

```
Let's do this incrementally:
1. First, just list all .zig files and create TYPE_REFERENCE.md
2. Then, refactor files in src/ directory only
3. I'll review those before we continue with lib/
```

---

## Troubleshooting

### Issue: Claude Code Can't Find Files

**Problem:** Claude says it can't find .zig files

**Solution:**
```
You: List all files in the current directory
     [Verify you're in the right place]
     
You: Please search recursively: find . -name "*.zig"
```

### Issue: Unknown Types

**Problem:** Claude doesn't know what type a function returns

**Solution:**
```
You: For the function MyClass.process(), it returns: Result!*MyClass
     Please use this type when refactoring.
```

### Issue: Build Fails After Refactoring

**Problem:** `zig build` fails after refactoring

**Solution:**
```
You: The build failed. Can you check src/main.zig for syntax errors?
     [Claude will analyze and fix]
     
You: Please show me the error and the problematic lines
```

### Issue: Comments Were Modified

**Problem:** Comments changed (this should NOT happen)

**Solution:**
```
You: STOP. The comments in src/reactor.zig were modified.
     Please restore them to exactly what they were before.
     Comments must never be changed.
```

### Issue: Too Many Changes at Once

**Problem:** Hard to review all changes

**Solution:**
```
You: Please show me just the type annotation changes, not the pointer dereferences
     
     [Review]
     
You: Now show me just the pointer dereference changes
```

---

## Tips & Best Practices

### 1. Start Small
```
You: Let's test on one file first: src/utils.zig
     [Review the output]
You: Good! Now do the rest.
```

### 2. Provide Context
```
You: This is a network protocol library using message passing.
     Key types are Reactor, Ampe, Message, and BinaryHeader.
     [Claude will understand context better]
```

### 3. Incremental Verification
```
You: After refactoring each file, run zig build-exe on it to verify
```

### 4. Use Git for Safety
```bash
# Before starting
git checkout -b refactor-backup
git commit -m "backup before refactoring"

# During refactoring, you can always:
git diff src/main.zig  # Review changes
git checkout src/main.zig  # Revert if needed
```

### 5. Document Custom Types
Keep a `types.txt` in your project:
```
# Project Types
Reactor.Create() -> *Reactor
ampe.get() -> ?*Message
MyClass.init() -> *MyClass
```

Then:
```
You: Use the types from types.txt when refactoring
```

---

## Expected Output

After completion, you should have:

### 1. Modified Files
All `.zig` files with:
- Explicit pointer dereferencing
- Explicit type annotations
- All comments preserved

### 2. TYPE_REFERENCE.md
```markdown
# Type Reference

## reactor.zig
- Reactor.Create() returns *Reactor
- rtr.ampe() returns Ampe
...

## message.zig
- ampe.get() returns ?*Message
...
```

### 3. REFACTORING_SUMMARY.md
```markdown
# Summary
- Files: 15
- Pointer dereferences: 187
- Type annotations: 142

## Details
src/main.zig: 12 + 8 changes
src/reactor.zig: 23 + 15 changes
...
```

### 4. Verified Build
```bash
$ zig build
# Should complete successfully
```

---

## Comparison: Claude Code vs Browser Claude

| Feature | Claude Code | Browser Claude |
|---------|-------------|----------------|
| File editing | ✅ In-place | ❌ Creates copies |
| Terminal access | ✅ Full | ❌ Limited |
| Batch processing | ✅ Native | ⚠️ Manual |
| Project structure | ✅ Preserves | ⚠️ Need manual copy |
| Verification | ✅ Can run zig build | ❌ Manual |
| Best for | Complete projects | Individual files |

**Recommendation:** Use Claude Code for project-wide refactoring!

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────────┐
│ CLAUDE CODE: ZIG REFACTORING                        │
├─────────────────────────────────────────────────────┤
│                                                     │
│ START:                                              │
│   cd /path/to/project                               │
│   claude-code                                       │
│   [Paste prompt from CLAUDE_CODE_QUICK.txt]        │
│                                                     │
│ RULES:                                              │
│   msg.?.field → msg.?.*.field                       │
│   var x = ... → var x: Type = ...                   │
│   PRESERVE ALL COMMENTS                             │
│                                                     │
│ TYPES:                                              │
│   *Reactor, Ampe, ChannelGroup                      │
│   ?*Message, BinaryHeader, u8, Allocator            │
│                                                     │
│ VERIFY:                                             │
│   zig build                                         │
│   git diff --stat                                   │
│   cat REFACTORING_SUMMARY.md                        │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## Ready to Start?

1. ✅ Backup your code: `git checkout -b refactor-explicit-types`
2. ✅ Navigate to project: `cd /path/to/project`
3. ✅ Start Claude Code: `claude-code`
4. ✅ Paste prompt from `CLAUDE_CODE_QUICK.txt`
5. ✅ Review output and verify
6. ✅ Commit if satisfied

Happy refactoring! 🚀
