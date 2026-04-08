---
name: rebuild-index
model: haiku
category: project-setup
description: Rebuild manifest.json for any artifact storage type. Scans directories and regenerates from scratch.
argument-hint: <artifact-type|all>
userInvocable: true
allowed-tools: Read, Write, Bash, Glob, Grep, Task, AskUserQuestion
---

# Rebuild Index

Rebuild `manifest.json` for one or all artifact storage types by scanning directories and extracting metadata from state files.

## Usage

```bash
/rebuild-index work              # Rebuild work manifest
/rebuild-index brainstorms       # Rebuild brainstorms manifest
/rebuild-index proposals         # Rebuild proposals manifest
/rebuild-index refactoring       # Rebuild refactoring manifest
/rebuild-index product-knowledge # Rebuild product knowledge manifest
/rebuild-index requirements      # Delegates to /rebuild-requirements-index
/rebuild-index all               # Rebuild all manifests
```

## When to Use

- Manifest missing or corrupted
- After manual changes to artifact directories
- After cleanup or archival operations
- Periodic maintenance
- As a safety net when manifests fall out of sync

## Context

Arguments: $ARGUMENTS

---

## Configuration

Read `.claude/configuration.yml` for all artifact paths:

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
IFS='|' read -r WORK_DIR WORK_TYPE         <<< "$(resolve_artifact_typed work work)"
IFS='|' read -r BRAINSTORM_DIR BRAIN_TYPE  <<< "$(resolve_artifact_typed brainstorms brainstorm)"
IFS='|' read -r PROPOSALS_DIR PROP_TYPE    <<< "$(resolve_artifact_typed proposals proposals)"
IFS='|' read -r REFACTOR_DIR REFAC_TYPE    <<< "$(resolve_artifact_typed refactoring work/refactoring-sessions)"
IFS='|' read -r REQUIREMENTS_DIR REQ_TYPE  <<< "$(resolve_artifact_typed requirements requirements)"
IFS='|' read -r PRODUCT_DIR PROD_TYPE      <<< "$(resolve_artifact_typed product-knowledge .)"
```

---

## Process

### Step 1: Parse Argument

Parse `$ARGUMENTS` to determine which artifact type(s) to rebuild.

**Valid arguments:** `work`, `brainstorms`, `proposals`, `refactoring`, `product-knowledge`, `requirements`, `all`

**If no argument or invalid argument:**
```
Error: Artifact type required.

Usage:
  /rebuild-index work
  /rebuild-index brainstorms
  /rebuild-index proposals
  /rebuild-index refactoring
  /rebuild-index product-knowledge
  /rebuild-index requirements
  /rebuild-index all

See docs/manifest-system.md for manifest schema details.
```

### Step 2: Sync Git Locations

For any artifact location with `type: git`, sync before scanning:

```bash
if [[ "$_TYPE" == "git" ]]; then
  _LOC=$(yq -r ".storage.artifacts.${artifact}.location" "$CONFIG")
  _BASE=$(yq -r ".storage.locations.${_LOC}.path" "$CONFIG")
  cd "$_BASE" && git pull --quiet
fi
```

### Step 3: Execute Rebuild(s)

For `all`, run each artifact type sequentially (or report results for each). For a single type, run just that one.

**Special cases:**
- `requirements` → Delegate to `/rebuild-requirements-index` skill
- `product-knowledge` → Delegate to `product-expert` agent

---

## Rebuild: Work

**Path:** `$WORK_DIR`

1. Back up existing `${WORK_DIR}/manifest.json` to `manifest.json.backup.{TIMESTAMP}`
2. Scan subdirectories of `$WORK_DIR`
3. For each subdirectory, read `state.json` and check the `type` field to detect work type:
   - `"implementation"` → type: `implementation`
   - `"proposal"` → type: `proposal`
   - `"epic"` → type: `epic`
   - `"requirements"` → type: `requirements`
4. Extract metadata from the state file:
   - `identifier`: from state file or directory name
   - `title`: from state file
   - `status`: from state file
   - `created_at`, `updated_at`: from state file
   - `current_phase`: derive from state file status fields
   - `progress`: derive from chunks or stages
   - `branch`: from state file branches section
   - `tags`: empty array (not tracked in state files)
5. Build manifest with `artifact_type: "work"`
6. Write to `${WORK_DIR}/manifest.json`

**Skip directories:** `manifest.json`, `manifest.json.backup.*`, any file (non-directory)

---

## Rebuild: Brainstorms

**Path:** `$BRAINSTORM_DIR`

1. Back up existing manifest
2. Scan subdirectories of `$BRAINSTORM_DIR`
3. For each subdirectory:
   - `slug`: directory name
   - `title`: extract from first heading in `brainstorm-summary.md` or `approaches.md`, or use slug
   - `created_at`: earliest file modification time in directory
   - `selected_approach`: extract from `brainstorm-summary.md` if exists
   - `alternatives_count`: count approach sections in `approaches.md` if exists
   - `tags`: empty array
4. Build manifest with `artifact_type: "brainstorms"`
5. Write to `${BRAINSTORM_DIR}/manifest.json`

---

## Rebuild: Proposals

**Path:** `$PROPOSALS_DIR`

1. Back up existing manifest
2. Scan subdirectories of `$PROPOSALS_DIR`
3. For each subdirectory:
   - `name`: directory name
   - `title`: extract from first heading in `proposal-final.md` or latest `proposal*.md`
   - `status`: `implemented` if `src/` exists, `final` if `proposal-final.md` exists, else `draft`
   - `created_at`: earliest file modification time
   - `updated_at`: latest file modification time
   - `iterations`: count of `proposal*.md` files
   - `tags`: empty array
4. Build manifest with `artifact_type: "proposals"`
5. Write to `${PROPOSALS_DIR}/manifest.json`

---

## Rebuild: Refactoring

**Path:** `$REFACTOR_DIR`

1. Back up existing manifest
2. Scan subdirectories of `$REFACTOR_DIR`
3. For each subdirectory with `session-state.json`:
   - `session_name`: from state file or directory name
   - `title`: from `target.scope` in state file, or directory name
   - `status`: from state file
   - `created_at`, `updated_at`: from state file
   - `files_affected`: count from `target.files` array in state file
   - `progress`: derive from `progress.completed`/`progress.completed + progress.pending` in state file
   - `tags`: empty array
4. Build manifest with `artifact_type: "refactoring"`
5. Write to `${REFACTOR_DIR}/manifest.json`

---

## Rebuild: Product Knowledge

**Path:** `$PRODUCT_DIR`

Delegate to `product-expert` agent:

```
Task(product-expert, "Build a fresh manifest.json for the product knowledge base.

Knowledge base path: ${PRODUCT_DIR}

Process:
1. Scan all .md files recursively in the knowledge base
2. For each file:
   - Extract title from first heading (or use filename)
   - Determine category from parent directory name
   - Extract tags from content (look for tags/keywords sections, or infer from headings)
   - Create a one-line summary from the first paragraph
3. Build categories and tags frequency maps
4. Write manifest.json to ${PRODUCT_DIR}/manifest.json

Use the manifest schema from docs/manifest-system.md (artifact_type: product-knowledge).
Include the extra 'categories' and 'tags' top-level fields.
")
```

---

## Rebuild: Requirements

Delegate entirely to the existing `/rebuild-requirements-index` skill:

```
The requirements knowledge base uses its own index.json format with richer metadata.
Delegating to /rebuild-requirements-index...
```

Trigger the `/rebuild-requirements-index` skill.

---

## Step 4: Report Results

For each artifact type rebuilt, report:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Index Rebuilt: {artifact_type}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Path: {artifact_dir}
Items found: {count}
Backup: manifest.json.backup.{timestamp}

Items:
  - {item_1_key}: {title} ({status})
  - {item_2_key}: {title} ({status})
  ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

For `all`, show a summary table:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Index Rebuild Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Artifact           Items  Status
──────────────────────────────────────────────
Work                  3   Rebuilt
Brainstorms           1   Rebuilt
Proposals             2   Rebuilt
Refactoring           0   Empty (no sessions)
Product Knowledge     8   Rebuilt (via agent)
Requirements          5   Rebuilt (via /rebuild-requirements-index)

Total: 19 items indexed across 6 artifact types.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Handling

**Artifact directory doesn't exist:**
```
⚠ {artifact_type}: Directory not found: {path}
  Skipping — no items to index.
```

**No items found:**
```
{artifact_type}: 0 items found in {path}
  Created empty manifest.json.
```

**Corrupt existing manifest:**
```
⚠ {artifact_type}: Existing manifest.json is invalid JSON
  Backed up to: manifest.json.corrupt.{timestamp}
  Building fresh manifest from directory scan.
```

**Agent delegation failure (product-knowledge):**
```
⚠ product-knowledge: Agent failed to build manifest
  Error: {error_message}

  Options:
  [r] Retry agent
  [s] Skip product-knowledge
  [a] Abort
```

Use AskUserQuestion for selection.

---

## See Also

- [Manifest System Reference](../../docs/manifest-system.md) — Schema details and update patterns
- `/rebuild-requirements-index` — Requirements-specific index rebuild
- `/load-context` — Uses manifests for fast listing and lookup
- `/resume-work` — Uses work manifest to find incomplete work
