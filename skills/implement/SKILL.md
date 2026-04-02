---
name: implement
category: implementation
model: opus
userInvocable: true
description: Implement a feature from saved requirements. Chunk-based commits, parallel QA (tests + review + security), and PR creation. Resumes interrupted sessions from saved state.
argument-hint: [--light] [identifier]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage, EnterWorktree, ExitWorktree
---

# Implement Based on Requirements

## Purpose

End-to-end implementation skill that:
1. Detects incomplete work in `$WORK_DIR/` for smart resume
2. Understands requirements from multiple input formats
3. Explores codebase and plans implementation
4. Implements changes with state persistence
5. Commits each chunk separately using `git-operator`
6. Ensures test coverage for new code
7. Reviews and auto-fixes issues
8. Enforces quality gate with auto-fix feedback loop before PR
9. Creates PR with target branch confirmation
10. Offers `/pr-review` after PR creation

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work state and context |
| `execution_mode` | `"team"` | QA phase execution mode (reads `qa_review` phase override) |

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
WORK_DIR=$(resolve_artifact work work)
QA_EXEC_MODE=$(resolve_exec_mode qa_review team)
```

Use `$WORK_DIR` instead of hardcoded `.claude/work` throughout this workflow.
Use `$QA_EXEC_MODE` to determine team vs sub-agent behavior in Phase 4 (QA).

**Important:** All path references in this skill MUST use `$WORK_DIR`. Never use hardcoded `.claude/work/` paths.

---

## Write Safety

Agents working in parallel MUST NOT write to the same file. Follow these conventions:

- **QA agent outputs**: Each QA agent writes ONLY to `$WORK_DIR/{identifier}/context/qa-{agent-role}.md` (e.g., `qa-code-reviewer.md`, `qa-security-auditor.md`, `qa-quality-guard.md`). Agents NEVER write to another agent's output file.
- **State files**: Only the skill lead writes to `state.json`.
- **Manifest**: Only the skill lead writes to `${WORK_DIR}/manifest.json`.
- **QA gate report**: Only the skill lead writes to `$WORK_DIR/{identifier}/qa-gate-report.md` after aggregating all agent outputs.
- **Source code**: During Phase 3 (implementation), only the lead writes code. During Phase 4.7 (auto-fix), only the refactorer agent writes fixes, sequentially (not in parallel).

See `~/.claude/shared/write-safety.md` for the full conventions.

---

## Lightweight Mode

If `$ARGUMENTS` begins with `--light`, strip the flag and enable lightweight mode:

- Output to user: "Lightweight mode enabled: execution agents use Sonnet. Quality gates unchanged."
- **Explore agent**: unchanged (already sonnet)
- **Plan agent**: spawn with model **sonnet** instead of opus
- **architect**: spawn with model **sonnet** instead of opus
- **code-reviewer**: unchanged (ALWAYS Opus — quality gate)
- **security-auditor**: unchanged (ALWAYS Opus — quality gate)
- **quality-guard**: unchanged (ALWAYS Opus — quality gate)
- **test-writer**: unchanged (already sonnet)
- **test-fixer**: unchanged (already sonnet)
- **git-operator**: unchanged (already sonnet)
- All orchestration flow, quality gates, and deadlock protocols remain identical

This reduces cost for the planning/architecture phases while maintaining full-strength quality assurance.

---

## Input Formats

This skill accepts requirements in multiple formats:

1. **Work directory**: `/implement $WORK_DIR/JIRA-123/` (from requirements phase)
2. **Requirements file**: `/implement docs/tickets/TICKET-123.md`
3. **No argument**: Scans `$WORK_DIR/` for incomplete work
4. **Dry run**: `/implement --dry-run [source]` (shows plan without executing)

---

## Workflow

### Phase 0: Smart Detection

**Goal**: Detect incomplete work or load requirements.

#### 0.1 Check for Incomplete Work

If no arguments provided, scan for incomplete implementations:

```bash
# Check for work directories with incomplete implementation
ls -1 $WORK_DIR/*/state.json 2>/dev/null
```

**If incomplete work found:**

```
Found incomplete implementation:

[1] JIRA-123 - User Export Feature
    Progress: 2/3 chunks complete
    Last updated: 2 hours ago

[2] JIRA-456 - SSO Integration
    Progress: Planning complete, not started
    Last updated: 1 day ago

[3] Start fresh (provide requirements)

Select [1-3]:
```

Use AskUserQuestion to get selection.

#### 0.2 Load Work Context

**If work directory specified or selected:**

**VALIDATION** (required):
```bash
# CRITICAL: Verify requirements state file exists
if [[ ! -f "$WORK_DIR/{identifier}/state.json" ]]; then
  echo "ERROR: No requirements found for {identifier}"
  echo "Expected: $WORK_DIR/{identifier}/state.json"
  echo ""
  echo "Please run /create-requirements first to generate requirements."
  exit 1
fi

# Validate requirements state file is valid JSON
if ! jq empty "$WORK_DIR/{identifier}/state.json" 2>/dev/null; then
  echo "ERROR: Corrupted requirements state file"
  echo "File: $WORK_DIR/{identifier}/state.json"
  echo ""
  echo "The state file is not valid JSON. It may have been corrupted."
  echo "You may need to regenerate requirements."
  exit 1
fi

# Validate requirements phase completed
req_status=$(jq -r '.status' "$WORK_DIR/{identifier}/state.json")
if [[ "$req_status" != "completed" ]]; then
  echo "WARNING: Requirements phase status is: $req_status"
  echo "Expected: completed"
  echo ""
  echo "The requirements may be incomplete. Continue anyway? [y/n]"
  # Use AskUserQuestion or read input
fi

echo "✓ Requirements state validated"
```

```bash
# Load and parse state files
identifier=$(jq -r '.identifier' "$WORK_DIR/{identifier}/state.json")
base_branch=$(jq -r '.branches.base' "$WORK_DIR/{identifier}/state.json")
feature_branch=$(jq -r '.branches.feature' "$WORK_DIR/{identifier}/state.json")

# Load implementation state if exists
if [[ -f "$WORK_DIR/{identifier}/state.json" ]]; then
  if ! jq empty "$WORK_DIR/{identifier}/state.json" 2>/dev/null; then
    echo "WARNING: Implementation state file is corrupted"
    echo "Starting fresh implementation"
  else
    impl_status=$(jq -r '.status' "$WORK_DIR/{identifier}/state.json")
    chunks_completed=$(jq -r '.phases.implement.chunks_completed // 0' "$WORK_DIR/{identifier}/state.json")
    echo "✓ Resuming implementation: $chunks_completed chunks completed"
  fi
fi
```

**Pre-flight validation**: Glob all file paths cited in the requirements context files. If any path does not resolve, warn: `'Stale path detected: {path} — requirements may need refresh.'` Flag but do not block.

Extract:
- `identifier` - work identifier
- `base_branch` - target branch for PR
- `feature_branch` - current working branch
- `requirements` - from requirements phase context/
- `implementation_progress` - chunks completed (if resuming)

#### 0.2b Enter Worktree (Conditional)

Skip this step if `resolve_worktree_enabled` returns `"false"`.

```bash
WORKTREE_ENABLED=$(resolve_worktree_enabled)
```

**If WORKTREE_ENABLED == "true":**

**Single mode** (`WORKSPACE_MODE == "single"`):
1. Call `EnterWorktree` with name `"impl-{identifier}"`
   - CWD moves to `.claude/worktrees/impl-{identifier}/`
   - A temporary branch is created from HEAD
2. After entering, checkout the feature branch (next step handles this)
3. `$WORK_DIR` still resolves correctly (anchored to `WORKSPACE_ROOT`)

**Multi mode** (`WORKSPACE_MODE == "multi"`):
1. Create per-service worktrees:
```bash
WT_ROOT=$(resolve_worktree_root)
TICKET_WORKSPACE="${WT_ROOT}/{identifier}"
mkdir -p "$TICKET_WORKSPACE"

for svc in $(resolve_services); do
  svc_path=$(resolve_service_path "$svc")
  wt_path="${TICKET_WORKSPACE}/${svc}"

  if [[ -d "$wt_path" ]]; then
    echo "Worktree exists: ${svc}/ → ${wt_path}"
    continue
  fi

  # Create worktree with feature branch (create branch or checkout existing)
  git -C "$svc_path" worktree add "$wt_path" -b "feature/{identifier}" 2>/dev/null \
    || git -C "$svc_path" worktree add "$wt_path" "feature/{identifier}"

  echo "Created worktree: ${svc}/ → ${wt_path}"
done
```
2. All subsequent agent prompts MUST use `$TICKET_WORKSPACE/{service}/` paths instead of original service paths
3. Track in state.json (see 0.3 below)

**Track worktree state** — add to state.json:
```json
{
  "worktree": {
    "enabled": true,
    "mode": "single|multi",
    "name": "impl-{identifier}",
    "workspace": "/absolute/path/.worktrees/{identifier}",
    "services": {
      "service1": "/absolute/path/.worktrees/{identifier}/service1",
      "service2": "/absolute/path/.worktrees/{identifier}/service2"
    }
  }
}
```

---

Ensure on correct branch:

**Single mode (in worktree):** checkout feature branch inside the worktree.
**Multi mode:** branches already set during worktree creation.
**No worktree:** standard checkout.

```bash
git checkout feature/{identifier}
```

**CRITICAL VALIDATION** - Verify we're on a feature branch:
```bash
current_branch=$(git branch --show-current)

# Must be on a feature branch
if [[ ! "$current_branch" =~ ^feature/ ]]; then
  echo "ERROR: Must be on a feature branch to implement."
  echo "Current branch: $current_branch"
  echo ""
  echo "If feature branch doesn't exist, run /create-requirements first."
  exit 1
fi

# Must NOT be on a release branch
if [[ "$current_branch" =~ ^release/ ]]; then
  echo "ERROR: Cannot implement directly on release branch."
  echo "Create a feature branch first: git checkout -b feature/{identifier} $current_branch"
  exit 1
fi

echo "✓ On feature branch: $current_branch"
```

**If not on feature branch**: STOP. Do NOT proceed with implementation.

#### 0.3 Initialize Implementation State

Read the existing `state.json` (written by `create-requirements`). Verify `type == "requirements"`.

If `state.json` doesn't exist or has `type == "implementation"` (resuming), skip creation or load as-is.

**Transition**: Replace the requirements state by writing a new `state.json` with `type: "implementation"`. Preserve key requirements fields in the `requirements` sub-object:

```json
{
  "schema_version": 1,
  "type": "implementation",
  "identifier": "{identifier}",
  "status": "in_progress",
  "started_at": "{ISO_TIMESTAMP}",

  "requirements": {
    "branches": {
      "base": "{base_branch from requirements state}",
      "feature": "feature/{identifier}",
      "remote_pushed": false
    }
  },

  "phases": {
    "plan": {"status": "pending"},
    "implement": {"status": "pending", "chunks_completed": 0, "chunks_total": 0},
    "test": {"status": "pending"},
    "review": {"status": "pending"},
    "qa_gate": {"status": "pending"},
    "pr": {"status": "pending"}
  },

  "plan": null,
  "implemented_files": [],
  "commits": []
}
```

#### 0.4 Update Work Manifest

After creating or loading `state.json`, upsert into `${WORK_DIR}/manifest.json` (see [docs/manifest-system.md](../../docs/manifest-system.md)).

Read or initialize manifest, then upsert item using `identifier` as unique key:

```json
{
  "identifier": "{identifier}",
  "title": "{feature_description_summary}",
  "type": "implementation",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "current_phase": "plan",
  "progress": "0/{chunks_total} chunks",
  "branch": "feature/{identifier}",
  "tags": [],
  "path": "{identifier}/"
}
```

Update `last_updated` and `total_items` in the envelope.

---

### Phase 1: Understand Requirements

**Goal**: Parse and validate the requirements input.

#### 1.1 Detect Input Format

Parse $ARGUMENTS to determine input type:

```
Arguments: $ARGUMENTS

Detection logic:
- If contains "--dry-run": Enable dry-run mode, parse remaining args
- If is $WORK_DIR/{id}/: Load from work directory
- If ends with ".md": Requirements file
- If empty: Smart detection (Phase 0)
```

#### 1.2 Load Requirements

**From work directory:**
```
Load context from $WORK_DIR/{identifier}/context/:
- discovery.json (from context-builder — JSON)
- archaeologist.md
- data-modeler.md (if exists)
- etc.

Synthesize into requirements summary.
```

**From file:**
```
Read the requirements file and extract:
- Summary
- Requirements list
- Acceptance criteria
- Technical context
```

#### 1.3 Update State

```json
{
  "phases": {
    "plan": {"status": "in_progress"}
  }
}
```

---

### Phase 2: Explore & Plan

**Goal**: Understand codebase context and design implementation approach.

#### 2.1 Codebase Exploration (Conditional)

**OPTIMIZATION**: Skip exploration if coming from `/create-requirements`.

**Check for existing context:**
```bash
# Check if context files exist from requirements phase
if [[ -f "$WORK_DIR/{identifier}/context/archaeologist.md" ]]; then
  echo "✓ Found existing context from requirements phase"
  echo "  Skipping Explore agent - using cached context"
  SKIP_EXPLORE=true
else
  echo "No cached context found - running Explore agent"
  SKIP_EXPLORE=false
fi
```

**If SKIP_EXPLORE=true:**
- Load context from `$WORK_DIR/{identifier}/context/`:
  - `discovery.json` → endpoints, services, entities
  - `archaeologist.md` → patterns, code to modify
  - `data-modeler.md` → schema info (if exists)
- Use this as `{exploration_results}` for planning

**If SKIP_EXPLORE=false (no cached context):**

**Verify which context files are missing:**
```bash
# Check for expected context files from requirements phase
required_files=("discovery.json" "archaeologist.md")
optional_files=("data-modeler.md" "integration-analyst.md" "security-requirements.md")
missing_required=()

for file in "${required_files[@]}"; do
  if [[ ! -f "$WORK_DIR/{identifier}/context/$file" ]]; then
    missing_required+=("$file")
  fi
done

if [[ ${#missing_required[@]} -gt 0 ]]; then
  echo "⚠ Missing required context files: ${missing_required[*]}"
  echo "Running Explore agent to gather context"
  SKIP_EXPLORE=false
else
  echo "✓ All required context files present"

  # Verify context files are valid JSON
  for file in $WORK_DIR/{identifier}/context/*.json; do
    if [[ -f "$file" ]] && ! jq empty "$file" 2>/dev/null; then
      echo "⚠ Invalid JSON in $(basename $file)"
      echo "Running Explore agent to regenerate context"
      SKIP_EXPLORE=false
      break
    fi
  done
fi
```

**Use Task tool with `subagent_type: "Explore"`:**

```
Prompt: Explore the codebase to understand context for implementing the following feature.

Feature Summary:
{requirements_summary}

Key Requirements:
{requirements_list}

Research and document:
1. Files that will need modification
2. Files to use as reference/patterns
3. Existing similar implementations
4. Test files for affected areas
5. Dependencies and integrations involved
6. Naming conventions and architectural patterns

Return a structured report with file paths and recommendations.
```

#### 2.2 Implementation Planning

**Use Task tool with `subagent_type: "Plan"`:**

```
Prompt: Create an implementation plan for the following feature.

Feature Summary:
{requirements_summary}

Requirements:
{requirements_list}

Codebase Context:
{exploration_results}

Create a step-by-step implementation plan:
1. List files to create/modify in order
2. For each file, describe the changes needed
3. Group into logical CHUNKS that can be committed separately
4. Note any risks or considerations
5. Estimate complexity (simple/moderate/complex)

Each chunk should be:
- A logical unit of work
- Independently testable
- Suitable for a single commit

When the implementation plan spans 2+ independent services (no shared write targets),
recommend parallel chunk execution. Note which chunks are independent and can be
implemented by separate agents simultaneously.
```

#### 2.3 Architecture Validation

**Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Validate this implementation plan against architecture rules.

Plan:
{implementation_plan}

Check:
1. Does this follow existing patterns?
2. Are there architectural concerns?
3. Is the approach consistent with the codebase?

Return validation result with any concerns.
```

#### 2.3b Requirements Coverage Validation

**Goal**: Verify the implementation plan addresses every requirement from Phase 1.

**Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Validate that this implementation plan fully covers the requirements.

Requirements (from Phase 1):
{requirements_list}

Acceptance Criteria:
{acceptance_criteria}

Implementation Plan:
{implementation_plan_with_chunks}

Cross-reference each requirement and acceptance criterion against the plan:

1. For each requirement, identify which chunk(s) address it
2. Flag any requirement NOT covered by any chunk
3. Flag any acceptance criterion that is NOT testable in the current plan
4. Note any plan chunks that don't trace back to a specific requirement (scope creep risk)

Return a coverage matrix:
| Requirement | Covered By (Chunk) | Status |
|-------------|--------------------|--------|
| Req 1       | Chunk 2            | COVERED |
| Req 2       | -                  | GAP     |

If gaps are found, suggest which chunk should address them or recommend adding a new chunk.
```

**If gaps found**: Present the coverage gaps to the user and ask whether to:
- Adjust the plan to cover missing requirements
- Proceed without full coverage (document gaps)
- Abort and revisit requirements

Use AskUserQuestion if the architect identifies coverage gaps.

**If fully covered**: Continue to save plan.

---

#### 2.4 Save Plan to State

```json
{
  "phases": {
    "plan": {"status": "completed"}
  },
  "plan": {
    "chunks": [
      {"id": 1, "description": "...", "files": [...], "status": "pending"},
      {"id": 2, "description": "...", "files": [...], "status": "pending"}
    ]
  }
}
```

#### 2.5 Checkpoint: Confirm Plan

**If --dry-run mode:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DRY RUN - Implementation Plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{implementation_plan}

Chunks:
1. {chunk_1_description} ({file_count} files)
2. {chunk_2_description} ({file_count} files)

Estimated complexity: {complexity}

To execute: /implement {original_args without --dry-run}
```
Stop execution.

**If normal mode:**

Use AskUserQuestion:
```
Implementation Plan Ready

{plan_summary}

Chunks to implement:
1. {chunk_1} - {files}
2. {chunk_2} - {files}

Each chunk will be committed separately.

Proceed with implementation? [y/n]
```

---

### Phase 3: Implement with Chunk Commits

**Goal**: Execute the implementation plan, committing each chunk.

#### 3.1 Resume Check

If resuming, skip completed chunks:

```python
for chunk in plan.chunks:
    if chunk.status == "completed":
        continue  # Already done
    # Implement this chunk
```

#### 3.2 Execute Each Chunk

For each chunk:

1. **Announce the chunk:**
   ```
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Chunk {N}/{total}: {chunk_description}
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   Files: {files_in_chunk}
   ```

2. **Implement the changes:**
   - Create new files as needed
   - Modify existing files
   - Follow patterns identified in exploration phase

3. **Commit the chunk using git-operator:**

   **Use Task tool with `subagent_type: "git-operator"`:**

   ```
   Prompt: Commit the following changes as a single atomic commit.

   Identifier: {identifier}
   Chunk: {chunk_description}
   Files changed: {files_list}

   Generate an appropriate commit message and commit the changes.
   Do NOT push yet.
   ```

   **Error Handling for Commit Failure:**

   If git-operator fails to commit:
   ```
   ⚠ Failed to commit chunk {N}: {error_message}

   Options:
   [r] Retry commit (will re-run git-operator)
   [m] Manual fix (you commit manually, then continue)
   [s] Skip commit (DANGEROUS - work is done but not committed)
   [a] Abort implementation

   Select [r/m/s/a]:
   ```

   Use AskUserQuestion for selection.

   - **r (Retry)**: Re-run git-operator with same prompt
   - **m (Manual)**: Wait for user to manually commit, then verify commit exists before proceeding
   - **s (Skip)**: Log warning in state, mark chunk as "completed_uncommitted", continue
   - **a (Abort)**: Stop implementation, save state, exit

   After manual commit option:
   ```bash
   # Verify user created a commit
   if ! git diff-index --quiet HEAD --; then
     echo "ERROR: Still have uncommitted changes"
     echo "Please commit your changes before continuing"
     exit 1
   fi

   # Get the commit hash for state tracking
   commit_hash=$(git rev-parse HEAD)
   echo "✓ Manual commit detected: $commit_hash"
   ```

4. **Update state:**

   ```json
   {
     "plan": {
       "chunks": [
         {"id": 1, "status": "completed", "commit": "abc123"},
         {"id": 2, "status": "in_progress"}
       ]
     },
     "commits": ["abc123"]
   }
   ```

5. **Update work manifest** after each chunk:

   Upsert into `${WORK_DIR}/manifest.json` with updated progress:
   ```json
   {
     "current_phase": "implement",
     "progress": "{chunks_completed}/{chunks_total} chunks",
     "updated_at": "{ISO_TIMESTAMP}"
   }
   ```

6. **Save state after each chunk** (enables resume)

#### 3.3 Chunk Checkpoint

After each chunk, offer to pause:

```
✓ Chunk {N}/{total} committed: {short_commit_hash}

Continue to next chunk? [y/n/review]
```

- **y**: Continue
- **n**: Pause (can resume later with /resume-work)
- **review**: Show diff before continuing

---

### Phase 4: Quality Assurance

**Goal**: Ensure implementation quality through tests and review.

**Execution mode**: Determined by `$QA_EXEC_MODE` (from configuration).

---

#### 4.1 Run QA Agents (Autonomous Collaboration)

**Design principle**: QA agents work autonomously, validate each other's findings, and resolve issues among themselves before presenting results to the user. The user reviews a consolidated, pre-validated report — not raw agent output.

**If `$QA_EXEC_MODE` = `"subagent"`:**

##### Step 1: Parallel Initial Review

Run all three QA agents in parallel as independent tasks.

**Execute in a single message with multiple Task tool calls:**

```
[PARALLEL EXECUTION - Single message with multiple Task calls]

Task 1: subagent_type: "test-writer"
Prompt: Write tests for the following implementation.

Implemented files:
{implemented_files}

Implementation context:
{what_was_implemented}

Requirements:
- Follow existing test patterns
- Cover happy path and error cases
- Use existing test utilities
- Analyze which files need tests (skip if tests already exist)

Return: Test files created and coverage summary.

---

Task 2: subagent_type: "code-reviewer"
Prompt: Review the implementation changes.

Diff: {git_diff}

Categorize issues:
- CRITICAL: Must fix before merge
- IMPORTANT: Should fix
- MINOR: Nice to have

Focus on:
- Logic errors
- Performance issues (N+1 queries, missing indexes)
- Code quality

---

Task 3: subagent_type: "security-auditor"
Prompt: Security review and PII scan.

Diff: {git_diff}

Check for:
- Security vulnerabilities
- PII/secrets exposure
- Input validation gaps
- Injection risks
```

Save all agent outputs to `$WORK_DIR/{identifier}/context/`:
- `qa-test-writer.md`
- `qa-code-reviewer.md`
- `qa-security-auditor.md`

##### Step 2: Skeptic Challenge

After all three QA agents complete, run the quality-guard to challenge their combined findings.

**Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Review the QA findings from three agents and challenge their work.

Implementation diff: {git_diff}
Requirements: $WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md

QA agent outputs (read these files):
- $WORK_DIR/{identifier}/context/qa-test-writer.md
- $WORK_DIR/{identifier}/context/qa-code-reviewer.md
- $WORK_DIR/{identifier}/context/qa-security-auditor.md

Your job (Level 2 — Implementation Validation):
1. Verify each CRITICAL finding by checking the actual code — did the reviewer cite the right file/line?
2. Look for issues ALL THREE agents missed — trace through the code paths yourself
3. Check test coverage: do the tests actually cover the critical paths, or do they test trivial cases?
4. Cross-reference: does the code-reviewer's "no issues" on a file contradict what security-auditor found?
5. Verify the implementation matches the requirements — not just "code works" but "code does what was asked"

Produce a Quality Review Gates report. Include a section on inter-agent agreement/disagreement.
```

Save output to `$WORK_DIR/{identifier}/context/qa-quality-guard.md`.

##### Step 3: Agent Resolution (Autonomous)

**If skeptic verdict is APPROVED**: Proceed to Phase 4.2. No user intervention needed.

**If skeptic verdict is CONDITIONAL or REJECTED**: Agents resolve gates autonomously before involving the user.

For each BLOCKING gate raised by the skeptic, run the appropriate agent to address it:

```
[PARALLEL EXECUTION — one Task per blocking gate]

Task N: subagent_type: "{responsible-agent}"  // code-reviewer, security-auditor, or test-writer
Prompt: The quality-guard challenged your finding / identified a gap.

Gate: {gate_title}
Challenge: {skeptic's specific challenge}
Evidence: {what the skeptic found}

Address this gate:
- If the skeptic is correct, provide the fix or corrected analysis
- If you stand by your original finding, provide concrete evidence (file paths, line numbers, test output)

Return: Your response with evidence.
```

After agents respond, re-run the skeptic on the specific gates:

```
Task: subagent_type: "quality-guard"
Prompt: The agents have responded to your gates. Verify their responses.

Original gates: $WORK_DIR/{identifier}/context/qa-quality-guard.md
Agent responses: {agent_response_1}, {agent_response_2}, ...

For each gate:
- RESOLVED: Agent provided satisfactory evidence
- STILL OPEN: Agent's response is insufficient (explain why)

Issue final verdict.
```

**Deadlock protocol (max resolution iterations: 2)**: After two rounds of agent resolution, remaining open gates are escalated to the user in Phase 4.5. Do NOT continue iterating — present all submissions, objections, and attempted resolutions to the user for a decision: override, provide guidance, or abort. See `~/.claude/shared/principles.md` for the full deadlock protocol.

---

**If `$QA_EXEC_MODE` = `"team"` (default):**

Read `references/qa-team-mode.md` for team mode QA execution details (TeamCreate, task assignment, cross-pollination, shutdown). In team mode, the quality-guard joins as a teammate and challenges findings via SendMessage in real-time rather than in sequential steps.

**IMPORTANT**: Regardless of mode, the output of Phase 4.1 is the same — a set of QA findings categorized by severity, plus test files written, PLUS a skeptic validation report. Subsequent phases (4.2 onward) process these findings identically.

#### 4.2 Run Tests

After test-writer completes:

```bash
# Detect and run tests
# PHP: ./vendor/bin/phpunit
# JS: npm test
# Python: pytest
```

**If tests fail, use test-fixer with retry limit:**

**Test-Fixer Retry Logic:**

```
Max attempts: 3
Current attempt: 0
```

**Loop:**

1. Increment attempt counter
2. Run test-fixer:

   **Use Task tool with `subagent_type: "test-fixer"`:**

   ```
   Prompt: Fix the following test failures (Attempt {attempt}/3).

   Failures:
   {test_output}

   Analyze root cause and fix.
   Return: Fixed code and explanation.
   ```

3. Re-run tests
4. If tests pass: Break loop, continue to Phase 4.3
5. If tests fail and attempt < 3: Continue loop (retry test-fixer)
6. If tests fail and attempt >= 3: Handle persistent failure

**Persistent Test Failure Handling:**

```
⚠ Tests still failing after 3 fix attempts

Failed tests:
{test_names}

Last error:
{test_output}

Options:
[m] Manual fix (pause for you to fix tests)
[s] Skip failing tests (mark in state, continue anyway)
[a] Abort implementation

Select [m/s/a]:
```

Use AskUserQuestion for selection.

- **m (Manual)**: Pause implementation, let user fix tests, re-run tests, then continue
- **s (Skip)**: Mark tests as "failing" in state, continue to PR but add warning
- **a (Abort)**: Stop implementation, save state with test failure info, exit

If skipping tests:
```json
{
  "phases": {
    "test": {
      "status": "completed_with_failures",
      "failing_tests": ["test_1", "test_2"],
      "reason": "Could not auto-fix after 3 attempts"
    }
  }
}
```

Add warning to PR description:
```
⚠️ WARNING: Some tests are failing
- test_1
- test_2

Manual review and fixes required before merge.
```

#### 4.3 Process Review Results

Collect findings from code-reviewer and security-auditor:
- CRITICAL issues → must fix before proceeding
- IMPORTANT issues → fix or document why deferred
- MINOR issues → optional

#### 4.4 Auto-Fix Issues

For auto-fixable issues, apply fixes and create additional commit:

**Use Task tool with `subagent_type: "git-operator"`:**

```
Prompt: Commit the review fixes.

Fixes applied:
{list_of_fixes}

Create a commit for these fixes.
```

#### 4.5 Report QA Summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Quality Assurance Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Tests:
  ✓ New tests written: {count}
  ✓ All tests passing: {yes/no}

Code Review:
  🔴 CRITICAL: {count}
  🟡 IMPORTANT: {count}
  🔵 MINOR: {count}

Security:
  ✓ No vulnerabilities / ⚠ Issues: {count}

Skeptic Validation:
  Verdict: {APPROVED|CONDITIONAL|REJECTED}
  Gates raised: {count}
  Gates resolved (autonomous): {count}
  Gates escalated to user: {count}

Auto-fixed: {count} issues
```

#### 4.6 Update State

```json
{
  "phases": {
    "test": {"status": "completed", "tests_written": 5, "all_passing": true},
    "review": {"status": "completed", "critical": 0, "important": 2, "minor": 1},
    "skeptic_validation": {
      "status": "completed",
      "verdict": "approved|conditional",
      "gates_raised": 3,
      "gates_resolved_autonomous": 2,
      "gates_escalated": 1,
      "iterations": 1
    }
  }
}
```

---

#### 4.7 Quality Gate (Auto-Fix Feedback Loop)

**Goal**: Ensure all critical issues are resolved before PR creation, with automated fix attempts.

This phase acts as a gate between QA (Phase 4) and PR creation (Phase 5). It collects all QA findings, attempts to auto-fix critical issues, re-validates fixes, and only proceeds when quality standards are met.

#### 4.7.1 Collect and Categorize All Findings

Gather outputs from all Phase 4 agents (code-reviewer, security-auditor, test-writer/test results). Create a consolidated findings list:

```
Consolidated QA Findings:

CRITICAL (must fix before PR):
  - [CR-1] code-reviewer: Null pointer dereference in UserService.php:45
  - [SA-1] security-auditor: SQL injection in SearchController.php:89

IMPORTANT (should fix):
  - [CR-2] code-reviewer: N+1 query in OrderRepository.php:112
  - [CR-3] code-reviewer: Missing error handling in ApiClient.php:67

MINOR (optional):
  - [CR-4] code-reviewer: Variable naming in helpers.php:23
  - [SA-2] security-auditor: Missing rate limiting on /api/search
```

**Severity classification:**
- **CRITICAL** (must fix): Bugs, security vulnerabilities, data loss risk, crashes, injection flaws
- **IMPORTANT** (should fix): Performance issues, maintainability concerns, missing validation
- **MINOR** (optional): Style, naming, minor improvements, documentation gaps

Save the consolidated findings to `$WORK_DIR/{identifier}/qa-gate-report.md`:

```markdown
# Quality Gate Report - {identifier}
Generated: {ISO_TIMESTAMP}

## Summary
- Critical: {count}
- Important: {count}
- Minor: {count}

## Critical Issues
| ID | Source | File:Line | Description |
|----|--------|-----------|-------------|
| CR-1 | code-reviewer | UserService.php:45 | Null pointer dereference |
| SA-1 | security-auditor | SearchController.php:89 | SQL injection |

## Important Issues
...

## Minor Issues
...
```

#### 4.7.2 Auto-Fix Critical Issues (Conditional)

**If NO critical issues found**: Skip to 4.7.4 (proceed directly).

**If critical issues found**, attempt auto-fix for each one sequentially (max 2 fix attempts per issue):

```
For each critical issue:

1. Attempt fix via refactorer agent (attempt 1)
2. Re-validate the fix
3. If still unresolved: attempt fix via refactorer agent (attempt 2, with failure context)
4. Re-validate again
5. Track result (resolved / unresolved)
```

Read `references/quality-gate-prompts.md` for the detailed auto-fix and re-validation prompt templates (refactorer fix prompts, code-reviewer/security-auditor re-validation prompts, attempt 2 enriched context prompt).

**Track results for each issue:**
```
Issue CR-1: RESOLVED (attempt 1) - Fix applied in UserService.php
Issue SA-1: RESOLVED (attempt 2) - Different approach worked after first attempt failed
Issue SA-2: UNRESOLVED - Both auto-fix attempts failed, requires manual intervention
```

**IMPORTANT**: Run fixes sequentially (each fix may affect subsequent ones). Do NOT run fixes in parallel.

#### 4.7.3 Commit Fixes (Conditional)

**If any fixes were applied successfully:**

1. Stage the fixed files
2. Commit via git-operator:

   **Use Task tool with `subagent_type: "git-operator"`:**

   ```
   Prompt: Commit the following QA auto-fix changes.

   Identifier: {identifier}
   Fixes applied:
   {list_of_resolved_issues_with_files}

   Commit message format: [{identifier}] fix: address critical QA findings
   Do NOT push yet.
   ```

3. Update state with the new commit:

   ```json
   {
     "commits": ["abc123", "def456", "qa-fix-789"]
   }
   ```

#### 4.7.4 Quality Gate Decision

Based on remaining (unresolved) issues after auto-fix attempts:

**If NO critical issues remain:**

```
✓ Quality Gate PASSED

Critical issues: {resolved_count} resolved, 0 remaining
Important issues: {count} (will be included in PR description)
Minor issues: {count} (will be included in PR description)

Proceeding to PR creation...
```

→ Proceed to Phase 5 (PR creation)
→ Include remaining IMPORTANT/MINOR issues in PR description body

**If CRITICAL issues remain (auto-fix failed):**

```
⚠ Quality Gate FAILED

{unresolved_count} critical issue(s) could not be auto-resolved:

1. [{issue_id}] {description}
   File: {file_path}:{line_number}
   Source: {code-reviewer | security-auditor}
   Auto-fix result: {what_was_attempted_and_why_it_failed}

2. [{issue_id}] {description}
   ...
```

Use AskUserQuestion:
```
Quality gate: {unresolved_count} critical issue(s) could not be auto-resolved.

Options:
[1] Fix manually and retry - you fix the issues, then re-run quality gate
[2] Proceed anyway - create PR with known critical issues documented
[3] Abort - stop implementation, preserve work state for later

Select [1/2/3]:
```

- **1 (Fix manually and retry)**: Pause for user to fix, then re-run Phase 4.7 from 4.7.1
- **2 (Proceed anyway)**: Continue to Phase 5 with critical issues documented in PR description as warnings:
  ```
  ⚠️ KNOWN CRITICAL ISSUES (user approved proceeding):
  - [{issue_id}] {description} in {file}:{line}
  ```
- **3 (Abort)**: Stop implementation, save state with quality gate failure info, exit

#### 4.7.5 Update State

```json
{
  "phases": {
    "qa_gate": {
      "status": "completed",
      "findings": {
        "critical": {"total": 2, "resolved": 1, "unresolved": 1},
        "important": {"total": 3},
        "minor": {"total": 2}
      },
      "auto_fixes_applied": 1,
      "auto_fixes_failed": 1,
      "gate_result": "passed | failed_override | failed_manual_fix",
      "report_path": "{identifier}/qa-gate-report.md"
    }
  }
}
```

Update work manifest:
```json
{
  "current_phase": "qa_gate",
  "updated_at": "{ISO_TIMESTAMP}"
}
```

---

### Phase 5: Create PR

**Goal**: Push changes and create pull request.

#### 5.1 Push All Commits

**SAFETY CHECK** - Verify branch before pushing:
```bash
current_branch=$(git branch --show-current)

# NEVER push to release branches directly
if [[ "$current_branch" =~ ^release/ ]]; then
  echo "ERROR: Cannot push directly to release branch: $current_branch"
  echo "All changes to release branches must go through PRs."
  exit 1
fi

# NEVER push to main/master directly
if [[ "$current_branch" =~ ^(main|master)$ ]]; then
  echo "ERROR: Cannot push directly to $current_branch"
  echo "Create a feature branch and PR instead."
  exit 1
fi

# Must be on feature branch
if [[ ! "$current_branch" =~ ^feature/ ]]; then
  echo "WARNING: Not on a feature branch. Current: $current_branch"
  echo "Expected: feature/{identifier}"
fi
```

```bash
git push origin feature/{identifier}
```

#### 5.2 Confirm Target Branch

Use AskUserQuestion:

```
Ready to create PR

Source: feature/{identifier}
Target: {base_branch} (from requirements phase)

Commits:
- {commit_1_message}
- {commit_2_message}
- {commit_3_message}

Create PR to {base_branch}? [y/change/skip]
```

- **y**: Create PR to base_branch
- **change**: Enter different target branch
- **skip**: Don't create PR now

#### 5.3 Create PR

```bash
gh pr create \
  --base {target_branch} \
  --head feature/{identifier} \
  --title "[{identifier}] {feature_title}" \
  --body "$(cat <<'EOF'
## Summary
{feature_summary}

## Changes
{list_of_changes}

## Quality Gate
{quality_gate_result: PASSED | FAILED_OVERRIDE}

{if FAILED_OVERRIDE, include:}
⚠️ KNOWN CRITICAL ISSUES (user approved proceeding):
- [{issue_id}] {description} in {file}:{line}

{if IMPORTANT/MINOR issues remain, include:}
### Remaining Review Findings
🟡 **Important:**
- {important_issue_description}

🔵 **Minor:**
- {minor_issue_description}

## Test Plan
- [ ] Unit tests pass
- [ ] Manual testing completed

## Commits
{commit_list}
EOF
)"
```

#### 5.4 Offer PR Review

```
✓ PR created: {pr_url}

Would you like to run /pr-review on this PR? [y/n]
```

If yes, trigger `/pr-review {pr_number}`.

#### 5.5 Update Work Manifest (Final)

Update the work manifest to reflect completion (see [docs/manifest-system.md](../../docs/manifest-system.md)).

Upsert item using `identifier` as unique key:

```json
{
  "identifier": "{identifier}",
  "type": "implementation",
  "status": "completed",
  "current_phase": "completed",
  "progress": "{chunks_total}/{chunks_total} chunks",
  "updated_at": "{ISO_TIMESTAMP}"
}
```

#### 5.6 Update Final State

```json
{
  "status": "completed",
  "completed_at": "{ISO_TIMESTAMP}",
  "phases": {
    "pr": {"status": "completed", "pr_url": "...", "pr_number": 123}
  }
}
```

---

### Phase 6: Final Report

#### 6.1 Generate Cost Summary

Track which agents were spawned and their model tiers for cost awareness. Save to `$WORK_DIR/{identifier}/cost-summary.md`:

```markdown
# Cost Summary: {identifier}
Generated: {ISO_TIMESTAMP}
Skill: /implement

## Agent Spawns

| Agent | Model | Phase | Purpose |
|-------|-------|-------|---------|
| Explore | sonnet | Phase 2 | Codebase exploration |
| Plan | opus | Phase 2 | Implementation planning |
| architect | opus | Phase 2 | Architecture validation |
| test-writer | sonnet | Phase 4 | Test creation |
| code-reviewer | opus | Phase 4 | Code review |
| security-auditor | opus | Phase 4 | Security audit |
| quality-guard | opus | Phase 4 | Skeptic validation |
| test-fixer | sonnet | Phase 4 | Test fixes (if needed) |
| refactorer | sonnet | Phase 4.7 | Auto-fix (if needed) |
| git-operator | sonnet | Phase 3,5 | Commits and PR |

## Summary
- Opus agents: {count}
- Sonnet agents: {count}
- Lightweight mode: {yes/no}
```

Adjust the table based on which agents were actually spawned (some are conditional).

#### 6.2 Print Report

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Implementation Complete: {identifier}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Feature: {feature_summary}
Branch: feature/{identifier}

Commits: {count}
{commit_list}

Files Created: {count}
Files Modified: {count}

Tests:
  ✓ New tests: {count}
  ✓ All passing: {yes/no}

Review:
  ✓ Auto-fixed: {count}
  ⚠ Remaining: {count}

Skeptic Validation:
  Verdict: {APPROVED | CONDITIONAL}
  Gates: {resolved}/{raised} resolved autonomously

Quality Gate:
  Result: {PASSED | FAILED_OVERRIDE | FAILED_MANUAL_FIX}
  Critical: {resolved}/{total} resolved
  Auto-fixes applied: {count}
  Report: $WORK_DIR/{identifier}/qa-gate-report.md

Cost: {opus_count} Opus + {sonnet_count} Sonnet agents
PR: {pr_url}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## State File Schema

Read `references/state-schema.md` for the complete `state.json` schema.

---

## Error Handling

Read `references/error-handling.md` for error recovery procedures (no work found, branch conflict, commit failed).

---

## Branch Safety Rules

Read `references/branch-safety-rules.md` for the complete branch safety rules. **CRITICAL**: These rules are enforced at Phase 0.2, Phase 3, and Phase 5.1 — read the reference before each enforcement point.

---

## Important Notes

- **State persistence**: Progress saved after each chunk for resume capability
- **Chunk commits**: Each logical unit committed separately for clean history
- **Smart detection**: Scans `$WORK_DIR/` for incomplete work
- **Git-operator delegation**: All git operations go through git-operator agent
- **Quality gate**: Critical QA issues must be resolved (or explicitly overridden) before PR creation
- **Auto-fix feedback loop**: Critical issues get up to 2 auto-fix attempts via refactorer (second attempt includes failure context), with targeted re-validation
- **PR workflow**: Target branch from requirements phase, with confirmation
- **Review integration**: Offers `/pr-review` after PR creation
- **Branch protection**: NEVER push directly to release/main/master branches
- **Ticket requirement**: Commit messages MUST include ticket number from branch in `[TICKET-123]` format
- **Worktree isolation**: When `worktree.enabled: true`, implementation runs in an isolated worktree. State files persist in the original workspace root. On completion, the worktree is kept (not removed) so the user can inspect or continue work

## Worktree Exit

After Phase 5 (PR creation) completes — or if the skill ends early for any reason:

**Single mode**: Call `ExitWorktree(action: "keep")` to return to the original working directory. The worktree and its branch are preserved on disk.

**Multi mode**: No explicit cleanup. Per-service worktrees persist at `{worktree_root}/{identifier}/`. Print a cleanup hint alongside the PR URL:

```
Multi-repo worktrees are kept at .worktrees/{identifier}/.
After the PR is merged, clean up with:
  rm -rf .worktrees/{identifier}
  git -C service1 worktree prune
  git -C service2 worktree prune
```

Update `state.json`:
```json
{
  "worktree": {
    "enabled": true,
    "mode": "...",
    "status": "kept"
  }
}
```
