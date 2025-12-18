# Git Interaction Rule for Claude

## ⚡ Quick Copy-Paste Instructions

### For Custom Instructions / Project Prompts
```
Git Rule: Never execute git commands automatically. Always ask for permission first 
before running git add, commit, push, or any git operation. Suggest commands but 
wait for explicit user approval.
```

### For Session Start
```
Remember: Ask before running any git commands.
```

## Rule to Add to System Prompt

Add the following rule to Claude's system prompt or instructions:

```
<git_interaction_rule>
Claude must NEVER perform git operations automatically without explicit user permission.

Before executing ANY git command, Claude must:
1. Explain what git operation it wants to perform
2. Show the exact git command(s) it intends to run
3. Wait for explicit user approval

Git operations include but are not limited to:
- git init
- git add
- git commit
- git push
- git pull
- git clone
- git checkout
- git branch
- git merge
- git rebase
- git stash
- git reset
- git revert
- .gitignore creation or modification
- Any git configuration changes

Exception: Claude may READ git status information (git status, git log, git diff) 
for informational purposes if it helps answer a user's question, but should still 
mention that it's checking git status.

If a task naturally involves version control, Claude should:
1. Complete the requested work (file creation, refactoring, etc.)
2. Suggest git commands the user might want to run
3. Ask if the user would like Claude to execute those commands

Example good response:
"I've completed the refactoring of your files. If you'd like to commit these changes 
to git, you could run:
  git add MultiHomed.zig services.zig
  git commit -m "Refactor: Add explicit types to improve readability"

Would you like me to execute these git commands for you?"

Example bad response:
[Claude automatically runs git add and git commit without asking]
</git_interaction_rule>
```

## Short Version (for space-constrained prompts)

```
CRITICAL: Never execute git commands automatically. Always ask user permission first 
before any git operation (add, commit, push, etc.). Suggest commands but wait for approval.
```

## Why This Rule Is Important

1. **User Control**: Users should have full control over their version control workflow
2. **Commit Messages**: Users may want specific commit messages or formats
3. **Branch Management**: Users may have specific branching strategies
4. **Safety**: Prevents accidental commits, pushes, or repository modifications
5. **Workflow Respect**: Different teams have different git workflows and conventions

## How to Use This Rule

### Option 1: Add to Custom Instructions (Claude.ai)
1. Go to your Claude settings
2. Add this to "Custom instructions" or "How would you like Claude to respond?"
3. Include the short or long version depending on space

### Option 2: Add to Project Instructions
If using Claude Projects:
1. Create a file called `GIT_RULES.md` in your project
2. Add the rule content
3. Reference it in project instructions: "Follow the git interaction rules in GIT_RULES.md"

### Option 3: Include in Each Session
Start each session with:
"Remember: Don't perform any git operations automatically. Always ask me first before running git commands."

## Testing the Rule

Try these prompts to verify the rule is working:

❌ **Bad (should not happen):**
"Refactor these files" → Claude automatically commits changes

✅ **Good (should happen):**
"Refactor these files" → Claude refactors, then ASKS if you want to commit

## Example Session with Rule Active

**User:** "Please refactor cookbook.zig to add explicit types"

**Claude (Good Response):**
"I'll refactor cookbook.zig to add explicit types.
[Performs refactoring work]
Done! I've added ~119 explicit type annotations. The refactored file is ready.

Would you like me to commit these changes to git? If so, I can run:
- git add cookbook.zig
- git commit -m 'Refactor: Add explicit types for better readability'

Let me know if you'd like me to proceed with git commands or if you prefer to handle version control yourself."

**User:** "Yes, please commit"

**Claude:**
"I'll commit the changes now.
[Executes git commands]
Done! Changes committed."

## Additional Considerations

### When Git Might Be Helpful
- User is clearly working on a git repository
- Changes are significant and should be tracked
- User has a history of requesting git operations

### When Git Should Definitely Wait
- First interaction with a user
- User hasn't mentioned git or version control
- Repository status is unclear
- Multiple files are being modified (user may want selective commits)
- Working on a feature branch (user may have specific workflow)

## Integration with Existing Rules

This rule complements existing guidelines:
- File creation rules (create files but don't auto-commit)
- Refactoring rules (refactor code but don't auto-commit)
- Code generation rules (generate code but don't auto-commit)

The general principle: **Claude can CREATE and MODIFY, but should ASK before COMMITTING**.
