---
name: context
category: implementation
model: sonnet
userInvocable: true
description: Load all available context for a ticket or topic — work state, brainstorms, proposals, requirements KB, product knowledge, and git history — into a single unified summary.
argument-hint: <identifier-or-query>
allowed-tools: "Read, Write, Glob, Grep, Bash(git:*), Task, AskUserQuestion"
---

# Context Aggregator

Arguments: $ARGUMENTS

Aggregate everything the system knows about a topic from all storage sources into a single unified summary.

## Usage

```bash
/context <slug-or-query>    # Aggregate context for a specific topic
/context                    # List available context across all sources
```

## When to Use

- Starting a conversation and want to load everything known about a topic
- Before resuming work — understand what exists before deciding next steps
- Exploring what past work is available across all sources
- Building understanding of a topic without modifying anything

**This is primarily a read-only skill.** Phase 3 (Create Context) can optionally write notes and update manifests when the user opts in.

---

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults.

### Resolve All 6 Artifact Paths

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

For any location with `type: git`, sync before reading:

```bash
for _var_pair in "WORK_DIR:WORK_TYPE" "BRAINSTORM_DIR:BRAIN_TYPE" "PROPOSALS_DIR:PROP_TYPE" \
                 "REFACTOR_DIR:REFAC_TYPE" "REQUIREMENTS_DIR:REQ_TYPE" "PRODUCT_DIR:PROD_TYPE"; do
  _dir_var="${_var_pair%%:*}"; _type_var="${_var_pair##*:}"
  if [[ "${!_type_var}" == "git" ]]; then
    _base="$(dirname "${!_dir_var}")"
    cd "$_base" && git pull --quiet 2>/dev/null
  fi
done
```

---

## Workflow: `/context <slug>`

When a slug/query argument is provided, search all sources for matches.

### Phase 1: Exact Match (Fast, Manifest-First)

**Prefer manifests over directory scans.** For each artifact type, check if `manifest.json` exists and search it first. Fall back to directory existence check only if manifest is missing.

```bash
# For each artifact type, try manifest first, then directory:
# Work:
if [[ -f "${WORK_DIR}/manifest.json" ]]; then
  # Search items array for matching identifier
  jq -e ".items[] | select(.identifier == \"${slug}\")" "${WORK_DIR}/manifest.json"
else
  [[ -d "${WORK_DIR}/${slug}" ]]
fi

# Brainstorms (stored in WORK_DIR since brainstorm writes to work dir):
# Brainstorm sessions have type="brainstorm" in the work manifest.
# Also check legacy BRAINSTORM_DIR for sessions created before this change.
if [[ -f "${WORK_DIR}/manifest.json" ]]; then
  jq -e ".items[] | select(.identifier == \"${slug}\" and .type == \"brainstorm\")" "${WORK_DIR}/manifest.json"
elif [[ -d "${WORK_DIR}/${slug}" ]] && [[ -f "${WORK_DIR}/${slug}/state.json" ]]; then
  echo "found"
elif [[ -f "${BRAINSTORM_DIR}/manifest.json" ]]; then
  jq -e ".items[] | select(.slug == \"${slug}\")" "${BRAINSTORM_DIR}/manifest.json"
else
  [[ -d "${BRAINSTORM_DIR}/${slug}" ]]
fi

# Proposals:
if [[ -f "${PROPOSALS_DIR}/manifest.json" ]]; then
  jq -e ".items[] | select(.name == \"${slug}\")" "${PROPOSALS_DIR}/manifest.json"
else
  [[ -d "${PROPOSALS_DIR}/${slug}" ]]
fi

# Refactoring:
if [[ -f "${REFACTOR_DIR}/manifest.json" ]]; then
  jq -e ".items[] | select(.session_name == \"${slug}\")" "${REFACTOR_DIR}/manifest.json"
else
  [[ -d "${REFACTOR_DIR}/${slug}" ]]
fi

# Git: check for branches matching slug
git branch -a --list "*${slug}*"
```

**Manifest advantage:** When a manifest match is found, you already have the item's metadata (status, title, progress, etc.) without reading individual state files.

For each match found, read and summarize the contents:

#### Work State
If `${WORK_DIR}/${slug}/` exists:
- Read `state.json` (check `type` field to understand session kind)
- Read files in `context/` subdirectory (agent outputs)
- Summarize: identifier, current phase, status, last updated, key files
- **If `state.json` has a non-empty `updates` array:** surface all entries as a **Session Updates** section (timestamp + note, newest last). These are manually recorded annotations from `/update-context`.
- **If `state.json` has `brainstorm.promoted_from`:** also load the linked brainstorm as prior art:
  - Read `$WORK_DIR/{promoted_from}/state.json`
  - Read `$WORK_DIR/{promoted_from}/context/approaches.md`, `context/exploration.md`, `implementation-picture.md` (if exist)
  - Surface as "Prior art: Brainstorm '{promoted_from}'" section in context output

#### Brainstorms
If `${WORK_DIR}/${slug}/` exists and contains `state.json`:
- Read `state.json` for status, selected approach, phase completion
- Read `context/approaches.md`, `context/exploration.md`, `context/architecture-validation.md` (if exist)
- Read `implementation-picture.md`, `work-breakdown.md` (if exist)
- Summarize: selected approach, alternatives considered, key decisions, completion status

Legacy: If `${BRAINSTORM_DIR}/${slug}/` exists (pre-migration sessions):
- Read all `.md` files in the directory
- Summarize: selected approach, alternatives considered, key decisions

#### Proposals
If `${PROPOSALS_DIR}/${slug}/` exists:
- Read proposal files (`.md`)
- Summarize: proposal status, key points, iterations

If `${PROPOSALS_DIR}/${slug}` is a file (not directory):
- Read the file directly
- Summarize: proposal content

#### Refactoring Sessions
If `${REFACTOR_DIR}/${slug}/` exists:
- Read session state files
- Summarize: refactoring scope, progress, files affected

#### Git History
For any branches matching `*${slug}*`:
- List matching branch names
- Show recent commits on those branches (last 5 per branch):
  ```bash
  git log --oneline -5 "${branch}"
  ```

### Phase 2: Fuzzy Fallback

If Phase 1 found **no exact matches**, run a broader search:

#### 2.1 Local Sources (Direct)

Search all local artifact directories in parallel:

```bash
# Glob for partial directory name matches
# In WORK_DIR, BRAINSTORM_DIR, PROPOSALS_DIR, REFACTOR_DIR:
# Look for directories containing the slug as substring

# Grep for slug in file contents across all sources
# Search .json and .md files for the query string
```

Use Glob and Grep tools to search each resolved path for:
- Directory names containing the slug
- File contents mentioning the slug

#### 2.2 Requirements KB (Agent)

**Only if requirements artifact is configured** (i.e., the resolved path exists and is not just the default empty local path):

```
Task(archivist, "Search requirements repository for: ${slug}

Configuration:
  Path: ${REQUIREMENTS_DIR}
  Type: ${REQ_TYPE}

Search for keyword matches. Return top 3 results with:
- ID, title, relevance score
- Brief summary
- Tags and components
")
```

#### 2.3 Product Knowledge (Agent)

**Only if product-knowledge artifact is configured** (i.e., the resolved path exists and is not just the default empty local path):

```
Task(product-expert, "Search product knowledge base for: ${slug}

Configuration:
  Path: ${PRODUCT_DIR}
  Type: ${PROD_TYPE}

Find related product documentation. Return:
- Document titles and paths
- Relevant excerpts
- How they relate to the query
")
```

**Run 2.2 and 2.3 in parallel** (single message with multiple Task calls).

#### 2.4 Git Log Search

```bash
git log --all --oneline --grep="${slug}" -10
```

### Phase 3: Create Context (when nothing found)

If all phases return no matches for the slug AND the user's phrasing implies creation intent (e.g., "create context for X", "build context for X"):

1. Inform: "No existing context found for `{slug}`."
2. Ask via AskUserQuestion: "Would you like me to research the codebase and create a new context artifact?"
   - Options: "Yes, research and create" / "No, just searching"
3. If yes:
   - Launch Explore agent for comprehensive codebase research on `{slug}`
   - Launch archivist (if configured) and product-expert (if configured) in parallel
   - Aggregate findings into `${WORK_DIR}/{slug}/notes.md`
   - Update manifest
   - Report: "Context created and saved to `${WORK_DIR}/{slug}/notes.md`"

### Compile Results

After phases complete, compile all findings into the output format.

---

## Workflow: `/context` (No Argument)

When invoked without arguments, list what context is available across all sources.

### Step 1: Scan All Sources (Manifest-First)

**Prefer manifests over directory scans.** For each artifact type, check if `manifest.json` exists using the Read tool. If it exists, parse it for structured data. If no manifest is found, fall back to the Glob tool to list directory contents.

**If manifest exists** — use Read to load it, then extract items:

| Artifact | Manifest Path | Fields |
|----------|--------------|--------|
| Work | `${WORK_DIR}/manifest.json` | `.items[] \| .identifier, .title, .status, .type` |
| Brainstorms | `${BRAINSTORM_DIR}/manifest.json` | `.items[] \| .slug, .title, .selected_approach` |
| Proposals | `${PROPOSALS_DIR}/manifest.json` | `.items[] \| .name, .title, .status` |
| Refactoring | `${REFACTOR_DIR}/manifest.json` | `.items[] \| .session_name, .title, .status` |

**If no manifest** — use Glob to list directory contents:

| Artifact | Glob call |
|----------|-----------|
| Work | `Glob("*", path="${WORK_DIR}/")` |
| Brainstorms | `Glob("*", path="${BRAINSTORM_DIR}/")` |
| Proposals | `Glob("*", path="${PROPOSALS_DIR}/")` |
| Refactoring | `Glob("*", path="${REFACTOR_DIR}/")` |

Run all four artifact scans in parallel where possible.

**Manifest advantage:** When manifests are available, the inventory table can include titles and statuses without reading individual state files.

### Step 2: Build Inventory

For each unique slug found across any source, note which sources contain it:

```
Available Context
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Slug               Title                   Work  Brainstorm  Proposal  Refactoring  Status
────────────────────────────────────────────────────────────────────────────────────────────
JIRA-123           User Export Feature       ✓                 ✓                    in_progress
user-auth          User Authentication       ✓       ✓                             completed
sso-integration    SSO with Azure AD                           ✓                    draft
api-refactor       API Controller Cleanup                                 ✓         paused

4 topics found across local sources.

Load details: /context <slug>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 3: Offer Selection

Use AskUserQuestion to let the user pick a slug to load:

```
Select a topic to load context for, or enter a search query:
```

Options: list the slugs found, plus an "Other" option for free-text search.

If user selects a slug, proceed with the `/context <slug>` workflow above.

---

## Output Format

Present results with sections only for sources that returned content. Omit empty sections entirely.

```
Context: {slug}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Work State
Status: {phase} ({status})
Last updated: {timestamp}
Branch: {feature_branch} → {base_branch}

Key files:
- state.json
- context/discovery.json
- context/archaeologist.md

Summary: {brief description of current state}

## Brainstorm
Selected approach: {approach name}
Alternatives considered: {count}

Key decisions:
- {decision 1}
- {decision 2}

Key files:
- {file list}

## Proposal
Status: {draft|final|implemented}
Iterations: {count}

Key points:
- {point 1}
- {point 2}

Key files:
- {file list}

## Refactoring Session
Scope: {description}
Progress: {status}

Files affected:
- {file list}

## Requirements KB
{Matched requirements from archivist, if any}

## Product Knowledge
{Related product docs from product-expert, if any}

## Git History
Branches:
- feature/{slug} (last commit: {date})

Recent commits:
- {hash} {message} ({date})
- {hash} {message} ({date})

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Handling

### No argument, no local context found

```
No context found across any source.

Available actions:
- /context <query>                    Search by keyword
- /create-requirements      Start new work
- /brainstorm                         Start brainstorming
```

### Slug not found anywhere

```
No context found for: "{slug}"

Searched:
  Work state:     {WORK_DIR} — not found
  Brainstorms:    {BRAINSTORM_DIR} — not found
  Proposals:      {PROPOSALS_DIR} — not found
  Refactoring:    {REFACTOR_DIR} — not found
  Requirements:   {status: searched/not configured}
  Product KB:     {status: searched/not configured}
  Git history:    No matching branches or commits

Suggestions:
- Try a broader query: /context auth (instead of user-authentication)
- Check spelling
- List available context: /context
```

### Configuration missing

Not an error — skill works without configuration by falling back to defaults:
- `WORK_DIR` → `.claude/work`
- `BRAINSTORM_DIR` → `.claude/brainstorm`
- `PROPOSALS_DIR` → `.claude/proposals` (note: no default external path)
- `REFACTOR_DIR` → `.claude/work/refactoring-sessions`
- Requirements KB and Product Knowledge → skipped (not configured)

---

## Agent Delegation Summary

| Source | Agent | When |
|--------|-------|------|
| Work state | Direct (Read, Glob) | Always — local file reads |
| Brainstorms | Direct (Read, Glob) | Always — local file reads |
| Proposals | Direct (Read, Glob) | Always — local file reads |
| Refactoring | Direct (Read, Glob) | Always — local file reads |
| Requirements KB | `archivist` | Only during fuzzy search, only if configured |
| Product Knowledge | `product-expert` | Only during fuzzy search, only if configured |
| Git history | Direct (Bash git) | Always — git branch/log commands |

Both agent searches run **in parallel** when triggered.

---

## Examples

### Example 1: Full context for a ticket

```bash
/context JIRA-123
```

```
Context: JIRA-123
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Work State
Status: implement (in_progress)
Last updated: 2026-02-09T14:30:00Z
Branch: feature/JIRA-123 → origin/master
Chunks: 2/3 completed

Key files:
- state.json  (type: implementation)
- context/discovery.json
- context/archaeologist.md

Summary: User export feature. Requirements complete,
implementation 2/3 done. Next chunk: Add admin UI button.

## Brainstorm
Selected approach: Queue-based async export
Alternatives considered: 3

Key decisions:
- Use PhpSpreadsheet for Excel generation
- Async processing via queue jobs
- S3 storage with 7-day retention

Key files:
- approach-comparison.md
- selected-approach.md

## Git History
Branches:
- feature/JIRA-123 (last commit: 2h ago)

Recent commits:
- def456 [JIRA-123] feat(export): add export endpoint
- abc123 [JIRA-123] feat(export): create UserExporter service

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Example 2: Search across sources

```bash
/context authentication
```

Finds partial matches in work directories, brainstorms, proposals,
and searches requirements KB and product docs for "authentication".

### Example 3: List all available context

```bash
/context
```

Lists all slugs found across local sources with which sources
contain data for each one.
