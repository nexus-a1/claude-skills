---
name: monitor-pr
model: claude-sonnet-5
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

**Loop state lives in a file, not shell variables.** Each step below (3.1
through 3.5) runs as its own Bash tool call, and shell variables do not
survive between separate Bash invocations — only the working directory
does. All loop-control state (iteration count, processed comment IDs,
last-processed SHA, poll-round budget) is persisted to one JSON file, read
at the start of each step and updated at the end:

```bash
STATE_FILE="/tmp/monitor-pr-${PR_NUMBER}-state.json"

if [ ! -f "$STATE_FILE" ]; then
  cat > "$STATE_FILE" <<'JSON'
{
  "iteration": 0,
  "max_iterations": 10,
  "processed_comments": [],
  "last_processed_sha": "",
  "poll_rounds_used": 0,
  "max_poll_rounds": 3,
  "idle_polls": 0,
  "max_idle_polls": 2
}
JSON
fi
```

- `max_iterations` (10) — hard cap on fix-attempt iterations; prevents a runaway loop.
- `processed_comments` — JSON array of comment IDs already addressed or explicitly skipped (see 3.4).
- `poll_rounds_used` / `max_poll_rounds` — bounds how many times 3.2a's polling block may be re-invoked for the current `HEAD_SHA` before giving up (see 3.2a).
- `idle_polls` / `max_idle_polls` — consecutive iterations where CI was already green and nothing else happened, so a PR that's just waiting on reviewer approval terminates instead of looping forever (see 3.5).

Read a field with `jq -r '.field' "$STATE_FILE"`. Write updates with a
read-modify-write — never by re-declaring the whole file from a shell
variable that may be stale from a prior call:

```bash
jq '.iteration += 1' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
```

**First-iteration bootstrap:** Treat all comments that already exist on the PR as "pre-existing." Use `AskUserQuestion` to confirm whether to address pre-existing unaddressed comments from reviewers (default: **Yes**). If the user says no, seed `processed_comments` in `$STATE_FILE` with all existing comment IDs so only comments posted after this moment are acted on.

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
polling loop instead.

**Token discipline:** each `gh run list --json` response is ~750 tokens.
Up to 80 polls per iteration × 10 iterations = ~600k tokens of polling JSON
alone if every response goes into the LLM's context. To prevent that,
**redirect each poll to a tmpfile and emit only a one-line summary to
stdout**. Re-read the tmpfile only when state changes (a run finishes or a
new run starts) or when you need detail to fall through to 3.3.

```bash
POLL_INTERVAL=15           # seconds between polls
POLL_MAX=36                # 36 × 15s = 9 minutes — stays under the Bash
                            # tool's 10-minute hard cap with margin for
                            # command overhead. Hitting POLL_MAX does NOT
                            # mean timeout — see the round-budget note
                            # right after this loop.
POLL_COUNT=0
# Tmpfile names include $$ (PID) so concurrent /monitor-pr invocations on
# the same PR don't clobber each other.
RUNS_FILE="/tmp/monitor-pr-${PR_NUMBER}-${$}-runs.json"
PREV_SUMMARY=""

while [ "$POLL_COUNT" -lt "$POLL_MAX" ]; do
  # Capture full JSON to file; do NOT pipe it to stdout.
  gh run list --repo "$REPO" --branch "$BRANCH" --limit 20 \
    --json databaseId,name,status,conclusion,headSha \
    --jq '[.[] | select(.headSha == "'"$HEAD_SHA"'")]' \
    > "$RUNS_FILE"

  # Defensive: empty/missing file means gh failed (auth expired, network
  # blip). Without this check, all jq selectors below return 0 and the
  # loop would `break` claiming "all green" while CI is unknown.
  if [ ! -s "$RUNS_FILE" ] || ! jq -e 'type == "array"' "$RUNS_FILE" >/dev/null 2>&1; then
    echo "WARN poll $POLL_COUNT/$POLL_MAX: gh run list returned no JSON — retrying" >&2
    sleep "$POLL_INTERVAL"
    POLL_COUNT=$((POLL_COUNT + 1))
    continue
  fi

  # One-line summary. Note the `unknown` bucket: GitHub stamps
  # `status=completed` a few seconds before it stamps `conclusion`, so
  # there's a transient window where a run is in neither pending nor
  # finalized state. Treating it as `pending` for loop control prevents
  # a false-green break during that window.
  SUMMARY=$(jq -r '
    [.[] | select(.status == "in_progress" or .status == "queued" or .status == "waiting")] as $p
    | [.[] | select(.status == "completed" and .conclusion == null)] as $u
    | [.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required")] as $f
    | [.[] | select(.conclusion == "success" or .conclusion == "skipped")] as $g
    | "pending=\($p|length) unknown=\($u|length) failed=\($f|length) green=\($g|length)"
      + (if (($p|length) + ($u|length)) > 0 then " | waiting: " + ([($p+$u)[].name] | join(",")) else "" end)
  ' "$RUNS_FILE")

  # `unknown` counts as pending for control flow.
  PENDING=$(jq '[.[] | select(.status == "in_progress" or .status == "queued" or .status == "waiting" or (.status == "completed" and .conclusion == null))] | length' "$RUNS_FILE")

  # Echo when the summary changes (state transition) OR every 10 polls
  # (liveness heartbeat — proves polling is still happening even when
  # nothing is changing).
  if [ "$SUMMARY" != "$PREV_SUMMARY" ] || (( POLL_COUNT > 0 && POLL_COUNT % 10 == 0 )); then
    printf 'poll %d/%d: %s\n' "$POLL_COUNT" "$POLL_MAX" "$SUMMARY"
    PREV_SUMMARY="$SUMMARY"
  fi

  if [ "$PENDING" -eq 0 ]; then break; fi
  sleep "$POLL_INTERVAL"
  POLL_COUNT=$((POLL_COUNT + 1))
done
```

After the loop exits, re-classify by reading the **final** state from
`$RUNS_FILE` (one jq invocation, scalar output — not the full JSON). Treat
`unknown` runs (completed but no conclusion stamped yet) as still-pending
for the timeout decision; they are not failures.

If `POLL_MAX` was hit with `unknown > 0`, surface that explicitly so the
user knows the timeout wasn't a clean classification:

```bash
UNKNOWN_AT_TIMEOUT=$(jq '[.[] | select(.status == "completed" and .conclusion == null)] | length' "$RUNS_FILE")
if [ "$POLL_COUNT" -eq "$POLL_MAX" ] && [ "$UNKNOWN_AT_TIMEOUT" -gt 0 ]; then
  echo "WARN $UNKNOWN_AT_TIMEOUT runs are completed-but-unstamped at POLL_MAX — re-run /monitor-pr in ~30s for a clean read"
fi
```

**Round budget (this call's 9-minute wait may not be enough).** A single
Bash tool call cannot run longer than the harness's 10-minute hard cap, so
one invocation of the `while` loop above can only wait ~9 minutes. If CI is
still pending when that loop exits (`FINAL_PENDING > 0` at `POLL_MAX`),
that is **not** a timeout by itself — it means "poll again in a fresh
call." Track how many rounds have run for the current `HEAD_SHA` in
`$STATE_FILE` (see Step 3's state-file note):

```bash
# Reset the round counter on a new HEAD_SHA — a push landed since the
# budget was last consumed, so CI is starting over.
STATE_SHA=$(jq -r '.last_processed_sha' "$STATE_FILE")
if [ "$STATE_SHA" != "$HEAD_SHA" ]; then
  jq --arg sha "$HEAD_SHA" '.poll_rounds_used = 0 | .last_processed_sha = $sha' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

FINAL_PENDING=$(jq '[.[] | select(.status == "in_progress" or .status == "queued" or .status == "waiting" or (.status == "completed" and .conclusion == null))] | length' "$RUNS_FILE")

if [ "$FINAL_PENDING" -gt 0 ]; then
  MAX_ROUNDS=$(jq '.max_poll_rounds' "$STATE_FILE")
  ROUNDS_USED=$(( $(jq '.poll_rounds_used' "$STATE_FILE") + 1 ))
  jq --argjson r "$ROUNDS_USED" '.poll_rounds_used = $r' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  if [ "$ROUNDS_USED" -lt "$MAX_ROUNDS" ]; then
    echo "CI still pending after round $ROUNDS_USED/$MAX_ROUNDS (~9 min) — re-invoke this Step 3.2a block again in a new call."
  else
    echo "CI still pending after $MAX_ROUNDS rounds (~$((MAX_ROUNDS * 9)) min total) — treat as ci_timeout, proceed to Step 3.5."
  fi
fi
```

Re-invoke this whole 3.2a block as a fresh Bash call while
`poll_rounds_used < max_poll_rounds` in `$STATE_FILE`. Only fall through to
`ci_timeout` once the round budget (3 rounds × ~9 min ≈ 27 min total) is
exhausted — enough runway for slow CI without ever exceeding a single
call's 10-minute cap.

```bash
jq -r '
  [.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required") | "\(.databaseId)\t\(.name)\t\(.conclusion)"]
  | .[]' "$RUNS_FILE"
```

That gives you `<id>\t<name>\t<conclusion>` per failed run — exactly what 3.3
needs. Avoid `cat $RUNS_FILE` or any unfiltered `jq '.'` of the file; load
specific fields only.

- `success` / `skipped` → green
- `failure` / `cancelled` / `timed_out` / `action_required` → fall through to 3.3
- Still pending after `POLL_MAX` and `poll_rounds_used < max_poll_rounds` → re-invoke this block in a fresh call (see round budget above)
- Still pending after `max_poll_rounds` is exhausted → report `ci_timeout` and exit the monitor loop; the round budget is a safety rail, not a failure signal

This pattern is synchronous, non-interactive, and bounded within each call —
and bounded overall via the round budget, so it never silently waits forever
or exceeds the harness's per-call time limit. It produces no background
processes, no TTY escape sequences, and no orphaned tasks.

### 3.3 Investigate and Fix Failed Runs

For each failed run, fetch the failure log. **Cap the inline read at the
last 200 lines** — most CI failures surface the actionable error in the
final stack trace / error block, and full logs routinely run 20k–300k
tokens (verbose pytest, `set -x`, npm spam). Always write the full log to
a tmpfile so you can `Read` earlier slices on demand without ever piping
the whole thing to context.

```bash
LOG_FILE="/tmp/monitor-pr-${PR_NUMBER}-${$}-run-{run_id}.log"
gh run view {run_id} --repo "$REPO" --log-failed > "$LOG_FILE"

# Defensive: empty file means gh failed (auth, rate limit, network), or
# the run has no failed steps yet. Without this check the multi-job
# detection below sees JOB_COUNT=0 and silently produces no diagnostic.
if [ ! -s "$LOG_FILE" ]; then
  echo "WARN gh run view --log-failed produced no output for run {run_id} — skipping diagnosis (re-run or check gh auth)"
else
  tail -n 200 "$LOG_FILE"
fi

# Detect multi-job failures. gh's --log-failed concatenates failed steps
# from every failed job, prefixed with the job name + tab. If the file
# contains more than one distinct job-name prefix block, the tail-200
# may show only the LAST job's noise while an earlier job hides the real
# stack trace. In that case, walk each failed job individually rather
# than trusting the unified tail.
JOB_COUNT=$(awk -F'\t' 'NF>1 {print $1}' "$LOG_FILE" | sort -u | wc -l)
if [ "$JOB_COUNT" -gt 1 ]; then
  echo "WARN multi-job failure ($JOB_COUNT failed jobs in $LOG_FILE) — tail-200 may not capture earlier job's error"
  echo "     Inspect each job's segment via Read with offset, or re-fetch per-job logs:"
  awk -F'\t' 'NF>1 {print $1}' "$LOG_FILE" | sort -u
fi
```

When the multi-job warning fires, do **not** rely on the tail-200 — use
`Read` with `offset`/`limit` to inspect each job's segment of `$LOG_FILE`,
or re-fetch a specific job's log via `gh run view {run_id} --job <job-id>
--log`. Acting on the wrong job's noise is the classic ghost-fix mode.

For a single-job failure, the tail-200 is normally sufficient. If it
still doesn't surface an actionable error (rare — happens with multi-stage
CI where a prep step fails and downstream stages run on cached artifacts),
use `Read` with `offset`/`limit` rather than re-fetching the whole file.

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

Load the running list at the start of this step — do not rely on a shell
variable from a prior call: `PROCESSED_COMMENTS=$(jq -c '.processed_comments' "$STATE_FILE")`.

Fetch PR comments (inline and review-level). **Filter out stale/outdated comments
before acting** — GitHub keeps historical comments on every commit a PR has ever
had, and acting on a comment whose code no longer exists produces ghost-fix
churn (the exact failure mode that motivated this skill).

**Token discipline:** these endpoints return every comment ever posted on
the PR — bodies, code snippets, suggestion blocks. On a heavily reviewed
PR that's tens of KB. Apply the staleness/author/processed filters
**inside a piped jq stage** so only actionable comments cross into
context. Drop `--paginate` for the default 100-per-page fetch; only
paginate when total exceeds the cap (rare).

> **Implementation note.** `gh api` exposes only `-q/--jq` for an inline
> filter and does **not** accept `--arg` / `--argjson`. To parameterize the
> filter (with `$GH_USER` and `$PROCESSED_COMMENTS`), pipe `gh api`'s raw
> JSON into a separate `jq` invocation. Do not collapse the two stages.

```bash
GH_USER=$(gh api user --jq .login)

# Reusable filter expression — keep it in one place to prevent drift
# between the first-page fetch and the paginate fallback.
COMMENT_FILTER='
  [.[]
    | select(.position != null)            # drop stale (line removed from diff)
    | select(.user.login != $me)           # drop self-replies
    | select(([(.id | tostring)] | inside($processed)) | not)  # drop already-handled
    | {id, path, line, original_line, position, original_position,
       author: .user.login, body, in_reply_to_id,
       created_at, commit_id, original_commit_id}]
'
REVIEW_FILTER='
  [.[]
    | select(.user.login != $me)
    | select(([(.id | tostring)] | inside($processed)) | not)
    | {id, state, author: .user.login, body, submitted_at, commit_id}]
'

# Inline review comments. PROCESSED_COMMENTS must be a JSON array (eg
# '["123","456"]'); see Step 3 init. Use string IDs to avoid jq's
# integer-vs-string equality footguns.
gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments?per_page=100" \
  | jq --arg me "$GH_USER" --argjson processed "$PROCESSED_COMMENTS" \
       "$COMMENT_FILTER"

# Review-level comments — same shape.
gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews?per_page=100" \
  | jq --arg me "$GH_USER" --argjson processed "$PROCESSED_COMMENTS" \
       "$REVIEW_FILTER"
```

If either raw `gh api` response includes exactly 100 entries (the cap),
there may be more — fall back to `gh api --paginate ...` for that endpoint
and re-apply the same `$COMMENT_FILTER` / `$REVIEW_FILTER` via the same
**piped** `jq` invocation. Do not collapse this back into `gh api --jq`;
that path does not accept `--arg`/`--argjson` and silently breaks the
filter. Use exactly:

```bash
gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/comments?per_page=100" \
  | jq --arg me "$GH_USER" --argjson processed "$PROCESSED_COMMENTS" --slurp \
       "[.[] | $COMMENT_FILTER[]]"
```

`--paginate` returns a stream of arrays (one per page); `--slurp` flattens
them into a single array before the filter applies. Same shape for the
reviews endpoint.

To **mark a comment processed**, append its ID directly to `$STATE_FILE`
(preserving array shape, deduped) — do not concatenate strings, and do not
hold this only in a shell variable, since it must survive into the next
Bash call:

```bash
jq --arg id "$COMMENT_ID" '.processed_comments += [$id] | .processed_comments |= unique' \
  "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
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

Silently mark stale comments as processed (persist their IDs to
`$STATE_FILE` via the jq command above) so subsequent iterations do not
re-examine them. Do **not** reply to stale comments — the reviewer already
knows the code moved.

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

**Every comment this skill acts on must have its ID persisted to `$STATE_FILE`'s `processed_comments`.** Track both inline-comment IDs and review IDs separately to avoid ID collisions.

**Do NOT resolve conversation threads** — resolution is a reviewer's prerogative. Leave the comment for the reviewer to mark resolved after inspecting the fix.

### 3.5 Decide Whether to Continue

**Increment `iteration` unconditionally, every pass** — whether or not a
fix was pushed. (The prior version only incremented on a pushed fix, so a
PR that's green and just waiting on reviewer approval never advanced the
counter, and the iteration cap could never trigger — it polled forever.)

```bash
jq '.iteration += 1' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
ITERATION=$(jq '.iteration' "$STATE_FILE")
MAX_ITERATIONS=$(jq '.max_iterations' "$STATE_FILE")
```

- If the PR reached a terminal state in 3.1 → exit loop with `success` status
- If `ITERATION >= MAX_ITERATIONS` → exit loop with `iteration_cap_hit` status
- If any fix was pushed or any comment was acted on this iteration → reset the idle counter, skip the sleep, loop immediately:
  ```bash
  jq '.idle_polls = 0' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  ```
- Otherwise (CI green, nothing pushed, no comment acted on — the PR is simply waiting on reviewer approval, and there is nothing left for this skill to do) → increment the idle counter and check the cap:
  ```bash
  jq '.idle_polls += 1' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  IDLE_POLLS=$(jq '.idle_polls' "$STATE_FILE")
  MAX_IDLE_POLLS=$(jq '.max_idle_polls' "$STATE_FILE")
  ```
  - If `IDLE_POLLS >= MAX_IDLE_POLLS` → exit loop with `awaiting_review` status
  - Otherwise → sleep 10 seconds, then loop

**Iteration compaction (token discipline).** Before re-entering the loop,
write a one-line summary of this iteration to a scratch file and rely on
that as the state-of-record going forward:

```bash
# No ${$} (PID) here, unlike $RUNS_FILE/$LOG_FILE — this file must
# accumulate across the whole run's iterations, each a separate Bash call
# with a different PID, so it has to be named per-PR, not per-call.
SUMMARY_FILE="/tmp/monitor-pr-${PR_NUMBER}-iter-summary.log"
# Bash arrays of flagged/skipped IDs (id|reason). Joined for the summary
# line; persist them so iter N+1 doesn't re-discover and re-flag.
FLAGGED_JOIN=$(IFS=, ; echo "${FLAGGED_THIS_ITER[*]:-}")
SKIPPED_JOIN=$(IFS=, ; echo "${SKIPPED_THIS_ITER[*]:-}")
printf 'iter %d HEAD=%s | green=%d failed=%d fixed=%d comments_acted=%d | flagged=[%s] skipped=[%s]\n' \
  "$ITERATION" "$HEAD_SHA" "$GREEN_COUNT" "$FAILED_COUNT" \
  "$FIXES_PUSHED_THIS_ITER" "$COMMENTS_ACTED_THIS_ITER" \
  "$FLAGGED_JOIN" "$SKIPPED_JOIN" \
  >> "$SUMMARY_FILE"
```

**Critical:** any comment the operator chose **not** to act on (flagged
for user judgment, skipped as ambiguous, deferred as conflicting with
existing decisions) must have its ID persisted to `$STATE_FILE`'s
`processed_comments` **and** appear in the iteration summary's
`flagged=[...]` / `skipped=[...]` field. Without this, iter N+1 fetches
the same comment, sees it's not in `processed_comments`, and either
re-flags it (final report shows duplicates) or — worse — *acts* on it
because the original "this needs human judgment" decision context is
lost. Treat `$STATE_FILE`'s `processed_comments` as the durable record of
"this skill has made a decision about this comment ID" — not just "this
skill applied a fix."

After writing the summary, treat the per-poll JSON, the failed-log tail,
and the per-comment fetch from this iteration as discardable. Do not
re-echo them, do not summarize them again — the next iteration starts
fresh and only re-loads what's needed for the new HEAD_SHA. The Step 4
final report reads `$SUMMARY_FILE` (cheap, structured) rather than
reconstructing history from the conversation.

**Tmpfile lifecycle.** All per-iteration tmpfiles (`$RUNS_FILE`, `$LOG_FILE`
per run, `$SUMMARY_FILE`) include `${$}` (PID) in their names so concurrent
invocations targeting the same PR don't clobber each other.

**Do not set an `EXIT` trap for cleanup.** Each Step 3.x block runs as its
own Bash process, so a trap registered in one call fires when *that call*
exits — not when the whole skill finishes — deleting files a later step
(Step 4's final report reads `$SUMMARY_FILE`) still needs. Clean up
explicitly instead, once, at the very end of Step 4 (see below); never
mid-loop.

**Safety rails:**
- Track failures by **workflow name** across pushed SHAs, not by run ID — each push creates new run IDs, so "same run ID fails twice" is unreachable. If the same workflow name fails on two consecutive pushed SHAs after a fix attempt, stop and report — the fix is not working and human judgment is required
- If a review comment body contains obvious secret-like patterns (API keys, tokens, passwords) that the reviewer has exposed, do NOT echo them in commits or replies; flag to the user

---

## Step 4: Final Report

Read `$STATE_FILE` one last time for `iteration`/`max_iterations` before
composing the report — do not rely on shell variables from a prior call.

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
- `awaiting_review` — CI green, no actionable comments, idle-poll cap reached; the PR is simply waiting on a reviewer and there is nothing left for this skill to do
- `blocked_needs_human` — a comment requires user judgment the skill refused to guess at
- `ci_stuck` — the same workflow failed repeatedly after fix attempts
- `ci_timeout` — at least one workflow remained pending past the 3.2a round budget (no failure signal, but the skill gave up waiting)

**If status is not `ready to merge` / `merged`**, list each unresolved item so the user can act.

**Cleanup (do this last, once, after the report above has been printed):**

```bash
rm -f "$STATE_FILE" "$SUMMARY_FILE" /tmp/monitor-pr-"${PR_NUMBER}"-*-runs.json /tmp/monitor-pr-"${PR_NUMBER}"-*-run-*.log
```

This is the one and only cleanup point — no `trap`, no mid-loop deletion.
If the skill exits early (error, user interrupt), leaving these tmpfiles
behind is harmless; the next `/monitor-pr` invocation for this PR
re-initializes `$STATE_FILE` fresh (Step 3) and stale run/log files are
simply overwritten or ignored.

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
- **Token discipline.** monitor-pr is the longest-lived skill in the plugin and the only one that polls a remote system. Without care it is the only Sonnet skill that routinely crosses the 200k context window (which requires the 1M-context tier on the Anthropic API). Three rules keep it bounded:
  1. **Polling JSON goes to a tmpfile, not to context.** The poll loop in 3.2a redirects every `gh run list` response to `$RUNS_FILE` and emits only a one-line summary — and even that line is suppressed when it's identical to the previous one. Without this, 80 polls × 750 tokens × 10 iterations = ~600k tokens of "still pending" noise.
  2. **Failed CI logs are tail-capped at 200 lines, full log written to a tmpfile.** The actionable error is almost always at the end. Re-read earlier slices via `Read` with `offset` only if needed. A single verbose pytest log unbounded is enough to blow the context window by itself.
  3. **Iteration compaction.** At the end of each iteration, write a one-line summary to `$SUMMARY_FILE` and treat per-poll JSON / log tails / comment fetches from that iteration as discardable. The Step 4 final report reads from the summary file, not from conversation history.
