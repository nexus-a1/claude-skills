---
name: local-pr-review
model: sonnet
category: code-quality
userInvocable: true
description: Review local branch changes before creating a pull request
argument-hint: "[base-branch]"
allowed-tools: "Read, Glob, Grep, Bash(git diff:*), Bash(git log:*), Bash(git branch:*), Bash(git merge-base:*), Bash(git rev-parse:*), Bash(git status:*), Bash(git push:*), Bash(gh pr create:*), Bash(gh pr view:*), Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage"
---

# Local PR Review Command

## Context

Current branch: !`git branch --show-current`
Available local branches: !`git branch --format='%(refname:short)' | head -20`
Uncommitted changes: !`git status --short | head -10`

Arguments (if provided): $ARGUMENTS

## Configuration

```bash
# Source resolve-config: marketplace installs get ${CLAUDE_PLUGIN_ROOT} substituted
# inline before bash runs; ./install.sh users fall back to ~/.claude. If neither
# path resolves, fail loudly rather than letting resolve_artifact be undefined.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found. Install via marketplace or run ./install.sh" >&2
  exit 1
fi
REVIEW_EXEC_MODE=$(resolve_exec_mode local_pr_review team)
```

Use `$REVIEW_EXEC_MODE` to determine team vs sub-agent behavior in Step 4.

## Your Task

Review all changes on the current branch compared to a base branch **before** creating a pull request. This is a pre-flight check — catch issues early, fix them locally, then optionally create the PR.

---

### 1. Validate State

**Check for uncommitted changes:**
```bash
git status --short
```

If there are uncommitted changes, use AskUserQuestion:
- "You have uncommitted changes. How would you like to proceed?"
- Options: Stash and continue / Review with uncommitted changes included / Cancel

**Check current branch is not main/master:**
If on `main`, `master`, or `develop`, stop with a message: "You're on a base branch. Switch to a feature branch first."

---

### 2. Determine Base Branch

**If base branch provided in $ARGUMENTS:** Use it directly.

**If not provided**, auto-detect by trying in order:
1. Check if upstream tracking branch is set: `git rev-parse --abbrev-ref @{upstream} 2>/dev/null`
2. Check for common base branches: `main`, `master`, `develop`
3. If multiple exist, use AskUserQuestion to let user pick

**Validate the base branch exists:**
```bash
git rev-parse --verify {base_branch} 2>/dev/null
```

If it doesn't exist, show available branches and ask user to pick.

---

### 3. Gather Diff and Commit History

```bash
# Find common ancestor
MERGE_BASE=$(git merge-base {base_branch} HEAD)

# Get the full diff against base
git diff {base_branch}...HEAD

# Get list of changed files with stats
git diff {base_branch}...HEAD --stat

# Get commit log for this branch
git log {base_branch}..HEAD --oneline --no-decorate

# Get detailed commit messages
git log {base_branch}..HEAD --format="%h %s%n%b" --no-decorate
```

**If no diff exists:** Stop with message: "No changes found between current branch and {base_branch}. Nothing to review."

---

### 4. Run Review Agents

**Execution mode**: Determined by `$REVIEW_EXEC_MODE`.

Delegate the review to specialized agents with cross-validation via quality-guard.

**If `$REVIEW_EXEC_MODE` = `"subagent"`:**

**Run all three agents — first two in parallel, then skeptic:**

#### Step 1: Parallel review

**Execute in a single message with multiple Task tool calls:**

**Task 1 — Use Task tool with `subagent_type: "code-reviewer"`:**

```
Prompt: Review this branch diff for code quality issues.

Branch: {current_branch} → {base_branch}
Commits: {commit_count}
Files changed: {file_count}

Commit history:
{commit_log}

Focus on:
- Logic errors and correctness
- Code quality and maintainability
- Error handling
- Performance issues
- Best practices
- Test coverage

Diff:
{full_diff}
```

**Task 2 — Use Task tool with `subagent_type: "security-auditor"`:**

```
Prompt: Review this branch diff for security vulnerabilities.

Branch: {current_branch} → {base_branch}
Files changed: {file_list}

Focus on:
- Injection vulnerabilities (SQL, XSS, command)
- Authentication/authorization issues
- Data exposure risks
- Input validation gaps
- Sensitive data handling
- Hardcoded secrets or credentials

Diff:
{full_diff}
```

#### Step 2: Skeptic challenge

After both reviewers complete, run the skeptic:

**Task 3 — Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Challenge the PR review findings (Level 2 — Implementation Validation).

Branch diff: {full_diff}
Code-reviewer findings: {code_reviewer_output}
Security-auditor findings: {security_auditor_output}

Verify:
1. Are the CRITICAL findings real? Check the actual code — verify file paths and line numbers.
2. Did both reviewers miss anything? Trace through key code paths yourself.
3. Do code-reviewer and security-auditor contradict each other on any file?
4. Are there any issues that fall between the two reviewers' scopes?

Produce a Quality Review Gates report.
```

---

**If `$REVIEW_EXEC_MODE` = `"team"` (default):**

Create a review team for real-time cross-pollination:

```
TeamCreate(team_name="local-review-{branch}")

TaskCreate: "Review code quality" (T1)
  description: |
    Branch: {current_branch} → {base_branch}. Diff: {full_diff}.
    Focus on logic, performance, code quality. Share findings with teammates.

TaskCreate: "Review security" (T2)
  description: |
    Branch: {current_branch} → {base_branch}. Diff: {full_diff}.
    Focus on injection, auth, data exposure. Share findings with teammates.

TaskCreate: "Challenge review findings" (T3) — depends on T1, T2
  description: |
    Wait for code-reviewer and security-auditor to complete.
    Verify their findings against actual code. Use SendMessage to challenge specific agents.
    Look for issues both missed. Produce Quality Review Gates report.

[PARALLEL - Single message with multiple Task calls]
Task tool: name: "review-code", subagent_type: "code-reviewer", team_name: "local-review-{branch}"
Task tool: name: "review-security", subagent_type: "security-auditor", team_name: "local-review-{branch}"
Task tool: name: "review-skeptic", subagent_type: "quality-guard", team_name: "local-review-{branch}"
```

Assign tasks. Skeptic challenges via SendMessage after T1 and T2 complete. Agents resolve gates. Collect results and TeamDelete.

---

### 5. Combine and Format Results

Merge agent outputs into a unified review:

```markdown
# Local Review: {current_branch}

**Branch**: {current_branch} → {base_branch}
**Commits**: {commit_count}
**Files Changed**: {file_count} (+{additions} -{deletions})

---

## 📊 Overview

[2-3 sentence summary of what this branch does based on commits and diff]

---

## ✅ Strengths

- [Positive aspects identified by agents]

---

## ⚠️ Issues & Concerns

### 🔴 Critical (Must Fix Before PR)

[Critical issues from both agents - security vulnerabilities, major bugs]

### 🟡 Important (Should Fix)

[Important issues - code quality, maintainability]

### 🔵 Minor (Consider)

[Suggestions and minor improvements]

---

## 🔒 Security Analysis

[Security findings from security-auditor agent]

---

## 🧪 Test Coverage

[Test coverage analysis from code-reviewer agent]

---

## 📝 Recommendations

1. [Prioritized action items]
2. [Most critical first]

---

## 💭 Overall Assessment

**Verdict**: [Ready for PR / Needs fixes first / Needs major rework]

[Final summary of branch quality and readiness]
```

---

### 6. Offer Next Steps

Based on the review verdict, use AskUserQuestion:

#### If "Ready for PR" (no critical or important issues):
- "Review complete — your branch looks good. What would you like to do?"
- Options:
  - **Create PR now** — Create pull request on GitHub
  - **Done** — Just wanted the review, I'll handle the rest

#### If "Needs fixes first" (has important issues, no critical):
- "Review found issues that should be addressed. What would you like to do?"
- Options:
  - **Create PR anyway** — I'll fix in follow-up commits
  - **Fix issues first** — I'll address the feedback and re-run
  - **Done** — Just wanted the review

#### If "Needs major rework" (has critical issues):
- "Review found critical issues that should be fixed before creating a PR."
- Options:
  - **Fix issues first** — I'll address the critical feedback
  - **Create PR anyway** — I accept the risks
  - **Done** — Just wanted the review

---

### 7. Create PR (if selected)

If user chose to create a PR:

**7.1 Confirm target branch:**
Use AskUserQuestion:
- "Which branch should this PR target?"
- Options: {base_branch} (auto-detected) / other common branches

**7.2 Generate PR title and body from the review:**

The PR title should be derived from the branch commits — concise, under 70 characters.

The PR body should include:
- Summary (from the review overview)
- Key changes (from diff analysis)
- Review notes (any deferred issues from the local review)

**7.3 Create the PR:**

**Use Task tool with `subagent_type: "git-operator"`:**

```
Prompt: Push branch {current_branch} to origin (with -u flag if not already tracking), then create a pull request targeting {target_branch}.

PR title: {title}
PR body:
{body}
```

**7.4 Show the PR URL** and confirm success.

---

## Error Handling

- **Not a git repository**: Display message, exit
- **No commits on branch**: Show message, suggest making commits first
- **Base branch doesn't exist**: Show available branches, ask user to pick
- **Agent timeout**: Show partial results with warning
- **Push fails**: Show error, suggest manual push

---

## Important Notes

- **Parallel agents**: Run code-reviewer and security-auditor simultaneously, then quality-guard validates
- **Team mode**: When `$REVIEW_EXEC_MODE` = `"team"`, agents cross-pollinate findings via SendMessage
- **Local-first**: Everything runs on local git data, no GitHub dependency until PR creation
- **Honest verdicts**: Don't sugarcoat — if there are critical issues, say so clearly
- **Actionable output**: Every issue should tell the developer what to fix and where
- **PR creation is optional**: The primary value is the review itself
