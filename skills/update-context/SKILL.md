---
name: update-context
category: implementation
model: claude-sonnet-5
userInvocable: true
description: Annotate an active work session with a note, scope change, or new finding. Auto-detects the active session, synthesizes the salient points of the current conversation, and appends a timestamped entry to state.json after a single target confirmation. Use mid-session when you learn something that should be preserved.
argument-hint: "[identifier] [note]"
allowed-tools: "Read, Write, Bash(source:*), Bash(echo:*), Bash(rm:*), Bash(jq:*), Bash(yq:*), Bash(flock:*), Bash(git:*), Bash(date:*), Bash(mv:*), Bash(touch:*), AskUserQuestion"
---

# Update Context

Append a timestamped note or update to an active work session's `state.json`.

## Purpose

Use this when something happens during a session that should be recorded against the work:
- New constraint or requirement discovered during implementation
- Scope change agreed with the team
- Blocker or dependency found
- Decision made mid-session that future context should know about

Invoked with no arguments, it behaves the way you mean when you say *"update the ticket context"*: it figures out which work session is active, synthesizes what happened **this session** (decisions, Q&A, scope changes, blockers) into a note, and records it — after confirming the target ticket with you.

**Scope:** `/update-context` is for free-form notes only — it appends to `state.json` without changing lifecycle state. For advancing a session's post-implementation lifecycle (e.g., to `in-review`, `merged`, `completed`), use `/work-status --update`. The two skills write to the same `state.json` but own different fields.

**"Session" means the current conversation / context window** — the discussion this command can see. Synthesis reasons over that in-context memory; no tool reads raw transcript history. If you invoke this in a fresh context window, it can only synthesize what that window contains.

## Context

Arguments: $ARGUMENTS

---

## Configuration

```bash
# Source resolve-config: ${CLAUDE_PLUGIN_ROOT} is set by the marketplace runtime.
# The ~/.claude fallback exists for development/local copies; it is not the
# primary install path. Fail loudly if neither resolves.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found. Install the plugin via the marketplace." >&2
  exit 1
fi
WORK_DIR=$(resolve_artifact work work)
```

---

## Workflow

### Step 1: Resolve the target session (detection chain)

Determine the candidate `{identifier}` by walking the following priority order. **Stop at the first candidate** — but every candidate, even a single high-confidence map hit, is confirmed in Step 4 before any write.

First, resolve the runtime session id. The Claude Code runtime injects `CLAUDE_CODE_SESSION_ID`; `CLAUDE_SESSION_ID` is preferred when present (forward-compat). This is the same value the `auto-context.sh` hook reads from its stdin payload (verified: the resolved id equals the session-transcript filename, which is the UUID the runtime passes to hooks as `.session_id`), so it matches the key the session-registering skills write into `.active-sessions`.

**Work-id safety:** any `{identifier}` taken from the `.active-sessions` map, the manifest, or the git branch is untrusted input flowing into a filesystem path. Reject anything that is not `^[A-Za-z0-9._-]+$` before using it in a path (mirrors `auto-context.sh:84`). The validation below enforces this centrally.

```bash
SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
SENTINEL="$WORK_DIR/.active-sessions"
CANDIDATE=""
SOURCE=""

# Priority 1 — explicit argument: first non-flag token matching an existing work dir.
# (Parse $ARGUMENTS: the first word not starting with '-' that matches
#  "$WORK_DIR/<token>/" is {identifier}; the remaining text is the explicit {note}.)
# Set CANDIDATE / SOURCE="arg" here when an explicit id is supplied.

# Priority 2 — active-sessions map (the session→ticket mapping).
if [ -z "$CANDIDATE" ] && [ -n "$SID" ] && [ -s "$SENTINEL" ]; then
  touch "$SENTINEL.lock" 2>/dev/null || true
  MAPPED=$(
    exec 200>"$SENTINEL.lock"
    flock -s -w 1 200 2>/dev/null || exit 0
    jq -r --arg s "$SID" '.[$s] // empty' "$SENTINEL" 2>/dev/null
  )
  # Reject a poisoned map value before it touches a path (mirror auto-context.sh:84).
  if [ -n "$MAPPED" ] && [[ "$MAPPED" =~ ^[A-Za-z0-9._-]+$ ]] && [ -d "$WORK_DIR/$MAPPED" ]; then
    CANDIDATE="$MAPPED"; SOURCE="active-sessions map"
  fi
fi

# Priority 3 — most-recently-updated non-completed session from the manifest.
# Git branch is a secondary tie-break signal: a feature/<id> branch whose <id>
# matches a non-completed session is preferred over pure recency.
if [ -z "$CANDIDATE" ] && [ -f "$WORK_DIR/manifest.json" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  # Only treat the branch as an id signal when it follows the feature/<id> convention.
  case "$BRANCH" in
    feature/*) BRANCH_ID="${BRANCH#feature/}" ;;
    *)         BRANCH_ID="" ;;
  esac
  if [ -n "$BRANCH_ID" ] && [[ "$BRANCH_ID" =~ ^[A-Za-z0-9._-]+$ ]] && [ -d "$WORK_DIR/$BRANCH_ID" ] \
     && [ "$(jq -r --arg id "$BRANCH_ID" '.items[] | select(.identifier==$id) | .status // empty' "$WORK_DIR/manifest.json" 2>/dev/null)" != "completed" ]; then
    CANDIDATE="$BRANCH_ID"; SOURCE="current git branch"
  else
    CANDIDATE=$(jq -r '[.items[] | select(.status != "completed")] | sort_by(.updated_at) | reverse | .[0].identifier // empty' "$WORK_DIR/manifest.json" 2>/dev/null)
    [ -n "$CANDIDATE" ] && SOURCE="most-recent non-completed session"
  fi
fi

# Central safety net: never carry a candidate that is not a safe path segment.
if [ -n "$CANDIDATE" ] && ! [[ "$CANDIDATE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Rejected unsafe identifier '$CANDIDATE' — falling back to ask." >&2
  CANDIDATE=""; SOURCE=""
fi

```

**Priority 4 — ask.** If `CANDIDATE` is still empty, there is no detectable session. List what exists and ask:

```bash
jq -r '.items[] | select(.status != "completed") | "\(.identifier)  \(.title)  [\(.type)]"' \
  "${WORK_DIR}/manifest.json" 2>/dev/null
```

Use AskUserQuestion to have the user pick an identifier (or, if the manifest is missing, scan `$WORK_DIR/*/` directories). If nothing non-completed exists, say so plainly and stop — do not fail silently.

> **Announced fall-through.** When Priority 2 finds no map entry (e.g. the session was not started by a registering skill), announce the fall to Priority 3 — e.g. `No active-sessions entry for this session; using most-recent non-completed session.` Never silently skip a tier.

### Step 2: Synthesize the note (skip if an explicit note was supplied)

If the user supplied explicit note text in `$ARGUMENTS` (Priority 1 / any remaining text after the identifier), use it **verbatim** and skip synthesis. Set `NOTE_SOURCE="explicit"`.

Otherwise, compose the note yourself by reasoning over **this conversation** (the current context window). Set `NOTE_SOURCE="synthesis"`. Group the salient points under these headings, **omitting any group that has nothing**:

- **Decisions** — choices made and the reason, if stated
- **Q&A** — questions raised and their resolved answers
- **Scope changes** — anything added to / removed from / deferred out of the work
- **Blockers & findings** — dependencies, constraints, or discoveries that affect the work

Keep it concise prose, not a transcript dump. This is inline reasoning — do **not** delegate to a subagent and do **not** attempt to read transcript files; only the in-context conversation is available.

**Empty-synthesis guard:** if the conversation has nothing substantive to record (e.g. a fresh context window with no decisions/Q&A/scope/blockers), do **not** fabricate or write an empty note. Instead, tell the user there's nothing to synthesize and ask them to supply an explicit note (or cancel). Never write a blank `{note}`.

Hold the composed text as `{note}` and the origin as `NOTE_SOURCE` for the confirmation preview and the write.

### Step 3: Load state

```bash
STATE_FILE="$WORK_DIR/{identifier}/state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: No state found for '{identifier}'"
  echo "Expected: $STATE_FILE"
  exit 1
fi

TITLE=$(jq -r '.title // "(untitled)"' "$STATE_FILE")
STATUS=$(jq -r '.status // empty' "$STATE_FILE")

# Surface a completed session explicitly so the confirmation gate can warn (Step 4).
if [ "$STATUS" = "completed" ]; then
  echo "WARNING: $STATE_FILE is marked completed — appending will not reopen it."
fi
```

### Step 4: Confirm the target (mandatory gate)

**Never write without explicit confirmation** — this applies even to a single high-confidence `.active-sessions` hit. Auto-write applies to the note *content*, never the *target*.

Show the resolved target and a preview, then confirm via AskUserQuestion:

```
Update context for:
  {identifier} — {TITLE}
  detected via: {SOURCE}

Note to record:
  {note}

Proceed?
  [Yes, record it]
  [No, pick a different session]
  [Cancel]
```

- **Yes** → continue to Step 5.
- **No** → re-run the Priority-4 list and let the user pick a different identifier, then return here. Nothing is written until confirmed.
- **Cancel** → stop without writing.

**Completed-session guard:** if `STATUS == "completed"`, warn before the confirmation — *"{identifier} is marked completed; appending a note will not reopen it."* — and require the user to explicitly confirm anyway. Do not silently append to a completed session.

### Step 5: Append the update (hardened write)

Serialize the write against the `auto-context.sh` hook with the same exclusive lock it uses, so concurrent writes cannot corrupt `state.json`.

For a **synthesized** note, tag the entry `"source":"synthesis"`. For an **explicit user-supplied** note, omit the `source` field (it stays a plain manual entry).

```bash
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE_LOCK="${STATE_FILE}.lock"
touch "$STATE_LOCK"

if [ "$NOTE_SOURCE" = "explicit" ]; then
  # Explicit user-supplied note — no source tag (plain manual entry per schema)
  (
    flock -x -w 2 200 || { echo "Could not acquire lock on $STATE_FILE"; exit 1; }
    jq --arg note "{note}" --arg ts "$TIMESTAMP" \
      '.updates = ((.updates // []) + [{"timestamp": $ts, "note": $note}]) | .updated_at = $ts' \
      "$STATE_FILE" > "${STATE_FILE}.tmp.$$" \
      && mv "${STATE_FILE}.tmp.$$" "$STATE_FILE" \
      || { rm -f "${STATE_FILE}.tmp.$$"; exit 1; }
  ) 200>"$STATE_LOCK"
else
  # Synthesized note (default when no explicit note was given) — tagged source:"synthesis"
  (
    flock -x -w 2 200 || { echo "Could not acquire lock on $STATE_FILE"; exit 1; }
    jq --arg note "{note}" --arg ts "$TIMESTAMP" --arg src "synthesis" \
      '.updates = ((.updates // []) + [{"timestamp": $ts, "note": $note, "source": $src}]) | .updated_at = $ts' \
      "$STATE_FILE" > "${STATE_FILE}.tmp.$$" \
      && mv "${STATE_FILE}.tmp.$$" "$STATE_FILE" \
      || { rm -f "${STATE_FILE}.tmp.$$"; exit 1; }
  ) 200>"$STATE_LOCK"
fi
```

### Step 6: Update manifest

```bash
MANIFEST="$WORK_DIR/manifest.json"

if [[ -f "$MANIFEST" ]]; then
  jq --arg id "{identifier}" --arg ts "$TIMESTAMP" \
    '(.items[] | select(.identifier == $id)) |= (.updated_at = $ts) | .last_updated = $ts' \
    "$MANIFEST" > "${MANIFEST}.tmp.$$" && mv "${MANIFEST}.tmp.$$" "$MANIFEST"
fi
```

### Step 7: Confirm

```
✓ Updated: {identifier}
  {timestamp}  {note}

Session now has {N} update(s). View with: /work-status {identifier}
```

---

## Updates Schema

The `updates` array in `state.json` holds all annotations. Entries have **three origins**, distinguished by which fields are present:

```json
{
  "updates": [
    {
      "timestamp": "2024-01-15T14:22:00Z",
      "note": "Discovered that the payment gateway requires webhook verification — adds scope to chunk 3"
    },
    {
      "timestamp": "2024-01-15T16:05:00Z",
      "note": "Decisions: defer mobile UI to v2. Blockers: webhook secret not yet provisioned.",
      "source": "synthesis"
    },
    {
      "timestamp": "2024-01-15T16:40:00Z",
      "note": "[auto] Edit: src/PaymentService.php",
      "auto": true
    }
  ]
}
```

| Origin | Shape | Written by |
|--------|-------|------------|
| **Manual** | `{timestamp, note}` | `/update-context` with an explicit note; `/work-status` lifecycle notes |
| **Synthesized** | `{timestamp, note, source:"synthesis"}` | `/update-context` when it summarizes the session |
| **Auto-hook** | `{timestamp, note, auto:true}` | `auto-context.sh` PostToolUse hook |

The `source` and `auto` fields are additive. All planning and implementation skills read `updates` when loading context for resume or `/load-context`, surfacing them under a **Session Updates** section — they read `.note` and are unaffected by the extra discriminator fields.

---

## Automatic State Updates

Beyond manual annotations, skills write progress to `state.json` automatically at these points:

| Skill | Auto-update triggers |
|-------|---------------------|
| `brainstorm` | After each phase completes (exploration, approaches, refinement, quality_guard, work_breakdown) |
| `create-requirements` | After each stage completes; after each deep-dive agent saves output |
| `create-proposal` | After each phase and each proposal iteration |
| `epic` | After ticket generation completes |
| `implement` | After each chunk commit; after QA gate result |

The `updated_at` field in `state.json` always reflects the last write, so `/work-status` shows accurate recency without requiring manual intervention.
