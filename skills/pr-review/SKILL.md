---
name: pr-review
model: claude-sonnet-5
category: code-quality
userInvocable: true
description: Review a pull request (or local branch with --local) with thorough analysis, severity levels, and actionable feedback
argument-hint: "[--local [base-branch]] | [--interactive] [pr-number]"
allowed-tools: "Read, Write, Glob, Grep, Bash(source:*), Bash(echo:*), Bash(cat:*), Bash(bash:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr review:*), Bash(gh pr create:*), Bash(gh api:*), Bash(gh repo view:*), Bash(git diff:*), Bash(git log:*), Bash(git branch:*), Bash(git merge-base:*), Bash(git rev-parse:*), Bash(git status:*), Bash(git push:*), Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage"
---

# Review Pull Request Command

## Context

Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repository)"`

Arguments (if provided): $ARGUMENTS

## Configuration

```bash
# Source resolve-config: marketplace installs get ${CLAUDE_PLUGIN_ROOT} substituted
# inline before bash runs; legacy local copies fall back to ~/.claude. If neither
# path resolves, fail loudly rather than letting resolve_artifact be undefined.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
  exit 1
fi
PR_REVIEW_EXEC_MODE=$(resolve_exec_mode pr_review team)
```

Use `$PR_REVIEW_EXEC_MODE` to determine team vs sub-agent behavior in Step 4.

This command performs a thorough code review by orchestrating specialized agents. It supports two sources for the diff:

**Modes:**
- **Remote PR mode** (default): Review an existing GitHub PR. Generates the review locally; with `--interactive`, can post inline comments back to GitHub.
- **Local branch mode** (`--local`): Pre-flight review of the current branch vs a base branch, before any PR exists. After review, optionally creates the PR.

`--local` and `--interactive` are mutually exclusive.

---

### 1. Parse Arguments

**Extract from $ARGUMENTS:**
- `--local` flag: switch to local branch mode. May be followed by an optional base branch name.
- `--interactive` flag: enable interactive posting to GitHub (remote mode only).
- PR number: numeric PR identifier (remote mode).

**Examples:**
- `/pr-review 123` → review PR 123, output locally.
- `/pr-review --interactive 123` → review PR 123, then optionally post inline comments.
- `/pr-review` → prompt user to select PR.
- `/pr-review --local` → review current branch vs auto-detected base.
- `/pr-review --local main` → review current branch vs `main`.

**Validation:**
- If both `--local` and `--interactive` present, stop: "`--local` and `--interactive` are mutually exclusive — `--interactive` posts to a remote PR; `--local` runs before one exists."
- If `--local` and a numeric PR number both present, stop with the same conflict.

If `--local` is set, jump to **Step 2L**. Otherwise continue with **Step 2R**.

---

### 2R. Detect Repository (remote mode)

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
```

**Use `--repo $REPO` on ALL subsequent `gh` commands.** This prevents cross-repo mistakes when the working directory changes or when reviewing PRs across multiple repositories. PR numbers are not globally unique — the same number can exist in different repos — so omitting `--repo` can silently target the wrong PR.

If no PR number was provided, fetch the list of open PRs and use AskUserQuestion to let the user pick:

```bash
gh pr list --repo $REPO --json number,title,author,headRefName,updatedAt --limit 20
```

---

### 3R. Fetch PR Details (remote mode)

```bash
gh pr view {PR_NUMBER} --repo $REPO --json title,author,body,baseRefName,headRefName,additions,deletions,changedFiles,commits,labels
gh pr diff {PR_NUMBER} --repo $REPO
gh pr view {PR_NUMBER} --repo $REPO --json files --jq '.files[].path'
```

Skip Step 2L/3L and proceed to **Step 4**.

---

### 2L. Pre-flight: Verify Git Repository (local mode)

```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```

**If non-zero or empty** (CWD is not a git repository — e.g., a monorepo root that only contains service repos as subdirectories), stop immediately with:

```
✗ Not in a git repository

/pr-review --local must be run from inside a git repository so it can diff
the current branch against its base branch.

If you're in a monorepo root with service repos as subdirectories,
cd into a specific service repo first:

    cd <service-name>
    /pr-review --local
```

Do NOT proceed to any other step.

**Validate state:**
```bash
git status --short
```

If there are uncommitted changes, use AskUserQuestion:
- "You have uncommitted changes. How would you like to proceed?"
- Options: Stash and continue / Review with uncommitted changes included / Cancel

**Check current branch is not main/master:** If on `main`, `master`, or `develop`, stop: "You're on a base branch. Switch to a feature branch first."

**Determine base branch:**
- If the user passed a base branch after `--local`, use it directly.
- Otherwise auto-detect by trying in order:
  1. Upstream tracking branch: `git rev-parse --abbrev-ref @{upstream} 2>/dev/null`
  2. Common base branches: `main`, `master`, `develop`
  3. If multiple exist, use AskUserQuestion to let the user pick.

**Validate the base branch exists:**
```bash
git rev-parse --verify {base_branch} 2>/dev/null
```

If it doesn't exist, show available branches and ask the user to pick.

---

### 3L. Gather Diff and Commit History (local mode)

```bash
MERGE_BASE=$(git merge-base {base_branch} HEAD)
git diff {base_branch}...HEAD
git diff {base_branch}...HEAD --stat
git log {base_branch}..HEAD --oneline --no-decorate
git log {base_branch}..HEAD --format="%h %s%n%b" --no-decorate
```

**If no diff exists:** Stop with: "No changes found between current branch and {base_branch}. Nothing to review."

---

### 4. Run Review Agents

**Execution mode**: Determined by `$PR_REVIEW_EXEC_MODE`.

Delegate the review to specialized agents with cross-validation via quality-guard. The prompts below use `{full_diff}` and `{file_list}`/`{commit_log}` from whichever path (remote or local) ran above.

#### Architecture review gate

`architect` validates finished code against the codebase's established architecture and patterns — but it's only worth the cost when the diff actually touches structure. Decide `INCLUDE_ARCHITECT` (true/false) by inspecting the diff and file list:

**Include `architect` when the diff does any of:**
- Adds or moves modules/packages, or changes directory/layer boundaries
- Touches shared, core, or cross-cutting services consumed by multiple callers
- Introduces a new dependency direction, DI wiring, or integration seam
- Establishes a new pattern (new base class, abstraction, framework convention) or appears to deviate from an existing one
- Changes public interfaces/contracts between components

**Skip `architect` when the diff is** localized bug fixes, copy/string/config tweaks, test-only changes, dependency bumps, or edits contained within a single existing module that follow its established pattern.

When in doubt on a non-trivial diff, include it. State the gate decision and the reason in one line before dispatching (e.g. `Architecture review: INCLUDED — adds a new shared HttpClient consumed across services`).

**If `$PR_REVIEW_EXEC_MODE` = `"subagent"`:**

#### Step 1: Parallel review

**Execute in a single message with multiple Task tool calls.** Run Task 1, Task 2, and (when `INCLUDE_ARCHITECT`) Task 1b together.

**Task 1 — Use Task tool with `subagent_type: "code-reviewer"`:**

```
Prompt: Review this {pr_or_branch} diff for code quality issues.

{remote: PR: #{number} - {title}, Branch: {head} → {base}}
{local:  Branch: {current_branch} → {base_branch}, Commits: {commit_count}, Commit history: {commit_log}}
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
Prompt: Review this {pr_or_branch} diff for security vulnerabilities.

{remote: PR: #{number} - {title}}
{local:  Branch: {current_branch} → {base_branch}}
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

**Task 1b (only if `INCLUDE_ARCHITECT`) — Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Validate this {pr_or_branch} diff against the codebase's established architecture and patterns. You are reviewing finished code, not a plan — assess whether what was built drifted from the intended design.

{remote: PR: #{number} - {title}, Branch: {head} → {base}}
{local:  Branch: {current_branch} → {base_branch}}
Files changed: {file_list}

Focus on:
- Architecture/layer compliance — does the change respect module boundaries and dependency direction?
- SOLID violations introduced by the diff
- Design-pattern consistency — does new code follow established patterns, or invent a divergent one?
- Naming and structural conventions versus the surrounding codebase
- Abstractions that are missing, leaky, or premature

Report only design-level findings with file/line references. Do not duplicate correctness or security review (those run separately).

Diff:
{full_diff}
```

#### Step 2: Skeptic challenge

**Task 3 — Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Independently review this diff, THEN reconcile against the review findings (Level 2 — Implementation Validation). Read the diff and trace the key code paths yourself first, forming your own view of where it breaks, before reading the findings below — the issues you add come from your own pass, not from re-litigating their list.

{remote: PR: #{number} - {title}}
{local:  Branch: {current_branch} → {base_branch}}
Full diff: {full_diff}
Code-reviewer findings: {code_reviewer_output}
Security-auditor findings: {security_auditor_output}
{if INCLUDE_ARCHITECT: Architect findings: {architect_output}}

In this order:
1. Independent pass FIRST: trace key code paths yourself and surface what both reviewers missed — this is your primary value.
2. Then reconcile their findings: are the CRITICAL findings real? Check actual file paths and line numbers. Any over- or under-stated?
3. Cross-reference: do findings contradict each other (e.g. architect's preferred design vs a correctness/security constraint)?
4. Any issues falling between the reviewers' scopes?

This is the terminal review before PR/merge — report all severities (BLOCKING / IMPORTANT / ADVISORY); do not suppress medium/low findings to save space. There is no later pass to catch what you drop.

Produce a Quality Review Gates report.
```

---

**If `$PR_REVIEW_EXEC_MODE` = `"team"` (default):**

Create a review team for real-time cross-pollination. Use `team_name="pr-review-{PR_NUMBER}"` in remote mode or `team_name="local-review-{branch}"` in local mode.

```
TeamCreate(team_name=<see above>)

TaskCreate: "Review code quality" (T1)
  description: |
    {Diff context}. Focus on logic, performance, code quality.
    Share findings with teammates.

TaskCreate: "Review security" (T2)
  description: |
    {Diff context}. Focus on injection, auth, data exposure.
    Share findings with teammates.

TaskCreate (only if INCLUDE_ARCHITECT): "Review architecture" (T2b)
  description: |
    {Diff context}. Validate finished code against established architecture and
    patterns — boundaries, dependency direction, SOLID, design-pattern consistency.
    Design-level findings only. Share findings with teammates.

TaskCreate: "Challenge review findings" (T3) — depends on T1, T2{if INCLUDE_ARCHITECT: , T2b}
  description: |
    Wait for code-reviewer, security-auditor{if INCLUDE_ARCHITECT: , and architect}.
    Review the diff independently FIRST — trace key code paths yourself and surface what
    the reviewers missed (your primary value) — then reconcile their findings against the
    actual code. Use SendMessage to challenge specific agents.
    Terminal review before PR/merge — report all severities (BLOCKING/IMPORTANT/ADVISORY);
    do not suppress medium/low findings. Produce Quality Review Gates report.

[PARALLEL - Single message with multiple Task calls]
Task tool: name: "pr-code", subagent_type: "code-reviewer", team_name: <see above>
Task tool: name: "pr-security", subagent_type: "security-auditor", team_name: <see above>
[only if INCLUDE_ARCHITECT] Task tool: name: "pr-architect", subagent_type: "architect", team_name: <see above>
Task tool: name: "pr-skeptic", subagent_type: "quality-guard", team_name: <see above>
```

Assign tasks. Skeptic challenges via SendMessage after T1, T2{if INCLUDE_ARCHITECT: , and T2b} complete. Agents resolve gates. Collect results and TeamDelete.

---

### 5. Combine and Format Results

Merge agent outputs into a unified review. Header varies by mode:

**Remote mode header:**
```markdown
# Pull Request Review: {title}

**PR**: #{number} by @{author}
**Branch**: {head} → {base}
**Files Changed**: {count} (+{additions} -{deletions})
```

**Local mode header:**
```markdown
# Local Review: {current_branch}

**Branch**: {current_branch} → {base_branch}
**Commits**: {commit_count}
**Files Changed**: {file_count} (+{additions} -{deletions})
```

**Body (both modes):**
```markdown
---

## 📊 Overview

[2-3 sentence summary]

---

## ✅ Strengths

- [Positive aspects identified by agents]

---

## ⚠️ Issues & Concerns

### 🔴 Critical (Must Fix{local: " Before PR"})

[Critical issues from both agents - security vulnerabilities, major bugs]

### 🟡 Important (Should Fix)

[Important issues - code quality, maintainability]

### 🔵 Minor (Consider)

[Suggestions and minor improvements]

---

## 🔒 Security Analysis

[Security findings from security-auditor agent]

---

## 🏛️ Architecture {only if INCLUDE_ARCHITECT}

[Design-level findings from architect agent — boundary, pattern, and SOLID drift. Omit this section entirely when the architecture gate was skipped.]

---

## 🧪 Test Coverage

[Test coverage analysis from code-reviewer agent]

---

## 📝 Recommendations

1. [Prioritized action items]
2. [Most critical first]

---

## 💭 Overall Assessment

**{remote: Recommendation: Approve / Request Changes / Needs Discussion}**
**{local:  Verdict: Ready for PR / Needs fixes first / Needs major rework}**

[Final summary]
```

---

### 6R. Interactive Mode — Post to GitHub (remote mode, `--interactive` only)

#### 6R.1 Ask About Posting Review

Use AskUserQuestion:
- "Would you like to post this review to GitHub with inline comments?"
- Options: Yes (as pending review) / No

**If No:** End command.

#### 6R.2 Select Severity Level

Use AskUserQuestion:
- "Which severity levels to include?"
- Options: Critical only / Critical + Important / All issues

#### 6R.3 Confirm Comments

For each issue matching the selected severity, use AskUserQuestion:
- Show issue details (file, line, description)
- Options: Include / Skip / Skip all remaining

#### 6R.4 Post Inline Review via Reviews API

Use the GitHub Pull Request Reviews API to post inline comments anchored to specific diff lines. **Do NOT use `gh pr comment`** — that creates a general top-level comment, not inline review comments.

**Build one JSON payload file with every field** — `body`, `comments`, and (if submitting outright) `event`. When `--input` is passed, `gh api` sends that file as the entire request body and silently shoves any co-occurring `-f` flags into the query string instead — so a split `-f body=... --input comments.json` call drops the summary body without error. Never combine `-f` with `--input` on this call.

```bash
cat > /tmp/review-comments.json <<JSON
{
  "body": "## PR Review Summary\n\n{overall_summary}",
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
JSON

gh api "repos/$REPO/pulls/{PR_NUMBER}/reviews" \
  --method POST \
  --input /tmp/review-comments.json
```

**Important considerations:**
- The `line` field refers to the line number in the **new version** of the file (right side of the diff)
- Use `side: "RIGHT"` (default) for lines in the new version, `side: "LEFT"` for deleted lines
- **Omit the `event` field entirely.** The Reviews API's `event` enum is `APPROVE` / `REQUEST_CHANGES` / `COMMENT` — there is no `"PENDING"` value, and passing one is rejected. Omitting `event` is what leaves the review unsubmitted (pending) so the reviewer can edit comments before submitting — that's the actual mechanism, not a literal `PENDING` value.
- `{overall_summary}` may itself contain newlines/quotes — escape it into valid JSON (`\n` for line breaks, `\"` for embedded quotes) before writing the heredoc, or build the file with `jq -n --arg body "$overall_summary" '...'` instead of a raw heredoc if the summary has non-trivial content.

#### 6R.5 Verify and Open Browser

```bash
gh pr view {PR_NUMBER} --repo $REPO --json url --jq '.url'
gh pr view {PR_NUMBER} --repo $REPO --web
```

Print summary:
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
```

---

### 6L. Offer Next Steps (local mode)

Based on the verdict, use AskUserQuestion:

**If "Ready for PR" (no critical or important issues):**
- "Review complete — your branch looks good. What would you like to do?"
- Options:
  - **Create PR now** — Create pull request on GitHub
  - **Done** — Just wanted the review

**If "Needs fixes first" (has important issues, no critical):**
- "Review found issues that should be addressed. What would you like to do?"
- Options:
  - **Create PR anyway** — I'll fix in follow-up commits
  - **Fix issues first** — I'll address the feedback and re-run
  - **Done** — Just wanted the review

**If "Needs major rework" (has critical issues):**
- "Review found critical issues that should be fixed before creating a PR."
- Options:
  - **Fix issues first** — I'll address the critical feedback
  - **Create PR anyway** — I accept the risks
  - **Done** — Just wanted the review

---

### 7L. Create PR (local mode, if selected)

**7L.1 Confirm target branch:** Use AskUserQuestion — default to `{base_branch}`, offer common alternatives.

**7L.2 Generate PR title and body** from the review (title from branch commits, under 70 chars; body includes summary, key changes, deferred issues from the local review).

**7L.3 Create the PR inline.** The hook requires a security-auditor confirmation before push; the local review already ran `security-auditor` in Step 4, so record the confirmation and push:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
git push -u origin {current_branch}

gh pr create \
  --base {target_branch} \
  --head {current_branch} \
  --title "{title}" \
  --body "$(cat <<'EOF'
{body}
EOF
)"
```

**7L.4 Show the PR URL** and confirm success.

---

## Error Handling

- **No PRs available** (remote): Display message, exit gracefully.
- **Invalid PR number** (remote): Show available PRs.
- **GitHub CLI not authenticated**: Show `gh auth login` instructions.
- **Not a git repository** (local): Display message, exit.
- **No commits on branch** (local): Suggest making commits first.
- **Base branch doesn't exist** (local): Show available branches, ask user to pick.
- **Agent timeout**: Show partial results with warning.
- **Push fails** (local PR creation): Show error, suggest manual push.

---

## Important Notes

- **Always use `--repo`** in remote mode: every `gh` command MUST include `--repo $REPO` to prevent cross-repo mistakes. PR numbers are not unique across repos.
- **Inline comments, not general comments**: Interactive mode MUST use the Reviews API. Never use `gh pr comment` — it creates a top-level comment that is not anchored to code lines.
- **Parallel agents**: code-reviewer and security-auditor (plus `architect` when the architecture gate fires) run simultaneously, then quality-guard validates.
- **Architecture gate**: `architect` is the only agent here that runs conditionally — include it for structural/boundary/pattern changes, skip it for localized fixes, config, or test-only diffs. State the gate decision before dispatching.
- **Team mode**: When `$PR_REVIEW_EXEC_MODE` = `"team"`, agents cross-pollinate findings via SendMessage.
- **Local review is local-only**: No GitHub interaction in `--local` mode unless the user explicitly opts in to PR creation in Step 7L.
- **Pending reviews**: Interactive mode creates a pending review (not submitted). User decides when to submit and with what verdict.
- **Honest verdicts**: Don't sugarcoat — if there are critical issues, say so clearly.
- **Verify after posting**: Always confirm the review URL matches the intended repository.
