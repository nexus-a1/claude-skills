---
name: update-context
category: implementation
model: haiku
userInvocable: true
description: Annotate an active work session with a note, scope change, or new finding. Appends a timestamped entry to state.json and updates the manifest. Use mid-session when you learn something that should be preserved.
argument-hint: [identifier] [note]
allowed-tools: Read, Write, Bash(jq:*), AskUserQuestion
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
# BEGIN_SHARED: resolve-config
# Shared configuration resolution for Claude Code skills.
# Source this script to get config discovery and artifact resolution functions.
#
# Usage in SKILL.md bash blocks:
#   source ~/.claude/shared/resolve-config.sh
#   WORK_DIR=$(resolve_artifact work work)
#   EXEC_MODE=$(resolve_exec_mode qa_review team)

# --- Config discovery ---
# Walks up from CWD to find .claude/configuration.yml
CONFIG=""
_d="$PWD"
while [[ "$_d" != "/" ]]; do
  if [[ -f "$_d/.claude/configuration.yml" ]]; then
    CONFIG="$_d/.claude/configuration.yml"
    break
  fi
  _d="$(dirname "$_d")"
done

# --- Artifact resolution ---
# Resolves an artifact path from configuration, with fallback defaults.
# Usage: resolve_artifact <artifact_name> <default_subdir> [default_base]
# Returns: resolved path (e.g., ".claude/work" or "/abs/path/to/requirements")
resolve_artifact() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    echo "${_BASE}/${_SUB}"
  else
    echo "${default_base}/${default_subdir}"
  fi
}

# --- Artifact resolution with type ---
# Like resolve_artifact but also returns the storage type (git|directory).
# Usage: IFS='|' read -r PATH TYPE <<< "$(resolve_artifact_typed work work)"
resolve_artifact_typed() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    local _TYPE=$(yq -r ".storage.locations.${_LOC}.type // \"directory\"" "$CONFIG")
    echo "${_BASE}/${_SUB}|${_TYPE}"
  else
    echo "${default_base}/${default_subdir}|directory"
  fi
}

# --- Execution mode resolution ---
# Resolves execution mode for a specific phase from configuration.
# Usage: resolve_exec_mode <phase_name> [default_mode]
# Returns: "team" or "subagent"
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
# END_SHARED: resolve-config
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

Session now has {N} update(s). View with: /status {identifier}
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

All planning and implementation skills read `updates` when loading context for resume or `/context`, and surface them under a **Session Updates** section.

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

The `updated_at` field in `state.json` always reflects the last write, so `/status` shows accurate recency without requiring manual intervention.
