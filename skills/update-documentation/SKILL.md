---
name: update-documentation
model: sonnet
category: documentation
userInvocable: true
description: Review and update project documentation using an agent team. Inventories docs, identifies gaps and drift, updates technical and API docs in parallel.
argument-hint: [scope|path]
allowed-tools: "Read, Write, Edit, Glob, Grep, Bash(git log:*), Bash(git diff:*), Bash(mkdir:*), Bash(date:*), Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage"
---

# Update Documentation

## Goal

Systematically review and update project documentation using an agent team. Discovers documentation gaps, identifies drift from current code, and updates technical and API docs in parallel.

## Outputs

- Updated documentation files (in-place edits)
- New documentation files (if gaps identified)
- Summary of all changes made

---

## Configuration

Read `.claude/configuration.yml` for execution mode. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `execution_mode` | `"team"` | Documentation phase execution mode (reads `documentation_update` phase override) |

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

# --- Workspace root ---
# The directory where .claude/configuration.yml lives.
# All relative paths anchor here. Works from worktrees, subdirs, anywhere.
WORKSPACE_ROOT=""
if [[ -n "$CONFIG" ]]; then
  WORKSPACE_ROOT="$(cd "$(dirname "$CONFIG")/.." && pwd)"
fi
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$PWD}"

# --- Workspace mode (auto-detect) ---
# "single" = inside a git repo; "multi" = aggregate directory with git repos as subdirs
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

# Config override: if workspace.services defined, use that instead of auto-discovery
if [[ -f "$CONFIG" ]]; then
  _svc_count=$(yq -r '.workspace.services | length // 0' "$CONFIG" 2>/dev/null)
  if [[ "$_svc_count" -gt 0 ]]; then
    WORKSPACE_MODE="multi"
    DISCOVERED_SERVICES=()
  fi
fi

# --- Artifact resolution ---
# Resolves an artifact path from configuration, with fallback defaults.
# Usage: resolve_artifact <artifact_name> <default_subdir> [default_base]
# Returns: absolute path anchored to WORKSPACE_ROOT
resolve_artifact() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  local result_path
  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    result_path="${_BASE}/${_SUB}"
  else
    result_path="${default_base}/${default_subdir}"
  fi

  if [[ "$result_path" != /* ]]; then
    echo "${WORKSPACE_ROOT}/${result_path}"
  else
    echo "$result_path"
  fi
}

# --- Artifact resolution with type ---
# Like resolve_artifact but also returns the storage type (git|directory).
# Usage: IFS='|' read -r PATH TYPE <<< "$(resolve_artifact_typed work work)"
resolve_artifact_typed() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  local result_path _TYPE
  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    _TYPE=$(yq -r ".storage.locations.${_LOC}.type // \"directory\"" "$CONFIG")
    result_path="${_BASE}/${_SUB}"
  else
    result_path="${default_base}/${default_subdir}"
    _TYPE="directory"
  fi

  if [[ "$result_path" != /* ]]; then
    echo "${WORKSPACE_ROOT}/${result_path}|${_TYPE}"
  else
    echo "${result_path}|${_TYPE}"
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

# --- Worktree helpers ---
resolve_worktree_enabled() {
  if [[ -f "$CONFIG" ]]; then
    yq -r '.worktree.enabled // "false"' "$CONFIG"
  else
    echo "false"
  fi
}

resolve_worktree_root() {
  local default=".worktrees"
  local root
  if [[ -f "$CONFIG" ]]; then
    root=$(yq -r ".worktree.root // \"${default}\"" "$CONFIG")
  else
    root="$default"
  fi
  [[ "$root" != /* ]] && echo "${WORKSPACE_ROOT}/${root}" || echo "$root"
}

# --- Service helpers (multi-mode) ---
resolve_services() {
  if [[ -f "$CONFIG" ]]; then
    local _count=$(yq -r '.workspace.services | length // 0' "$CONFIG" 2>/dev/null)
    if [[ "$_count" -gt 0 ]]; then
      yq -r '.workspace.services[].name' "$CONFIG"
      return
    fi
  fi
  printf '%s\n' "${DISCOVERED_SERVICES[@]}"
}

resolve_service_path() {
  local svc="$1"
  if [[ -f "$CONFIG" ]]; then
    local rel
    rel=$(yq -r ".workspace.services[] | select(.name == \"${svc}\") | .path // empty" "$CONFIG" 2>/dev/null)
    if [[ -n "$rel" ]]; then
      [[ "$rel" != /* ]] && echo "${WORKSPACE_ROOT}/${rel}" || echo "$rel"
      return
    fi
  fi
  echo "${WORKSPACE_ROOT}/${svc}"
}
# END_SHARED: resolve-config
DOC_EXEC_MODE=$(resolve_exec_mode documentation_update team)
```

Use `$DOC_EXEC_MODE` to determine team vs sub-agent behavior in Phases 2-4.

---

## Process

### Phase 1: Setup & Scope

**Goal**: Determine what documentation to review and what triggered the update.

#### 1.1 Parse Scope

Check $ARGUMENTS for a scope hint (e.g., a specific path, "api", "readme").

#### 1.2 Get Documentation Scope

Use AskUserQuestion:
```
question: "What documentation should we review and update?"
options:
  - label: "All documentation"
    description: "Full audit of all docs in the project"
  - label: "README + architecture"
    description: "Top-level README and architecture docs"
  - label: "API documentation only"
    description: "API endpoints, OpenAPI specs, API guides"
  - label: "Recently changed areas"
    description: "Docs related to recently modified code"
```

If $ARGUMENTS specified a path, skip this question and use that path as scope.

#### 1.3 Get Update Trigger

Use AskUserQuestion:
```
question: "What triggered this documentation update?"
options:
  - label: "New feature added"
    description: "Code was added that needs documentation"
  - label: "Documentation audit"
    description: "Periodic review for accuracy and completeness"
  - label: "API changes"
    description: "API endpoints were added, changed, or removed"
  - label: "Architecture changes"
    description: "System architecture or patterns changed"
```

#### 1.4 Gather Git Context

Determine recent changes to inform the update:

```bash
# Recent commits
git log --oneline -20

# Files changed recently
git diff --stat HEAD~10
```

Store as `{git_context}`.

#### 1.5 Create Work Directory

```bash
mkdir -p .claude/work/doc-update-$(date +%Y%m%d-%H%M%S)/context
```

Store path as `{work_dir}`.

---

### Phase 2: Discovery

**Goal**: Inventory all documentation and map it to source code.

#### 2.1 Setup Execution

**If `$DOC_EXEC_MODE` = `"team"` (default):**

```
TeamCreate(team_name="doc-update-{timestamp}")
```

Create Task Graph:
```
T1: "Discover and inventory documentation" (no deps)
T2: "Analyze documentation gaps and priorities" (blocked by T1)
T3: "Update all documentation (technical + API)" (blocked by T2)
T4: "Review consistency" (blocked by T3) — handled by lead
```

Use TaskCreate and TaskUpdate to set dependencies.

**If `$DOC_EXEC_MODE` = `"subagent"`:**

Skip TeamCreate. Agents run as independent sub-agent tasks. No task graph needed — orchestrator manages execution order directly.

#### 2.2 Run Context Builder

**Team mode** — Spawn context-builder as a teammate:

```
Task(
  subagent_type="context-builder",
  team_name="doc-update-{timestamp}",
  name="context-builder",
  ...
)
```

**Sub-agent mode** — Run context-builder as independent task:

```
Task(
  subagent_type="context-builder",
  # Team mode only:
  # team_name="doc-update-{timestamp}",
  # name="context-builder",
  prompt="Inventory all documentation in the project.

Scope: {scope}
Recent git changes: {git_context}

Discover and catalog:
1. All .md files with their purpose and last-modified date
2. OpenAPI/Swagger specs (if any)
3. Inline code documentation (JSDoc, PHPDoc, etc.)
4. Map each doc to the source code it describes
5. Identify recently changed code without corresponding doc updates
6. Detect documentation drift (docs describing behavior code no longer implements)

Save output to {work_dir}/context/discovery.json as structured JSON with:
{
  \"docs\": [
    {
      \"path\": \"docs/api.md\",
      \"type\": \"api\",
      \"describes\": [\"src/Controller/UserController.php\"],
      \"last_modified\": \"2025-12-01\",
      \"status\": \"outdated|current|missing|drift\"
    }
  ],
  \"gaps\": [
    {
      \"source_file\": \"src/Service/ExportService.php\",
      \"description\": \"No documentation for export functionality\"
    }
  ],
  \"drift\": [
    {
      \"doc_path\": \"README.md\",
      \"section\": \"API Endpoints\",
      \"issue\": \"Lists /api/users/list but code uses /api/users\"
    }
  ]
}

Mark your task as completed when done."
)
```

**Team mode**: Monitor T1 completion via TaskList.
**Sub-agent mode**: Wait for Task result.

---

### Phase 3: Analysis

**Goal**: Categorize and prioritize documentation updates, then get user approval.

#### 3.1 Run Business Analyst

Once discovery is complete, run business-analyst to analyze findings.

**Team mode** — Spawn as teammate with `team_name` and `name` parameters.
**Sub-agent mode** — Run as independent Task (no `team_name`/`name`).

```
Task(
  subagent_type="business-analyst",
  # Team mode only:
  # team_name="doc-update-{timestamp}",
  # name="business-analyst",
  prompt="Analyze documentation inventory and create an update plan.

Read the discovery inventory: {work_dir}/context/discovery.json
Update trigger: {trigger}
Scope: {scope}

Tasks:
1. Categorize each finding: Outdated / Missing / Inaccurate / Drift / Style-only
2. Prioritize: Critical (misleading users) > Important (outdated) > Minor (formatting/style)
3. For each item, specify:
   - File path to update/create
   - What specifically needs changing
   - Source code files to reference
   - Estimated effort (small/medium/large)

Save analysis to {work_dir}/context/analysis.md in this format:

## HIGH PRIORITY (Critical/Misleading)
1. **{file}** - {description}
   Source: {source_files}
   Action: {what to do}

## MEDIUM PRIORITY (Outdated)
1. **{file}** - {description}

## LOW PRIORITY (Style/Minor)
1. **{file}** - {description}

Mark your task as completed when done."
)
```

**Team mode**: Monitor T2 completion via TaskList.
**Sub-agent mode**: Wait for Task result.

#### 3.2 Present Plan to User

Read the analysis from `{work_dir}/context/analysis.md` and present to user:

Use AskUserQuestion:
```
question: "Documentation Update Plan:

{formatted_analysis_summary}

Which updates should we apply?"
options:
  - label: "All updates"
    description: "Apply all identified updates (high + medium + low priority)"
  - label: "High + Medium only"
    description: "Skip low-priority style/formatting changes"
  - label: "High priority only"
    description: "Only fix critical/misleading documentation"
  - label: "Cancel"
    description: "Don't make any changes"
```

If user selects "Cancel", clean up team and exit.

Store selected scope as `{update_scope}`.

---

### Phase 4: Documentation Updates

**Goal**: Update all documentation (technical and API) using the doc-writer agent.

#### 4.1 Run Doc Writer

Run doc-writer for all documentation updates (technical, API, architecture).

**Team mode** — Spawn as teammate with `team_name` and `name` parameters.
**Sub-agent mode** — Run as independent Task (no `team_name`/`name`).

```
Task(
  subagent_type="doc-writer",
  # Team mode only:
  # team_name="doc-update-{timestamp}",
  # name="doc-writer",
  prompt="Update all documentation based on the approved plan.

Read the analysis: {work_dir}/context/analysis.md
Update scope: {update_scope} (high/medium/low priorities to apply)

For each approved update:
1. Read the current documentation file
2. Read the corresponding source code
3. Make targeted, minimal updates (not full rewrites)
4. Preserve existing structure and tone
5. Update code examples if they reference changed APIs

For API documentation updates:
1. Read the corresponding controllers/routes/handlers
2. Update endpoint documentation (methods, parameters, responses)
3. Update OpenAPI/Swagger specs if they exist
4. Add documentation for new endpoints
5. Ensure error response catalogs are current

Save a summary of changes to {work_dir}/context/doc-writer-changes.md listing:
- Files updated with brief description of changes
- Files created (if any)

Mark your task as completed when done."
)
```

#### 4.2 Monitor Progress

**Team mode**: Monitor doc-writer progress via TaskList until T3 completes.
**Sub-agent mode**: Wait for Task result.

---

### Phase 5: Review & Cleanup

**Goal**: Verify consistency across all updated docs, clean up team.

#### 5.1 Review Consistency

Once doc-writer completes (T3 done):

1. Read the change summary:
   - `{work_dir}/context/doc-writer-changes.md`

2. For each updated file, verify:
   - No contradictions between technical docs and API docs
   - Cross-references are correct (links, file paths)
   - Terminology is consistent

3. If inconsistencies found, make targeted fixes directly.

#### 5.2 Cleanup

**If `$DOC_EXEC_MODE` = `"team"`:**

Send shutdown requests to all teammates:

```
SendMessage(type="shutdown_request", recipient="context-builder", content="Work complete")
SendMessage(type="shutdown_request", recipient="business-analyst", content="Work complete")
SendMessage(type="shutdown_request", recipient="doc-writer", content="Work complete")
```

After all teammates shut down:

```
TeamDelete()
```

**If `$DOC_EXEC_MODE` = `"subagent"`:**

No team cleanup needed — sub-agents terminate automatically after returning results.

#### 5.3 Present Summary

```
Documentation Update Complete

Trigger: {trigger}
Scope: {scope}
Team: doc-update-{timestamp} (created and cleaned up)

Updated Files:
  - {file1} — {brief change description}
  - {file2} — {brief change description}
  ...

Created Files:
  - {new_file1} — {purpose}
  ...

Skipped (out of scope):
  - {skipped items if any}

Review changes: git diff
Commit changes: /commit
```

---

## Error Handling

### Team Creation Fails (team mode only)

Set `DOC_EXEC_MODE = "subagent"` and continue. Agents will run as independent sub-agent tasks instead.

### Teammate Fails

Use AskUserQuestion:
```
question: "Teammate {agent_name} failed: {error_message}. How would you like to proceed?"
options:
  - label: "Retry"
    description: "Respawn this teammate"
  - label: "Skip"
    description: "Continue without this agent's updates"
  - label: "Abort"
    description: "Stop and clean up"
```

**If "Abort"**: Shutdown all teammates, TeamDelete(), exit.

### No Documentation Found

If discovery finds no documentation files:
```
No documentation found in the project.

Would you like to create initial documentation?
- README.md
- Architecture overview
- API documentation
```

### No Updates Needed

If analysis finds all docs are current:
```
Documentation Review Complete

All documentation is up to date. No changes needed.

Reviewed: {count} documentation files
Last updated: {most_recent_date}
```

---

## Quality Checklist

### Phase 1: Setup
- [ ] Scope determined (all, readme, api, path, recent)
- [ ] Trigger identified
- [ ] Git context gathered
- [ ] Work directory created

### Phase 2: Discovery
- [ ] Team created
- [ ] Task graph with correct dependencies
- [ ] Documentation inventory complete
- [ ] Gaps and drift identified

### Phase 3: Analysis
- [ ] Updates categorized and prioritized
- [ ] Plan presented to user
- [ ] User approved scope of updates

### Phase 4: Updates
- [ ] Doc-writer updated all documentation (technical + API)

### Phase 5: Cleanup
- [ ] Consistency verified across updated files
- [ ] All teammates shut down
- [ ] Team deleted
- [ ] Summary presented with file list
