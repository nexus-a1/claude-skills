---
name: resume-work
category: implementation
model: claude-sonnet-4-6
userInvocable: true
description: Resume any interrupted work session — brainstorm, requirements, proposal, epic, or implementation. Scans for incomplete sessions and continues from the last saved checkpoint. Re-enters the original session's worktree if one was used; otherwise runs in the current working tree.
argument-hint: "[identifier]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion, EnterWorktree, ExitWorktree
---

# Resume Work

Arguments: $ARGUMENTS

## Purpose

Resume any interrupted work by:
1. Scanning `$WORK_DIR/` for incomplete implementations or requirements
2. Loading saved state and context
3. Continuing from where you left off

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work state and context |

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

Use `$WORK_DIR` instead of hardcoded `.claude/work` throughout this workflow.

**Important:** All path references in this skill MUST use `$WORK_DIR`. Never use hardcoded `.claude/work/` paths.

---

## Usage

```bash
/resume-work                    # Scan and show incomplete work
/resume-work JIRA-123          # Resume specific work by identifier
```

## Workflow

### When identifier is provided

```
/resume-work JIRA-123
```

1. Check if `$WORK_DIR/JIRA-123/` exists
2. Read `$WORK_DIR/JIRA-123/state.json`. If not found, report "No state found" and list available directories.
3. Validate schema version:
   - If `schema_version` is missing → WARN: "State file predates schema versioning. It may use an older format — proceed with caution."
   - If `schema_version` == 1 → OK, proceed normally
   - If `schema_version` > 1 → WARN: "State file was created with a newer framework version (v{N}) — proceed with caution."
4. Dispatch by `type` field (in priority order if type is ambiguous):

```bash
type=$(jq -r '.type' "$WORK_DIR/JIRA-123/state.json")
case "$type" in
  "implementation") # Resume implementation phase ;;
  "proposal")       # Resume proposal phase ;;
  "requirements")   # Requirements complete → offer to start /implement ;;
  "brainstorm")     # Resume or continue brainstorm ;;
  "epic")           # Resume epic ;;
  *)                # Unknown type → warn and show raw state ;;
esac
```

### When no identifier provided

```
/resume-work
```

**Scan for incomplete work (manifest-first):**

Prefer reading `${WORK_DIR}/manifest.json` over directory scans. Fall back to `ls` + per-directory reads if manifest is missing.

```bash
MANIFEST="${WORK_DIR}/manifest.json"
if [[ -f "$MANIFEST" ]]; then
  # Filter items where status != "completed"
  # This gives identifiers, titles, types, statuses, and progress without reading individual state files
  jq -r '.items[] | select(.status != "completed") | "\(.identifier)\t\(.title)\t\(.type)\t\(.current_phase)\t\(.progress)\t\(.updated_at)"' "$MANIFEST"
else
  # Fallback: scan directories
  ls -1 "${WORK_DIR}/" 2>/dev/null
  # For each directory, check state files
fi
```

**Present options to user:**

```
Found incomplete work:

[1] user-export - User Data Export
    Type: Brainstorm
    Stage: Approaches selected, work breakdown pending
    Last updated: 2 hours ago

[2] JIRA-123 - User Export Feature
    Type: Requirements
    Stage: Deep dive (Stage 3/4)
    Last updated: 1 day ago

[3] AUTH-001 - User Authentication
    Type: Proposal
    Stage: Drafts (iteration 2)
    Last updated: 3 hours ago

[4] user-dashboard - Dashboard Redesign
    Type: Implementation
    Stage: Review (issues found)
    Last updated: 5 hours ago

[5] Start fresh (create new requirements)

Select [1-5]:
```

Use AskUserQuestion to get selection.

### Re-register Active Session (for auto-context hook)

Once the target `{identifier}` is resolved (either from the argument or the user's manifest selection), re-register the current session → work-id mapping so the optional `auto-context.sh` PostToolUse hook can resolve it. This is a no-op when `CLAUDE_SESSION_ID` is unset or `jq` is missing:

```bash
if [ -n "${CLAUDE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
  mkdir -p "$WORK_DIR"
  touch "$WORK_DIR/.active-sessions.lock"
  (
    flock -x -w 2 200 || exit 0
    [ -s "$WORK_DIR/.active-sessions" ] || echo '{}' > "$WORK_DIR/.active-sessions"
    jq --arg s "$CLAUDE_SESSION_ID" --arg w "{identifier}" \
       '. + {($s): $w}' "$WORK_DIR/.active-sessions" \
       > "$WORK_DIR/.active-sessions.tmp.$$" \
       && mv "$WORK_DIR/.active-sessions.tmp.$$" "$WORK_DIR/.active-sessions" \
       || rm -f "$WORK_DIR/.active-sessions.tmp.$$"
  ) 200>"$WORK_DIR/.active-sessions.lock"
fi
```

The corresponding clear block lives inside the target skill that takes over (e.g. `/implement`'s Completion Cleanup section). `/resume-work` itself does not clear the sentinel because control hands off to the resumed skill.

### Surface Session Updates

Before resuming any session, check `state.json` for a non-empty `updates` array. If updates exist, display them:

```
Session updates recorded since last run:
  2024-01-15T14:22Z  Webhook requirement discovered — adds scope to chunk 3
  2024-01-15T16:05Z  Team agreed to defer mobile UI to v2
```

This ensures manually recorded context (via `/update-context`) is front-of-mind before continuing.

### Context File Conventions

When this skill reads per-agent outputs from `$WORK_DIR/{identifier}/context/` (for reporting progress, surfacing prior findings, or checking completion state), prefer the distilled `-summary.md` variant when present and fall back to the full file otherwise:

- `qa-code-reviewer-summary.md` → fall back to `qa-code-reviewer.md`
- `archaeologist-summary.md` → fall back to `archaeologist.md`
- Same pattern for the other QA and deep-dive agents

Summaries are written by `/create-requirements` Stage 3 and `/implement` Phase 4 at ≤10 lines each. Legacy work dirs created before this convention have no summary files — the fallback path handles them transparently. The full file is always available via explicit `Read()` when deeper context is needed.

---

### Resume Requirements Phase

**If requirements phase incomplete:**

```
Resuming: JIRA-123 - User Export Feature

Last stage: Stage 3 - Deep Dive
Completed agents: context-builder, archaeologist

Continuing requirements gathering...
```

**Next steps:**
1. Check which agents have already run (from `context/` directory)
2. Continue with remaining agents
3. Proceed to business-analyst for synthesis

### Resume Proposal Phase

**If proposal phase incomplete (state.json exists):**

```
Resuming: AUTH-001 - User Authentication Proposal

Proposal progress:
- Phase: proposal_drafts
- Iterations: 2
- Latest: proposal2.md

Phases completed:
  ✓ requirements_gathering (business-analyst)
  ✓ brainstorming (Plan agent)
  → proposal_drafts (iteration 2)
  ○ confirm_implementation
  ○ implementation

Continuing proposal development...
```

**Load state:**
```json
{
  "identifier": "AUTH-001",
  "proposal_name": "user-authentication",
  "status": "in_progress",
  "phases": {
    "requirements_gathering": {"status": "completed"},
    "brainstorming": {"status": "completed", "selected_approach": "JWT with refresh tokens"},
    "proposal_drafts": {"status": "in_progress", "current_iteration": 2},
    "confirm_implementation": {"status": "pending"},
    "implementation": {"status": "pending"}
  },
  "iterations": [
    {"version": 1, "file": "proposal1.md", "feedback": "Need more error handling detail"},
    {"version": 2, "file": "proposal2.md", "feedback": null}
  ]
}
```

**Resume actions by phase:**

| Phase | Action |
|-------|--------|
| `requirements_gathering` | Load context/requirements.json, continue with clarifications |
| `brainstorming` | Load context/approaches.json, continue approach selection |
| `proposal_drafts` | Load latest proposal, ask for feedback or proceed |
| `confirm_implementation` | Show latest proposal, ask for implementation approval |
| `implementation` | Continue from src/ directory |

**Trigger `/create-proposal`** with loaded context to continue.

---

### Resume Brainstorm Phase

**If brainstorm phase incomplete (`state.json` exists):**

```
Resuming: {slug} - {title}

Brainstorm progress:
- Status: {status}
- Last phase: {last_completed_phase}
- Selected approach: {selected_approach or "not yet selected"}
- Last updated: {updated_at}

Phases:
  {tick/arrow} exploration
  {tick/arrow} approaches
  {tick/arrow} refinement
  {tick/arrow} quality_guard
  {tick/arrow} work_breakdown
```

**If `status == "promoted"`:**

```
Brainstorm '{slug}' was promoted to requirements: {promoted_to}

Resume the requirements session instead? [y/n]
```

Use AskUserQuestion. On **y**: run `/resume-work {promoted_to}`. On **n**: ask if they want to restart the brainstorm fresh.

**Resume by last incomplete phase (status == "in_progress"):**

| Last completed phase | Resume action |
|---|---|
| `exploration` | Load context/exploration.md and context/business-context.md, continue to Phase 3 (approaches) |
| `approaches` | Load context/approaches.md, present approaches to user, continue with selection |
| `refinement` | Load implementation-picture.md, proceed to Phase 4.5 quality guard |
| `quality_guard` | Load quality-guard output, present verdict, proceed to Phase 5 work breakdown |
| `work_breakdown` | Brainstorm is complete — suggest `/create-requirements --from-brainstorm {slug}` or `/epic` |

---

### Resume Implementation Phase

**If implementation phase incomplete:**

```
Resuming: JIRA-123 - User Export Feature

Implementation progress:
- Chunks completed: 2/3
- Files created: 2
- Files modified: 1
- Tests: Not started

Last chunk: "Add export endpoint"

Continuing implementation...
```

**Load state:**
```json
{
  "identifier": "JIRA-123",
  "status": "in_progress",
  "phases": {
    "implement": {"status": "in_progress", "progress": "2/3 chunks"}
  },
  "plan": {
    "chunks": [
      {"id": 1, "description": "Create UserExporter service", "status": "completed"},
      {"id": 2, "description": "Add export endpoint", "status": "completed"},
      {"id": 3, "description": "Add admin UI button", "status": "pending"}
    ]
  }
}
```

**Re-enter worktree (if applicable):**

If `state.json` contains a `worktree` object with `enabled: true`:

**Single mode** (`worktree.mode == "single"`):
1. Check if worktree directory still exists at `.claude/worktrees/{worktree.name}/`
   - If exists: call `EnterWorktree(name: "{worktree.name}")` to re-attach to the existing worktree
   - If not: call `EnterWorktree(name: "{worktree.name}")` to create fresh
2. Checkout the feature branch: `git checkout feature/{identifier}`

**Multi mode** (`worktree.mode == "multi"`):
1. Check if worktree paths in `state.json.worktree.services` still exist
2. If all exist → reuse them (no action needed, just reference the paths)
3. If any are missing → recreate:
```bash
for svc in {missing_services}; do
  svc_path=$(resolve_service_path "$svc")
  wt_path="{worktree.workspace}/${svc}"
  git -C "$svc_path" worktree add "$wt_path" "feature/{identifier}" 2>/dev/null \
    || git -C "$svc_path" worktree add "$wt_path" -b "feature/{identifier}"
done
```
4. All agent prompts use worktree paths from state

**Resume from last checkpoint:**
1. Show what's been completed
2. Show what remains
3. Continue with next pending chunk

## State Files

All session state is stored in `$WORK_DIR/{identifier}/state.json`. The `type` field in the envelope identifies the session kind.

### Requirements State (`"type": "requirements"`)

```json
{
  "schema_version": 1,
  "type": "requirements",
  "identifier": "JIRA-123",
  "title": "User Export Feature",
  "status": "in_progress",
  "created_at": "2024-01-15T10:00:00Z",
  "updated_at": "2024-01-15T11:30:00Z",

  "branches": {
    "base": "origin/master",
    "feature": "feature/JIRA-123",
    "remote_pushed": true
  },

  "stages": {
    "setup":     {"stage": 1, "status": "completed"},
    "discovery": {"stage": 2, "status": "completed", "agent": "context-builder"},
    "deep_dive": {"stage": 3, "status": "in_progress", "agents_run": ["archaeologist"]},
    "synthesis": {"stage": 4, "status": "pending", "agent": "business-analyst"}
  }
}
```

### Proposal State (`"type": "proposal"`)

```json
{
  "schema_version": 1,
  "type": "proposal",
  "identifier": "AUTH-001",
  "proposal_name": "user-authentication",
  "title": "User Authentication with JWT",
  "status": "in_progress",
  "created_at": "2024-01-15T10:00:00Z",

  "phases": {
    "requirements_gathering": {"status": "completed", "agent": "business-analyst"},
    "brainstorming": {"status": "completed", "agent": "Plan", "selected_approach": "JWT"},
    "proposal_drafts": {"status": "in_progress", "current_iteration": 2},
    "confirm_implementation": {"status": "pending"},
    "implementation": {"status": "pending"}
  },

  "iterations": [
    {"version": 1, "file": "proposal1.md", "feedback": "Need more detail"},
    {"version": 2, "file": "proposal2.md", "feedback": null}
  ]
}
```

### Implementation State (`"type": "implementation"`)

```json
{
  "schema_version": 1,
  "type": "implementation",
  "identifier": "JIRA-123",
  "status": "in_progress",
  "started_at": "2024-01-15T10:00:00Z",
  "phases": {
    "plan": {"status": "completed"},
    "implement": {"status": "in_progress", "chunks_completed": 2, "chunks_total": 3},
    "test": {"status": "pending"},
    "review": {"status": "pending"},
    "qa_gate": {"status": "pending"},
    "pr": {"status": "pending"}
  },
  "plan": {
    "chunks": [
      {"id": 1, "description": "...", "status": "completed", "commit": "abc123"},
      {"id": 2, "description": "...", "status": "completed", "commit": "def456"},
      {"id": 3, "description": "...", "status": "pending"}
    ]
  },
  "implemented_files": [...],
  "commits": ["abc123", "def456"]
}
```

## Error Handling

**No work directory exists:**
```
No incomplete work found in $WORK_DIR/

Start new work with /create-requirements
```

**Invalid identifier:**
```
Work directory not found: $WORK_DIR/{identifier}/

Available work:
- JIRA-123
- JIRA-456
- user-dashboard
```

**Corrupted state:**
```
⚠ State file corrupted or invalid: {file}

Options:
[r] Reset state and restart this phase
[d] Delete this work
[a] Abort
```

## Integration with Other Skills

Dispatch logic based on `state.json` type field:

- `type: "proposal"` → Trigger `/create-proposal` with loaded context
- `type: "implementation"` → Trigger `/implement` to resume
- `type: "requirements"` with `status: "completed"` → Offer `/implement` to start implementation
- `type: "requirements"` with `status: "in_progress"` → Resume requirements gathering
- `type: "brainstorm"` → Resume brainstorm or offer `/create-requirements --from-brainstorm {slug}`
- `type: "epic"` → Resume epic ticket generation
- No `state.json` → Trigger `/create-requirements`
- Works with any identifier format (ticket numbers or slugs)

## Notes

- State persistence enables resuming after interruptions
- Maintains full context across sessions
- Prevents duplicate work
- Tracks progress granularly
- Works with `/create-requirements`, `/create-proposal`, and `/implement` skills

## State Type Dispatch Order

When reading `state.json`, route by `type` field:

1. `"implementation"` — Active implementation in progress
2. `"proposal"` — Proposal workflow in progress
3. `"requirements"` — Requirements gathered (complete) or in progress
4. `"brainstorm"` — Brainstorm in progress or completed
5. `"epic"` — Epic planning in progress
