---
name: update-context
category: implementation
model: claude-haiku-4-5
userInvocable: true
description: Annotate an active work session with a note, scope change, or new finding. Appends a timestamped entry to state.json and updates the manifest. Use mid-session when you learn something that should be preserved.
argument-hint: "[identifier] [note]"
allowed-tools: "Read, Write, Bash(jq:*), Bash(yq:*), AskUserQuestion"
---

# Update Context

Append a timestamped note or update to an active work session's `state.json`.

## Purpose

Use this when something happens outside the normal skill flow that should be recorded against the session:
- New constraint or requirement discovered during implementation
- Scope change agreed with the team
- Blocker or dependency found
- Decision made mid-session that future context should know about

## Context

Arguments: $ARGUMENTS

---

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
WORK_DIR=$(resolve_artifact work work)
```

---

## Workflow

### Step 1: Resolve identifier and note

Parse `$ARGUMENTS`:
- First word that doesn't start with `-` and matches an existing `$WORK_DIR/*/` directory → `{identifier}`
- Remaining text → `{note}`

If `{identifier}` not found in arguments or doesn't match a directory:

```bash
# List active sessions from manifest
jq -r '.items[] | select(.status != "completed") | "\(.identifier)  \(.title)  [\(.type)]"' \
  "${WORK_DIR}/manifest.json" 2>/dev/null
```

Use AskUserQuestion:
```
Which session do you want to update?
(enter identifier, e.g. PROJ-123 or user-export)
```

If `{note}` is empty, ask:
```
What do you want to record?
(scope change, blocker, decision, finding, etc.)
```

### Step 2: Load state

```bash
STATE_FILE="$WORK_DIR/{identifier}/state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: No state found for '{identifier}'"
  echo "Expected: $STATE_FILE"
  exit 1
fi
```

### Step 3: Append update

Merge a new entry into the `updates` array in `state.json`:

```bash
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq --arg note "{note}" --arg ts "$TIMESTAMP" \
  '.updates = ((.updates // []) + [{"timestamp": $ts, "note": $note}]) | .updated_at = $ts' \
  "$STATE_FILE" > /tmp/uc-tmp.json && mv /tmp/uc-tmp.json "$STATE_FILE"
```

### Step 4: Update manifest

```bash
MANIFEST="$WORK_DIR/manifest.json"

if [[ -f "$MANIFEST" ]]; then
  jq --arg id "{identifier}" --arg ts "$TIMESTAMP" \
    '(.items[] | select(.identifier == $id)) |= (.updated_at = $ts)' \
    "$MANIFEST" > /tmp/mf-tmp.json && mv /tmp/mf-tmp.json "$MANIFEST"
fi
```

### Step 5: Confirm

```
✓ Updated: {identifier}
  {timestamp}  {note}

Session now has {N} update(s). View with: /work-status {identifier}
```

---

## Updates Schema

The `updates` array in `state.json` holds all manual annotations:

```json
{
  "updates": [
    {
      "timestamp": "2024-01-15T14:22:00Z",
      "note": "Discovered that the payment gateway requires webhook verification — adds scope to chunk 3"
    },
    {
      "timestamp": "2024-01-15T16:05:00Z",
      "note": "Team agreed to defer mobile UI to v2 — descoped from this ticket"
    }
  ]
}
```

All planning and implementation skills read `updates` when loading context for resume or `/load-context`, and surface them under a **Session Updates** section.

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
