---
name: pr-review
model: sonnet
category: code-quality
userInvocable: true
description: Review a pull request with thorough analysis, severity levels, and actionable feedback
argument-hint: [--interactive] [pr-number]
allowed-tools: "Read, Write, Glob, Grep, Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr review:*), Bash(gh api:*), Bash(gh repo view:*), Bash(git diff:*), Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage"
---

# Review Pull Request Command

## Context

Available PRs: !`gh pr list --json number,title,author,headRefName,updatedAt --limit 20`

PR argument (if provided): $ARGUMENTS

## Configuration

```bash
# BEGIN_SHARED: resolve-config
CONFIG=""
_d="$PWD"
while [[ "$_d" != "/" ]]; do
  if [[ -f "$_d/.claude/configuration.yml" ]]; then
    CONFIG="$_d/.claude/configuration.yml"
    break
  fi
  _d="$(dirname "$_d")"
done
WORKSPACE_ROOT=""
if [[ -n "$CONFIG" ]]; then
  WORKSPACE_ROOT="$(cd "$(dirname "$CONFIG")/.." && pwd)"
fi
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$PWD}"
WORKSPACE_MODE="single"
DISCOVERED_SERVICES=()
if git -C "$WORKSPACE_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
  WORKSPACE_MODE="single"
else
  for dir in "${WORKSPACE_ROOT}"/*/; do
    if [[ -d "${dir}.git" ]]; then
      DISCOVERED_SERVICES+=("$(basename "$dir")")
    fi
  done
  [[ ${#DISCOVERED_SERVICES[@]} -gt 0 ]] && WORKSPACE_MODE="multi"
fi
if [[ -f "$CONFIG" ]]; then
  _svc_count=$(yq -r '.workspace.services | length // 0' "$CONFIG" 2>/dev/null)
  if [[ "$_svc_count" -gt 0 ]]; then
    WORKSPACE_MODE="multi"
    DISCOVERED_SERVICES=()
  fi
fi
resolve_exec_mode() {
  local phase="$1"
  local default="${2:-team}"
  if [[ -f "$CONFIG" ]]; then
    local _raw=$(yq -r '.execution_mode' "$CONFIG" 2>/dev/null)
    if [[ "$_raw" == "subagent" || "$_raw" == "team" ]]; then
      echo "$_raw"
    elif [[ "$_raw" != "null" && -n "$_raw" ]]; then
      yq -r ".execution_mode.overrides.${phase} // .execution_mode.default // \"${default}\"" "$CONFIG"
    else
      echo "$default"
    fi
  else
    echo "$default"
  fi
}
resolve_worktree_enabled() {
  if [[ -f "$CONFIG" ]]; then
    yq -r '.worktree.enabled // "false"' "$CONFIG"
  else
    echo "false"
  fi
}
# END_SHARED: resolve-config
PR_REVIEW_EXEC_MODE=$(resolve_exec_mode pr_review team)
```

Use `$PR_REVIEW_EXEC_MODE` to determine team vs sub-agent behavior in Step 4.

This command performs a thorough code review by orchestrating specialized agents.

**Modes:**
- **Local-only mode** (default): Generates review locally, does NOT post to GitHub
- **Interactive mode** (`--interactive`): After review, allows posting comments to GitHub

---

### 1. Parse Arguments

**Extract from $ARGUMENTS:**
- `--interactive` flag: Enable interactive mode
- PR number: Numeric PR identifier

**Examples:**
- `/pr-review 123` → PR 123, local mode
- `/pr-review --interactive 123` → PR 123, interactive mode
- `/pr-review` → Prompt user to select PR

**If no PR number:** Use AskUserQuestion to let user select from available PRs.

---

### 2. Detect Repository

Determine the GitHub repository from the current git remote:

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
```

**Use `--repo $REPO` on ALL subsequent `gh` commands.** This prevents cross-repo mistakes when the working directory changes or when reviewing PRs across multiple repositories. PR numbers are not globally unique — the same number can exist in different repos — so omitting `--repo` can silently target the wrong PR.

---

### 3. Fetch PR Details

```bash
# Get PR metadata
gh pr view {PR_NUMBER} --repo $REPO --json title,author,body,baseRefName,headRefName,additions,deletions,changedFiles,commits,labels

# Get the full diff
gh pr diff {PR_NUMBER} --repo $REPO

# Get list of changed files
gh pr view {PR_NUMBER} --repo $REPO --json files --jq '.files[].path'
```

---

### 4. Run Review Agents

**Execution mode**: Determined by `$PR_REVIEW_EXEC_MODE`.

Delegate the review to specialized agents with cross-validation via quality-guard.

**If `$PR_REVIEW_EXEC_MODE` = `"subagent"`:**

**Run reviewers in parallel, then skeptic validates:**

#### Step 1: Parallel review

**Execute in a single message with multiple Task tool calls:**

**Task 1 — Use Task tool with `subagent_type: "code-reviewer"`:**

```
Prompt: Review this pull request diff for code quality issues.

PR: #{number} - {title}
Branch: {head} → {base}
Files changed: {count}

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
Prompt: Review this pull request diff for security vulnerabilities.

PR: #{number} - {title}
Files changed: {file_list}

Focus on:
- Injection vulnerabilities (SQL, XSS, command)
- Authentication/authorization issues
- Data exposure risks
- Input validation gaps
- Sensitive data handling

Diff:
{full_diff}
```

#### Step 2: Skeptic challenge

**Task 3 — Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Challenge the PR review findings (Level 2 — Implementation Validation).

PR: #{number} - {title}
Full diff: {full_diff}
Code-reviewer findings: {code_reviewer_output}
Security-auditor findings: {security_auditor_output}

Verify:
1. Are the CRITICAL findings real? Check actual file paths and line numbers.
2. Did both reviewers miss anything? Trace through key code paths.
3. Cross-reference: do findings contradict each other?
4. Any issues falling between the two reviewers' scopes?

Produce a Quality Review Gates report.
```

---

**If `$PR_REVIEW_EXEC_MODE` = `"team"` (default):**

Create a review team for real-time cross-pollination:

```
TeamCreate(team_name="pr-review-{PR_NUMBER}")

TaskCreate: "Review code quality" (T1)
  description: |
    PR #{number}: {title}. Diff: {full_diff}.
    Focus on logic, performance, code quality. Share findings with teammates.

TaskCreate: "Review security" (T2)
  description: |
    PR #{number}: {title}. Diff: {full_diff}.
    Focus on injection, auth, data exposure. Share findings with teammates.

TaskCreate: "Challenge review findings" (T3) — depends on T1, T2
  description: |
    Wait for code-reviewer and security-auditor. Verify findings against actual code.
    Use SendMessage to challenge specific agents. Produce Quality Review Gates report.

[PARALLEL - Single message with multiple Task calls]
Task tool: name: "pr-code", subagent_type: "code-reviewer", team_name: "pr-review-{PR_NUMBER}"
Task tool: name: "pr-security", subagent_type: "security-auditor", team_name: "pr-review-{PR_NUMBER}"
Task tool: name: "pr-skeptic", subagent_type: "quality-guard", team_name: "pr-review-{PR_NUMBER}"
```

Assign tasks. Skeptic challenges via SendMessage after T1 and T2 complete. Agents resolve gates. Collect results and TeamDelete.

---

### 5. Combine and Format Results

Merge agent outputs into a unified review:

```markdown
# Pull Request Review: {title}

**PR**: #{number} by @{author}
**Branch**: {head} → {base}
**Files Changed**: {count} (+{additions} -{deletions})

---

## 📊 Overview

[2-3 sentence summary of what this PR does]

---

## ✅ Strengths

- [Positive aspects identified by agents]

---

## ⚠️ Issues & Concerns

### 🔴 Critical (Must Fix)

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

**Recommendation**: [Approve / Request Changes / Needs Discussion]

[Final summary of PR quality and readiness]
```

---

### 6. Interactive Mode (if --interactive flag)

**Only if `--interactive` was specified:**

#### 6.1 Ask About Posting Review

Use AskUserQuestion:
- "Would you like to post this review to GitHub with inline comments?"
- Options: Yes (as pending review) / No

**If No:** End command

#### 6.2 Select Severity Level

Use AskUserQuestion:
- "Which severity levels to include?"
- Options: Critical only / Critical + Important / All issues

#### 6.3 Confirm Comments

For each issue matching the selected severity, use AskUserQuestion:
- Show issue details (file, line, description)
- Options: Include / Skip / Skip all remaining

#### 6.4 Post Inline Review via Reviews API

Use the GitHub Pull Request Reviews API to post inline comments anchored to specific diff lines. **Do NOT use `gh pr comment`** — that creates a general top-level comment, not inline review comments.

```bash
# Build the review payload with inline comments
# Each comment must have: path (file), line (diff line number), body (comment text)
gh api "repos/$REPO/pulls/{PR_NUMBER}/reviews" \
  --method POST \
  -f event="PENDING" \
  -f body="## PR Review Summary

{overall_summary}" \
  --input /tmp/review-comments.json
```

Where `/tmp/review-comments.json` contains the inline comments array:

```json
{
  "comments": [
    {
      "path": "src/Services/FooClient.php",
      "line": 42,
      "body": "🔴 **Critical:** Error detection changed from checking body status to HTTP status only. This silently drops application-level errors."
    },
    {
      "path": "src/Controller/BarController.php",
      "line": 15,
      "body": "🟡 **Important:** Missing input validation on user-supplied parameter."
    }
  ]
}
```

**Important considerations:**
- The `line` field refers to the line number in the **new version** of the file (right side of the diff)
- Use `side: "RIGHT"` (default) for lines in the new version, `side: "LEFT"` for deleted lines
- The `event` should be `"PENDING"` so the reviewer can edit comments before submitting

#### 6.5 Verify and Open Browser

After posting, verify the review was created on the correct repository:

```bash
# Verify the review URL matches the intended repo
gh pr view {PR_NUMBER} --repo $REPO --json url --jq '.url'
```

```
─────────────────────────────────
Interactive Review Summary
─────────────────────────────────

✓ {count} inline comments posted as pending review
⊘ {count} issues skipped
📍 Repository: {REPO}

NEXT STEPS:
1. Review pending comments in GitHub UI (Files changed tab)
2. Edit or delete individual comments as needed
3. Submit as "Request Changes", "Approve", or "Comment"

Opening PR in browser...
```

```bash
gh pr view {PR_NUMBER} --repo $REPO --web
```

---

## Error Handling

- **No PRs available**: Display message, exit gracefully
- **Invalid PR number**: Show available PRs
- **GitHub CLI not authenticated**: Show `gh auth login` instructions
- **Agent timeout**: Show partial results with warning

---

## Important Notes

- **Always use `--repo`**: Every `gh` command MUST include `--repo $REPO` to prevent cross-repo mistakes. PR numbers are not unique across repos — omitting `--repo` can silently target the wrong PR.
- **Inline comments, not general comments**: Interactive mode MUST use the Reviews API (`gh api repos/.../pulls/.../reviews`) to post inline comments. Never use `gh pr comment` — it creates a top-level comment that is not anchored to code lines.
- **Parallel agents**: Run code-reviewer and security-auditor simultaneously, then quality-guard validates
- **Team mode**: When `$PR_REVIEW_EXEC_MODE` = `"team"`, agents cross-pollinate findings via SendMessage
- **Local by default**: Never post to GitHub unless `--interactive` mode
- **Pending reviews**: Interactive mode creates pending review (not submitted)
- **User control**: User decides when to submit and with what verdict
- **Verify after posting**: Always confirm the review URL matches the intended repository
