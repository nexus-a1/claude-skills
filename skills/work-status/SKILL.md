---
name: work-status
category: project-setup
model: claude-sonnet-4-6
userInvocable: true
description: Show all active work sessions across brainstorms, requirements, proposals, and epics. Supports --update to advance lifecycle on one session and --sync to sweep them all.
argument-hint: "[--update | --sync] [identifier]"
allowed-tools: "Read, Glob, Bash(jq:*), Bash(git:*), Bash(ls:*), Bash(yq:*), Bash(gh:*), Bash(date:*), Bash(mktemp:*), Bash(mv:*), AskUserQuestion"
---

# Work Status

Show active work sessions and advance their post-implementation lifecycle.

**Scope:** `/work-status` owns the `lifecycle` field in `state.json` — use it for status transitions (`in-review`, `merged`, `completed`, etc.). For free-form notes, scope changes, or mid-session findings that should be preserved against a session, use `/update-context` instead. Both skills write to the same `state.json` but own different fields.

## Usage

```bash
/work-status                        # List all active sessions (read-only)
/work-status {identifier}           # Detailed view of one session (read-only)
/work-status --update               # Advance lifecycle on the current session
/work-status --update {identifier}  # Advance lifecycle on a specific session
/work-status --sync                 # Sweep all non-completed sessions, update interactively
```

## Lifecycle States

Lifecycle is a post-implementation overlay. It tracks where a ticket sits once the planning/implementation phases are done and real-world review/QA/merge kicks in. Stored as the top-level `lifecycle` field in `state.json`, independent from the `phases.*` tracking that skills write automatically.

| State | Meaning |
|-------|---------|
| `ready_to_implement` | Requirements complete, no implementation started |
| `in_progress` | Code being written; PR may or may not exist |
| `qa_ready` | PR open, CI green, code review approved — waiting on QA |
| `qa` | QA actively testing |
| `done` | PR merged and QA signed off |

Sessions without a `lifecycle` field are pre-lifecycle (planning stages) and are listed under their phase label.

## Configuration

```bash
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found. Install via marketplace or run ./install.sh" >&2
  exit 1
fi
WORK_DIR=$(resolve_artifact work work)
MANIFEST="${WORK_DIR}/manifest.json"
```

---

## Mode Routing

Parse `$ARGUMENTS`:

- `--sync` anywhere → **Sync mode** (Section 3)
- `--update` anywhere → **Update mode** (Section 2); remaining non-flag token is `{identifier}` if provided
- First non-flag token matches a directory under `$WORK_DIR/` → **Detail mode** (Section 1b)
- No arguments → **List mode** (Section 1a)

---

## 1. List / Detail Mode (read-only)

### 1a. List all active sessions (`/work-status`)

```bash
if [[ ! -f "$MANIFEST" ]]; then
  for dir in "${WORK_DIR}"/*/; do
    [[ -f "${dir}state.json" ]] && echo "${dir}state.json"
  done
fi
```

Read the manifest and display all sessions grouped by type. **Omit entries where `status == "completed"` or `lifecycle == "done"`.**

Output shape:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Active Work Sessions
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔵 Brainstorm
  user-export       User Data Export                   deep_dive     2h ago
  sso-integration   SSO with Azure AD                  Promoted → PROJ-456

🟡 Requirements
  PROJ-123          Payment Refund Flow                deep_dive     3h ago
  PROJ-456          SSO Integration        (from sso-integration)    1h ago

🟢 Lifecycle
  PROJ-789          Checkout Redesign                  in_progress   2h ago
  PROJ-790          Shipping Rules                     qa_ready      1d ago

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Advance: /work-status --update {identifier}
Sweep:   /work-status --sync
Resume:  /resume-work {identifier}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Formatting rules:**
- Sessions with a `lifecycle` field appear under the **Lifecycle** group instead of their original type
- Brainstorm with `status == "promoted"`: show `Promoted → {promoted_to}`
- Requirements with `brainstorm.promoted_from`: show `(from {promoted_from})`
- Completed / done items: excluded

If no active sessions:
```
No active work sessions.

Start one:
  /brainstorm           — explore approaches for a feature
  /create-requirements  — deep requirements for a ticket
  /epic                 — break down a large initiative
```

### 1b. Show single session (`/work-status {identifier}`)

Read `$WORK_DIR/{identifier}/state.json`. If a `lifecycle` field is present, show it prominently; otherwise show the phase checklist.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PROJ-123 — Payment Refund Flow
Type: Requirements | Lifecycle: in_progress
Branch: feature/PROJ-123
PR: #482 (open, checks passing, 1 approval)
Last updated: 3 hours ago
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✓ Stage 1  Setup
  ✓ Stage 2  Discovery
  ✓ Stage 3  Deep dive
  ✓ Stage 4  Synthesis
  → Implementation  (chunk 3/5)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Advance: /work-status --update PROJ-123
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 2. Update Mode (`--update`)

### Step 2.1: Resolve identifier

If `{identifier}` was passed explicitly on the command line, use it and skip to 2.2.

Otherwise, derive from context — collect all candidates, present findings, confirm with user:

1. **Current git branch** — `git rev-parse --abbrev-ref HEAD`, then find sessions whose `state.json` has a `branch` field matching (exact or the `feature/{identifier}` convention).
2. **Branch substring match** — identifier substring within the branch name (e.g. `feat/PROJ-123-refund` → `PROJ-123`).
3. **Most recently updated non-completed session** — `jq` sort by `updated_at` desc on `$MANIFEST`.

Present findings with `AskUserQuestion`:

```
Detected session for update: PROJ-123 (Payment Refund Flow)
  Current branch: feature/PROJ-123
  Last updated: 3 hours ago
  Current lifecycle: in_progress

Use this session?
  [Yes, use PROJ-123]
  [No, pick different session]
```

If the user picks "No" or no candidate was found, list all non-completed sessions via `AskUserQuestion` and have them pick. If still nothing matches, ask them to type the identifier.

**Never auto-select without confirmation** — mutations require explicit user approval.

Once `{identifier}` is confirmed, set:

```bash
STATE_FILE="$WORK_DIR/{identifier}/state.json"
MANIFEST="$WORK_DIR/manifest.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: No state found for '{identifier}'. Expected: $STATE_FILE"
  exit 1
fi
```

### Step 2.2: Check PR status (if a PR exists)

Read `phases.pr.pr_number` from `state.json`. If present:

```bash
PR_NUM=$(jq -r '.phases.pr.pr_number // empty' "$STATE_FILE")
if [[ -n "$PR_NUM" ]]; then
  PR_JSON=$(gh pr view "$PR_NUM" --json state,mergedAt,reviewDecision,statusCheckRollup,isDraft 2>/dev/null)
fi
```

Parse:
- `state`: `OPEN` / `MERGED` / `CLOSED`
- `reviewDecision`: `APPROVED` / `CHANGES_REQUESTED` / `REVIEW_REQUIRED` / null
- `statusCheckRollup[].conclusion`: aggregate to `passing` / `failing` / `pending`
- `isDraft`: boolean

**Derived suggestion:**

| PR state | Suggest |
|----------|---------|
| `MERGED` | ask: `qa` or `done` (depending on whether QA has run) |
| `OPEN`, draft | `in_progress` |
| `OPEN`, checks failing | `in_progress` |
| `OPEN`, approved, checks green | `qa_ready` |
| `OPEN`, changes_requested | `in_progress` |
| `CLOSED` (not merged) | ask — likely abandoned |
| no PR | `ready_to_implement` or `in_progress` — ask |

If `gh` is unavailable or not authenticated, skip this step and go straight to Step 2.3 with no suggestion.

### Step 2.3: Confirm lifecycle transition

Present current + suggested state, let user pick:

```
PROJ-123 — Payment Refund Flow
Current lifecycle: in_progress
PR #482: open, checks passing, 1 approval

Suggested: qa_ready

Set lifecycle to?
  [qa_ready]      (suggested)
  [ready_to_implement]
  [in_progress]
  [qa]
  [done]
  [skip — don't change]
```

Use `AskUserQuestion` with the six options. If user picks "skip", exit without writing.

### Step 2.4: Write update

```bash
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NEW_STATE="{chosen_state}"

TMP_STATE=$(mktemp)
jq --arg s "$NEW_STATE" --arg ts "$TIMESTAMP" \
  '.lifecycle = $s
   | .lifecycle_updated_at = $ts
   | .updated_at = $ts
   | if $s == "done" then .status = "completed" else . end
   | .updates = ((.updates // []) + [{"timestamp": $ts, "note": ("lifecycle → " + $s)}])' \
  "$STATE_FILE" > "$TMP_STATE" && mv "$TMP_STATE" "$STATE_FILE"

if [[ -f "$MANIFEST" ]]; then
  TMP_MF=$(mktemp)
  jq --arg id "{identifier}" --arg s "$NEW_STATE" --arg ts "$TIMESTAMP" \
    '(.items[] | select(.identifier == $id)) |= (.lifecycle = $s | .updated_at = $ts | if $s == "done" then .status = "completed" else . end)' \
    "$MANIFEST" > "$TMP_MF" && mv "$TMP_MF" "$MANIFEST"
fi
```

### Step 2.5: Confirm

```
✓ PROJ-123 → qa_ready
  PR #482 open, 1 approval, checks passing
  Recorded 2026-04-22T14:22:00Z
```

---

## 3. Sync Mode (`--sync`)

Sweep all non-completed sessions and run the update flow per session.

### Step 3.1: Collect candidates

```bash
jq -r '.items[]
  | select((.status // "") != "completed" and (.lifecycle // "") != "done")
  | .identifier' "$MANIFEST"
```

If the manifest is missing, fall back to scanning `$WORK_DIR/*/state.json`.

### Step 3.2: For each session

Run Steps 2.2 → 2.4 from Update Mode. Between sessions, show a compact progress header:

```
[2/5] PROJ-123 — Payment Refund Flow
      Current: in_progress   Suggested: qa_ready
      PR #482 open, checks passing, 1 approval

Set lifecycle to? [ready_to_implement] [in_progress] [qa_ready] [qa] [done] [skip] [abort sync]
```

`[abort sync]` exits cleanly with whatever was already written.

### Step 3.3: Summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Sync complete — 5 sessions reviewed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ PROJ-123   in_progress → qa_ready
  ✓ PROJ-456   qa_ready    → qa
  ✓ PROJ-789   qa          → done  (archived)
  · PROJ-790   no change
  · AUTH-001   skipped
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Notes

- **List and detail modes remain read-only.** Only `--update` and `--sync` mutate state.
- **No tracker integration.** Jira/Linear/GitHub Issues status is out of scope; lifecycle is the plugin-internal view.
- **`gh` CLI is required** for PR status checks. If unavailable, `--update` still works — it just skips the suggestion and asks the user directly.
- **Identifier ambiguity** — always confirm with the user before mutating; never auto-pick a mutation target.
