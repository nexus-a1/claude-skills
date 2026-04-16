---
name: commit
category: release-management
model: haiku
userInvocable: true
description: Stage and commit changes with a conventional commit message. Runs pre-commit checks automatically. Optionally prefixes with a ticket number.
argument-hint: "[ticket-number]"
allowed-tools: "Bash(GIT_AUTHORIZED=1 git commit:*), Bash(GIT_AUTHORIZED=1 git checkout:*), Bash(git branch:*), Bash(git log:*), Bash(./vendor/bin/php-cs-fixer:*), Bash(php-cs-fixer:*), Bash(test:*), Bash(which:*), Task, AskUserQuestion"
---

# Git Commit Command

## Context

Recent commits for reference: !`git log --oneline -5 2>/dev/null || echo "No previous commits (this will be the first commit)"`

Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repository)"`

## Your Task

**IMPORTANT**: Complete all steps in a single message using parallel tool calls.

### 1. Determine Ticket Number

Priority order for ticket number (argument: $ARGUMENTS):

1. **From argument**: If provided, validate it matches pattern `[A-Z]+-[0-9]+`
2. **From branch name**: Extract from patterns like `feature/JIRA-123-description`
   - Support prefixes: `feature/`, `fix/`, `hotfix/`
   - Pattern: `[A-Z]+-[0-9]+` (e.g., `JIRA-123`, `SKILLS-001`, `PROJ-456`)
   - Examples:
     - `feature/JIRA-2232-some-updates` → `JIRA-2232`
     - `fix/SKILLS-456-bug-fix` → `SKILLS-456`
3. **None**: Proceed without ticket number (only if branch has no ticket pattern)

**Extraction command:**
```bash
branch=$(git branch --show-current)
ticket=$(echo "$branch" | grep -oE '[A-Z]+-[0-9]+' | head -1)
echo "Ticket: ${ticket:-none}"
```

**IMPORTANT**: If branch contains a ticket number, it MUST be included in the commit message.

### 2. Check Branch Safety

If on `main` or `master`:
- Create a new feature branch: `feature/[ticket]-description` or `feature/[description]`
- Use `GIT_AUTHORIZED=1 git checkout -b [branch-name]`

### 3. Run PHP CS Fixer (if available)

- Check: `test -f ./vendor/bin/php-cs-fixer` or `which php-cs-fixer`
- If available, run on modified PHP files only
- Skip silently if not available or no PHP files modified

### 4. Stage Changes and Generate Commit Message

Delegate staging and commit message generation to `git-operator` in a single call. The agent will run `git status` and `git diff` internally to understand the changes, run a **mandatory credential content scan** on the files about to be staged (filename exclusion is not enough — embedded tokens in otherwise-innocuous files are the usual leak vector), stage appropriate files, and return a formatted commit message.

**Use Task tool with `subagent_type: "git-operator"`:**

```
Prompt: Stage all modified files (avoid .env, credentials, secrets) and generate a commit message.

Ticket Number: {ticket_number or "None"}
Branch: {current_branch}

Recent commits for style reference:
{recent_commits}

Commit message requirements:
- Follow conventional commit format: [TICKET-123] type(scope): description
- Ticket MUST be in square brackets: [JIRA-123] not JIRA-123:
- Ticket format: [A-Z]+-[0-9]+ (e.g., JIRA-123, SKILLS-001)
- Use imperative mood, keep subject line under 50 characters
- Ticket prefix should preserve original casing
- NO footers, NO attribution, NO Co-Authored-By lines

Return ONLY the commit message, nothing else.
```

**The agent will stage the files and return** the formatted commit message ready to use.

**If git-operator reports credential-scan findings:** staging is refused. Show the findings to the user verbatim (file:line:label — never echo the matched secret). Ask the user whether each finding is a true leak or a false positive. If confirmed false positive, re-invoke git-operator with an explicit override clause: `override credential scan: <reason>`. The override reason is recorded in the commit message body so the decision is traceable. Never override silently, and never override without an explicit user confirmation.

### 5. Create the Commit

```bash
GIT_AUTHORIZED=1 git commit -m "[TICKET] type(scope): description"
```

**Rules:**
- NO footers or attribution
- NO "Generated with Claude Code"
- NO "Co-Authored-By" lines
- Simple, clean message only

### 6. Report Results

Show:
- Commit hash
- Commit message
- Files changed

## Important Notes

- **Single message execution** - Complete all steps in one response
- **Branch safety** - Never commit directly to main/master
- **Clean messages** - No AI attribution or footers
- **Do NOT push** - User will push manually
