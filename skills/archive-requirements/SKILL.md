---
name: archive-requirements
model: sonnet
category: requirements-kb
description: Manually archive completed requirements to team knowledge base
argument-hint: [identifier]
userInvocable: true
allowed-tools: Read, Bash, Task, AskUserQuestion
---

# Archive Requirements

Manually archive completed requirements to the team's requirements knowledge base.

## Purpose

Use this skill to archive requirements that weren't automatically archived during `/implement`, or to re-archive requirements after updates.

## When to Use

- Implementation completed but archival was skipped
- Archival failed during `/implement` and needs retry
- Requirements updated and need to be re-archived
- Manual archival for legacy work not tracked in `$WORK_DIR/`

## Arguments

```bash
/archive-requirements [identifier]
```

**identifier** (optional): Work identifier (e.g., JIRA-123)
- If provided: Archive that specific work
- If omitted: Scan `$WORK_DIR/` and present options

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work state and context |
| `storage.artifacts.requirements` | `location: local, subdir: requirements` | Requirements knowledge base (archive target) |

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

Use `$WORK_DIR` instead of hardcoded `.claude/work` throughout this workflow.

**Important:** All path references in this skill MUST use `$WORK_DIR`. Never use hardcoded `.claude/work` paths.

---

## Process

### Step 1: Identify Work to Archive

**If identifier provided:**
```bash
if [ ! -d "$WORK_DIR/${identifier}" ]; then
  echo "❌ Work directory not found: $WORK_DIR/${identifier}"
  echo ""
  echo "Available work:"
  ls -1 $WORK_DIR/
  exit 1
fi
```

**If no identifier provided:**

Scan for completed work:
```bash
# Find work directories with completed requirements
for dir in $WORK_DIR/*/; do
  identifier=$(basename "$dir")

  if [ -f "$dir/state.json" ]; then
    status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$dir/state.json" | cut -d'"' -f4)

    if [ "$status" = "completed" ]; then
      echo "[$identifier] - Ready to archive"
    fi
  fi
done
```

Use AskUserQuestion to present options:
```
Select work to archive:

[1] JIRA-123 - User Export Feature (completed 2 hours ago)
[2] JIRA-456 - SSO Integration (completed yesterday)
[3] PROJ-789 - API Refactor (completed last week)

Select [1-3]:
```

### Step 2: Validate Work State

Read state files:
```bash
Read("$WORK_DIR/${identifier}/state.json")
Read("$WORK_DIR/${identifier}/context/")
```

**Check:**
- Requirements phase completed
- Implementation phase completed (if exists)
- Has context files (discovery, archaeologist, business-analyst, etc.)

**If incomplete:**
```
⚠ Warning: Work appears incomplete

Requirements: completed ✓
Implementation: in progress (2/3 chunks)

Archive anyway? [y/n]
```

### Step 3: Resolve Requirements Storage

Resolve the requirements artifact path using the config functions loaded in the Configuration section above:

```bash
IFS='|' read -r REPO _TYPE <<< "$(resolve_artifact_typed requirements requirements)"
_BASE="$(dirname "$REPO")"
```

If the storage location type is `git`, sync before reading:
```bash
if [[ "$_TYPE" == "git" ]]; then
  cd "$_BASE" && git pull
fi
```

**If not configured:**
```
Requirements storage not configured

To set up:
1. See: ~/.claude/templates/requirements-repo/README.md
2. Add requirements artifact to .claude/configuration.yml:

storage:
  locations:
    team-knowledge:
      type: git
      path: /path/to/team-knowledge
  artifacts:
    requirements: { location: team-knowledge, subdir: requirements }

Cannot archive until configured.
```

### Step 4: Delegate to Archivist

Use Task tool with `subagent_type: "archivist"`:

```
Task(archivist, "Archive requirements for ${identifier}

Work directory: $WORK_DIR/${identifier}/
Configuration: ${requirements_config}

Tasks:
1. Sync requirements repository
2. Read all state and context files
3. Extract metadata from git commits and code changes
4. Generate human-readable requirements.md
5. Copy all files to requirements repository
6. Update searchable index.json
7. Commit and push to repository

Provide detailed success report with archive location.
")
```

### Step 5: Report Results

**Success:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Requirements Archived Successfully
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Identifier: ${identifier}
Title: ${feature_title}

Archived to: ${repo_path}/${identifier}/
- metadata.json (searchable)
- requirements.md (human-readable)
- state.json (session state)
- context/ (all agent outputs)

Index updated:
- Total tickets: 25 → 26
- Tags: ${extracted_tags}
- Components: ${extracted_components}

Changes committed and pushed to: origin/main

This work is now discoverable by the archivist agent
when searching for similar past implementations.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Failure:**
```
❌ Archival Failed

Error: ${error_message}

Possible causes:
- Requirements repository not accessible
- Git conflicts in index.json
- Missing required context files
- Insufficient permissions

Troubleshooting:
1. Check repository path: ${repo_path}
2. Ensure repository is up to date: git pull
3. Verify context files exist in $WORK_DIR/${identifier}/context/
4. Check git status in requirements repository

Retry: /archive-requirements ${identifier}
```

## Examples

### Example 1: Archive Specific Work

```bash
/archive-requirements JIRA-123
```

Archives the completed work for JIRA-123.

### Example 2: Select from Available Work

```bash
/archive-requirements
```

Scans `$WORK_DIR/` and presents a list of completed work to choose from.

### Example 3: Re-archive After Updates

```bash
# After updating requirements
/archive-requirements JIRA-123

# Archivist will update existing archive
```

## Error Handling

### Work Not Found

```
❌ Work directory not found: $WORK_DIR/JIRA-123

Available work:
- JIRA-456
- PROJ-789
- AUTH-001

Did you mean one of these?
```

### Repository Not Configured

```
❌ Requirements repository not configured

Setup guide: ~/.claude/templates/requirements-repo/README.md

Cannot proceed until configured.
```

### Incomplete Work

```
⚠ Work appears incomplete:
- Requirements: ✓ completed
- Implementation: ✗ not started

This will archive requirements only (no implementation).

Continue? [y/n]
```

### Git Conflicts

```
❌ Archival failed: Git conflict in index.json

Another developer may have archived simultaneously.

To resolve:
1. cd ${repo_path}
2. git pull --rebase
3. Resolve conflicts in index.json
4. git rebase --continue
5. Retry: /archive-requirements ${identifier}
```

## Notes

- **Idempotent**: Re-archiving updates existing archive
- **Non-destructive**: Original work in `$WORK_DIR/` is preserved
- **Atomic**: Index updated in single commit with archive
- **Concurrent-safe**: Uses git for synchronization

## See Also

- `/search-requirements <query>` - Search archived requirements
- `/load-requirements <id>` - Load specific archived requirement
- `/rebuild-requirements-index` - Rebuild corrupted index
