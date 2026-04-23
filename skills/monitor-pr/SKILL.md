---
name: monitor-pr
model: claude-sonnet-4-6
category: code-quality
userInvocable: true
description: Monitor an open pull request — watch CI, investigate and fix failing workflows, address new review comments, and loop until the PR is approved, merged, or the iteration limit is reached.
argument-hint: "[pr-number]"
allowed-tools: "Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion"
---

# Monitor PR

Arguments: $ARGUMENTS

Autonomously monitor an open pull request: watch CI workflows to completion, investigate and fix any failures, address new review comments, and repeat until the PR reaches a terminal state (approved with all checks green, merged, closed, or the iteration cap is hit).

This skill complements `/pr-review` (one-shot review of an existing PR, or `--local` for a pre-flight review before opening one). Use `monitor-pr` **after** a PR is open when you want the PR shepherded through CI and review without constant manual polling.

## Non-Goals

- **This skill does NOT merge the PR.** Final merge is an explicit user decision.
- **This skill does NOT rewrite history.** All fixes are added as follow-up commits.
- **This skill does NOT bypass reviewers.** Reviewer approval is required for terminal success.
- **This skill does NOT invent review comments.** It addresses only comments posted by others.

---

## Step 1: Select PR

Parse `$ARGUMENTS`:

- **If a number is provided** (e.g., `130`) — use it directly
- **Otherwise** — detect the PR for the current branch

### Detect PR

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# Try to find a PR for the current branch
PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null || echo "")
```

If `PR_NUMBER` is empty, list the user's open PRs and use `AskUserQuestion` to pick:

```bash
gh pr list --repo "$REPO" --author @me --state open --limit 10 \
  --json number,title,headRefName \
  --jq '.[] | "#\(.number) \(.title) [\(.headRefName)]"'
```

Show up to 4 as options. If more exist, note the user can type the number directly.

### Fetch PR metadata

```bash
gh pr view "$PR_NUMBER" --repo "$REPO" \
  --json number,title,state,isDraft,mergeable,headRefName,baseRefName,headRefOid
```

Store `BRANCH=$headRefName`, `HEAD_SHA=$headRefOid`, `BASE=$baseRefName`.

**Guardrails:**
- If `state != OPEN` → stop with `PR #{n} is already {state}. Nothing to monitor.`
- If `isDraft == true` → ask user via `AskUserQuestion` whether to proceed (default: stop).

Display summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Monitoring PR #{number}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Title:  {title}
Branch: {headRefName} → {baseRefName}
State:  {state} {if draft: "(DRAFT)"}
URL:    {html_url}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Step 2: Checkout PR Branch

Align the working tree with the PR using direct Bash. This is a read-heavy operation (fetch + checkout + pull with no divergent local history) where a `git-operator` subagent spin-up costs ~17k tokens for ~3 commands; the `GIT_AUTHORIZED=1` prefix satisfies the `git-mutation-guard.sh` hook and matches the exception pattern already used by the Haiku-tier release skills.

```bash
git fetch origin "$BRANCH"
GIT_AUTHORIZED=1 git checkout "$BRANCH"
GIT_AUTHORIZED=1 git pull --ff-only origin "$BRANCH"

# Confirm HEAD matches origin
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse "origin/$BRANCH")
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "HEAD ($LOCAL_SHA) != origin/$BRANCH ($REMOTE_SHA)"; exit 1; }
```

`--ff-only` prevents an implicit merge if local history has diverged — in that case surface the error to the user rather than attempting recovery here; monitor-pr assumes the PR branch is a clean mirror of origin. If fetch, checkout, or pull fails, stop and surface the error. All subsequent **mutations** (commits, pushes in Step 3.3) still delegate to `git-operator` per repo convention.

---

## Step 3: Monitor Loop

Initialize loop state:

- `MAX_ITERATIONS=10` — hard cap to prevent runaway loops
- `ITERATION=0`
- `PROCESSED_COMMENTS={}` — set of comment IDs already addressed
- `LAST_PROCESSED_SHA=""` — tracks the SHA we last acted on

**First-iteration bootstrap:** Treat all comments that already exist on the PR as "pre-existing." Use `AskUserQuestion` to confirm whether to address pre-existing unaddressed comments from reviewers (default: **Yes**). If the user says no, seed `PROCESSED_COMMENTS` with all existing comment IDs so only comments posted after this moment are acted on.

Enter the loop:

### 3.1 Refresh PR State

```bash
PR_STATE=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
  --json state,mergeable,reviewDecision,headRefOid \
  --jq '{state, mergeable, reviewDecision, head: .headRefOid}')
```

Update `HEAD_SHA` from `.head`.

**Terminal checks (exit loop if any match):**
- `state == MERGED` → success, jump to Step 4
- `state == CLOSED` → report and stop
- `reviewDecision == APPROVED` AND all workflow conclusions on `HEAD_SHA` are `success`/`skipped` AND no unaddressed comments → success, jump to Step 4

If no terminal match, continue.

### 3.2 Check CI Status

```bash
gh run list --repo "$REPO" --branch "$BRANCH" --limit 20 \
  --json databaseId,name,status,conclusion,headSha,event \
  --jq '[.[] | select(.headSha == "'"$HEAD_SHA"'") | {id: .databaseId, name, status, conclusion, event}]'
```

Filter to runs matching `HEAD_SHA`. Group by status:

- `in_progress` / `queued` / `waiting` → poll to completion (3.2a)
- `completed` with conclusion `success` / `skipped` → record as green
- `completed` with conclusion `failure` / `cancelled` / `timed_out` / `action_required` → investigate in 3.3

> **Why not `gh pr checks`?** That command returns exit code 8 whenever any
> check is pending OR failed — pending and failed are indistinguishable in
> the exit status, so it cannot be used for loop control. `gh run list` with
> explicit `status`/`conclusion` fields avoids the ambiguity.

### 3.2a Poll In-Progress Runs to Completion

**Do NOT use `gh run watch`.** It assumes a TTY, streams output with escape
sequences, and cannot be reliably captured or backgrounded. Use a bounded
polling loop instead:

```bash
POLL_INTERVAL=15           # seconds between polls
POLL_MAX=80                # 80 × 15s = 20 minutes hard cap per iteration
POLL_COUNT=0

while [ "$POLL_COUNT" -lt "$POLL_MAX" ]; do
  RUNS_JSON=$(gh run list --repo "$REPO" --branch "$BRANCH" --limit 20 \
    --json databaseId,name,status,conclusion,headSha \
    --jq '[.[] | select(.headSha == "'"$HEAD_SHA"'")]')

  PENDING=$(echo "$RUNS_JSON" \
    | jq '[.[] | select(.status == "in_progress" or .status == "queued" or .status == "waiting")] | length')

  if [ "$PENDING" -eq 0 ]; then
    break
  fi

  sleep "$POLL_INTERVAL"
  POLL_COUNT=$((POLL_COUNT + 1))
done
```

After the loop exits, re-classify all runs for `HEAD_SHA` by `conclusion`:

- `success` / `skipped` → green
- `failure` / `cancelled` / `timed_out` / `action_required` → fall through to 3.3
- Still pending after `POLL_MAX` → report `ci_timeout` and exit the monitor loop; the poll cap is a safety rail, not a failure signal

This pattern is synchronous, non-interactive, and bounded. It produces no
background processes, no TTY escape sequences, and no orphaned tasks.

### 3.3 Investigate and Fix Failed Runs

For each failed run, fetch the failure log:

```bash
gh run view {run_id} --repo "$REPO" --log-failed
```

**Diagnose before acting.** Classify the failure:

| Category | Fix approach |
|----------|--------------|
| Validation (`scripts/validate.sh`, schema checks) | Read the validator output, fix the specific rule violation, re-run the validator locally before pushing |
| Test failures | Read the test file and the source under test, fix the regression. Delegate to `test-fixer` agent via `Task` if the failure is non-obvious |
| Lint / style | Apply the specific formatter or lint fix the tool suggests |
| Build errors | Read the compile error, fix the specific symbol/type mismatch |
| Infrastructure (runner died, cancelled, network timeout) | Re-run the workflow, do NOT attempt a code fix: `gh run rerun {run_id} --repo "$REPO"` |
| Flaky (intermittent, no code change between passing/failing runs) | Re-run once. If it fails a second time, treat as real and investigate |

**Never blind-retry a failing code path.** If the root cause is unclear, use the `Explore` agent to understand the affected code before editing.

After applying a fix locally:

1. Re-run relevant local checks (e.g., `bash scripts/validate.sh`) before pushing
2. Commit + push inline. The hook runs credential scan on commit; push requires a security-auditor confirmation for the new HEAD, so record one after a clean audit:

```bash
git add <modified-files>
git commit -m "[SKILLS-{N}] fix(ci): {short description of the failure fixed}"
# Run security-auditor on the staged/committed changes, then:
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
git push
```

Use the **issue/ticket number this PR closes** as `{N}` (e.g., `[SKILLS-022]`) — per the repo's commit convention, the prefix is always the originating ticket, never the PR number. Pushing a new commit updates `HEAD_SHA`; the next loop iteration will pick it up.

### 3.4 Check for New Review Comments

Fetch PR comments (inline and review-level). **Filter out stale/outdated comments
before acting** — GitHub keeps historical comments on every commit a PR has ever
had, and acting on a comment whose code no longer exists produces ghost-fix
churn (the exact failure mode that motivated this skill).

```bash
# Inline review comments — keep raw commit_id and position fields so we can
# filter stale ones. Do NOT use `(.line // .original_line)` here: `line` is
# null precisely when the referenced code no longer exists in the diff, and
# falling back to original_line treats that as actionable.
gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
  --jq '[.[] | {id, path, line, original_line, position, original_position,
    author: .user.login, body, in_reply_to_id,
    created_at, commit_id, original_commit_id}]'

# Review-level comments (approve/request changes/comment)
gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
  --jq '[.[] | {id, state, author: .user.login, body,
    submitted_at, commit_id}]'
```

**Staleness filter** — drop any inline comment that matches any of:

1. `position == null` — GitHub nulls this field when the referenced line no
   longer exists in the current diff. This is the canonical "outdated" signal
   and the only reliable way to detect comments whose code has since been
   rewritten or deleted.
2. `author == $(gh api user --jq .login)` — never act on the skill's own
   replies or prior bot comments.

> **Do not use `commit_id != HEAD_SHA` as a staleness filter.** A reviewer may
> post a comment against commit A saying "this method has a race condition";
> a subsequent unrelated commit B does not resolve that concern. As long as
> `position` is non-null, the line still exists in the current diff and the
> feedback is still actionable regardless of which SHA it was pinned to.
> `commit_id` is useful for reporting and debugging, not for filtering.

Silently mark stale comments as processed (add their IDs to `PROCESSED_COMMENTS`)
so subsequent iterations do not re-examine them. Do **not** reply to stale
comments — the reviewer already knows the code moved.

**Actionable delta** — comments that:
- pass the staleness filter above, AND
- whose `id` is not in `PROCESSED_COMMENTS`, AND
- whose `author` is not the current `gh` user.

For each new comment:

| Comment type | Action |
|--------------|--------|
| Suggested change (contains `suggestion` block) | Read the file, apply the suggestion, commit via git-operator. Mark addressed. |
| Actionable request (e.g., "please rename X", "add a test for Y") | Read the referenced file, apply the change, commit via git-operator. Mark addressed. |
| Question | If the answer is unambiguous from code, reply via `gh pr comment $PR_NUMBER --repo "$REPO" --body "..."`. If ambiguous, skip and flag to the user at end-of-run. |
| Praise / LGTM / purely informational | Mark as processed without action. Do NOT reply. |
| Request that conflicts with existing code decisions | Skip, log to the end-of-run report, and flag as needing user judgment. |

**Every comment this skill acts on must be added to `PROCESSED_COMMENTS` by ID.** Track both inline-comment IDs and review IDs separately to avoid ID collisions.

**Do NOT resolve conversation threads** — resolution is a reviewer's prerogative. Leave the comment for the reviewer to mark resolved after inspecting the fix.

### 3.5 Decide Whether to Continue

At the end of the iteration:

- If any fix was pushed this iteration → increment `ITERATION`, skip the sleep, loop immediately
- If no fix was pushed and nothing was in-progress → sleep 10 seconds, then loop
- If `ITERATION >= MAX_ITERATIONS` → exit loop with `iteration_cap_hit` status
- If the PR reached a terminal state in 3.1 → exit loop with `success` status

**Safety rails:**
- Track failures by **workflow name** across pushed SHAs, not by run ID — each push creates new run IDs, so "same run ID fails twice" is unreachable. If the same workflow name fails on two consecutive pushed SHAs after a fix attempt, stop and report — the fix is not working and human judgment is required
- If a review comment body contains obvious secret-like patterns (API keys, tokens, passwords) that the reviewer has exposed, do NOT echo them in commits or replies; flag to the user

---

## Step 4: Final Report

Produce a structured summary regardless of exit reason:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Monitor PR #{number} — {status}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PR:             {REPO}#{PR_NUMBER}
Final state:    {state} ({reviewDecision})
HEAD SHA:       {HEAD_SHA}
Iterations:     {ITERATION} / {MAX_ITERATIONS}
Workflows:      {count green} / {count total}
Comments acted on: {count}
Comments skipped:  {count, with reasons}
Follow-up commits: {list of SHAs with short messages}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Status values:**
- `ready to merge` — approved, all CI green, no unaddressed comments
- `merged` — the PR was merged during monitoring (e.g., a reviewer merged it)
- `closed` — the PR was closed during monitoring
- `iteration_cap_hit` — max iterations reached, human attention needed
- `blocked_needs_human` — a comment requires user judgment the skill refused to guess at
- `ci_stuck` — the same workflow failed repeatedly after fix attempts
- `ci_timeout` — at least one workflow remained pending past the 3.2a poll cap (no failure signal, but the skill gave up waiting)

**If status is not `ready to merge` / `merged`**, list each unresolved item so the user can act.

---

## Examples

### Monitor the PR for the current branch
```
/monitor-pr
```

### Monitor a specific PR by number
```
/monitor-pr 130
```

### After `/implement` creates a PR
Invoke `/monitor-pr` to shepherd it through CI and review without manually polling `gh run list` and `gh pr view` yourself.

---

## Design Notes

- **Run this skill in the foreground.** The polling loop in 3.2a is synchronous
  by design. Do **not** background it with `sleep && ...` wrappers or detached
  shells — overlapping polls produce unreliable output capture, accumulate
  orphaned tasks, and defeat the staleness tracking in 3.4. If you need the
  conversation to stay responsive during long CI, let the skill run and read
  its final report when it completes; do not spawn parallel ad-hoc pollers.
- **Never use `gh pr checks` for loop control.** Exit code 8 is returned for
  both pending AND failed checks, so a still-running workflow is indistinguishable
  from a broken one. Always use `gh run list` with `status`/`conclusion` fields
  and filter by `headSha` to know what is actually green.
- **Never use `gh run watch` inside this skill.** It is interactive by design,
  assumes a TTY, and leaks escape sequences when its output is captured. The
  bounded polling loop in 3.2a supersedes it.
- **Always filter PR comments by `position`.** Raw `pulls/{n}/comments`
  returns every comment ever posted; only `position == null` reliably marks
  an outdated comment whose referenced line no longer exists in the diff.
  Acting on stale comments produces ghost-fix churn — the failure mode that
  originally motivated this skill. Do not use `commit_id` as the filter:
  a valid concern pinned to an older SHA remains actionable as long as the
  referenced line is still present.
- **One loop iteration ≠ one minute.** Iterations advance when state changes (CI finishes, comments arrive, a push lands). Between state changes the loop sleeps briefly (10s) and re-polls.
- **Iteration cap protects from runaway token spend.** 10 iterations is enough for most PRs; escalate to the user beyond that.
- **Mutating git operations that are visible to others (commit, push) delegate to `git-operator`.** This preserves the plugin's mandatory security-auditor / branch-protection checks before every push. Local-only alignment operations (fetch, checkout, `--ff-only` pull) in Step 2 run inline with `GIT_AUTHORIZED=1` to avoid the ~17k-token cost of a subagent spin-up for a trivial read-through operation.
- **No destructive actions.** The skill never force-pushes, never amends, never resets, never closes the PR.
- **Conservative comment handling.** When in doubt about a comment, the skill flags it for the user rather than guessing. Silent wrong fixes are worse than skipped comments.
