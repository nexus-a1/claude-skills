---
name: create-requirements
category: planning
model: opus
userInvocable: true
description: Run a multi-agent pipeline to produce detailed technical requirements and a ticket-ready summary. Creates a feature branch, persists session state, and supports resume. Optionally seeds from a prior brainstorm session.
argument-hint: "[--light] [--from-brainstorm <slug>] [feature-description]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage
---

# Create Requirements

## Goal

Create comprehensive, step-by-step technical requirements documentation for a given task or feature. Establishes persistent work context that enables `/implement` and `/resume-work` to continue seamlessly.

## Scope Boundary — CRITICAL

**This skill produces REQUIREMENTS DOCUMENTS. It does NOT implement anything.**

- Do NOT enter plan mode for implementation after requirements are complete
- Do NOT propose code changes, file modifications, or implementation steps
- Do NOT ask the user to confirm execution of implementation
- The terminal state of this skill is: requirements documents saved, completion report printed, STOP
- The user will explicitly invoke `/implement` when they are ready to implement
- If Claude's workflow rules say "enter plan mode for non-trivial tasks" — that applies to planning the REQUIREMENTS GATHERING process, not planning implementation

## Execution Modes

This skill supports two execution modes, controlled by `execution_mode` in `.claude/configuration.yml`:

| Mode | Value | Deep-Dive Behavior | Token Cost | Best For |
|------|-------|-------------------|------------|----------|
| **Team** | `"team"` (default) | Agent teammates with cross-pollination via SendMessage | Higher quality | Most features — agents collaborate |
| **Sub-agent** | `"subagent"` | Parallel Task calls, independent agents | Lower token cost | Quick iterations, cost-sensitive |

**Team mode adds:** Agents can read each other's outputs during deep-dive, enabling cross-pollination of findings. The lead monitors progress and notifies agents when peer findings become available.

## Outputs

This skill produces:
1. **`state.json`** - State file for resume capability
2. **`context/`** - Cached agent outputs for reference
3. **`{identifier}-TECHNICAL_REQUIREMENTS.md`** - Full technical spec
4. **`{identifier}-JIRA_TICKET.md`** - Light JIRA-ready summary
5. **Consolidated requirements** - Final output from business-analyst synthesis

All saved to `$WORK_DIR/{identifier}/`

---

## Configuration

Read `.claude/configuration.yml` for project-specific paths and execution mode. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `execution_mode` | `"team"` | Agent execution mode (`"subagent"` or `"team"`) |
| `storage.artifacts.work` | `location: local, subdir: work` | Work state and context |

Optional integrations (only if artifact exists in configuration.yml):

| Config Key | Enables |
|-----------|---------|
| `storage.artifacts.requirements` | `archivist` agent |
| `storage.artifacts.product-knowledge` | `product-expert` agent |

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
REQUIREMENTS_DIR=$(resolve_artifact requirements requirements)
EXEC_MODE=$(resolve_exec_mode requirements_deep_dive team)
```

Use `$WORK_DIR` instead of hardcoded `.claude/work` throughout this workflow.
Use `$EXEC_MODE` to determine team vs sub-agent behavior at stages 2, 3, 4, 4.5, and 4.6.

**Important:** All path references in this skill MUST use `$WORK_DIR`. Never use hardcoded `.claude/work/` paths.

---

## Write Safety

Agents working in parallel MUST NOT write to the same file. Follow these conventions:

- **Agent outputs**: Each agent writes ONLY to `$WORK_DIR/{identifier}/context/{agent-name}.md` (e.g., `context/archaeologist.md`, `context/data-modeler.md`). Agents NEVER write to another agent's output file.
- **State files**: Only the skill lead writes to `state.json` and final output documents (`{identifier}-TECHNICAL_REQUIREMENTS.md`, `{identifier}-JIRA_TICKET.md`).
- **Manifest**: Only the skill lead writes to `${WORK_DIR}/manifest.json`.
- **Discovery JSON**: Only the context-builder writes to `context/discovery.json`.

See `~/.claude/shared/write-safety.md` for the full conventions.

---

## Lightweight Mode

If `$ARGUMENTS` begins with `--light`, strip the flag and enable lightweight mode:

- Output to user: "Lightweight mode enabled: research agents use Sonnet. Quality gates unchanged."
- **context-builder**: unchanged (already sonnet)
- **archaeologist**: unchanged (already sonnet)
- **data-modeler**: unchanged (already sonnet)
- **integration-analyst**: unchanged (already sonnet)
- **archivist**: unchanged (already sonnet)
- **product-expert**: unchanged (already sonnet)
- **business-analyst**: spawn with model **sonnet** instead of opus (ALWAYS Opus in standard mode — reasoning-heavy synthesis)
- **security-requirements**: unchanged (already sonnet)
- All orchestration flow, quality standards, and output formats remain identical

This reduces cost for the analysis/synthesis phase. In most cases the deep-dive agents are already Sonnet, so the savings come from the business-analyst downgrade.

---

## Process

### Stage 0: Check for Existing Session

Before collecting any input, scan for active requirements sessions.

```bash
if [[ -f "${WORK_DIR}/manifest.json" ]]; then
  jq -r '.items[] | select(.type == "requirements" and .status != "completed") | "\(.identifier)\t\(.title)\t\(.current_phase)\t\(.progress)\t\(.updated_at)"' "${WORK_DIR}/manifest.json"
fi
```

**If active sessions found**, display them and ask:

```
Active requirements sessions:

  [1] PROJ-123 — User Export Feature
      Stage: deep_dive (Stage 3/4) — last updated 3 hours ago

  [2] PROJ-456 — SSO Integration
      Stage: setup (Stage 1/4) — last updated 2 days ago

  [n] Start new session

Select session to resume, or [n] to start fresh:
```

Use AskUserQuestion. On selection: load state from `$WORK_DIR/{identifier}/state.json` and resume from the recorded stage. On **n**: proceed to Stage 1.

**If no active sessions:** Proceed directly to Stage 1.

---

### Stage 1: Setup

**Goal**: Establish work identifier, create feature branch, initialize state.

#### 1.1 Get Work Identifier

Use AskUserQuestion:
```
What is the ticket number for this work?

Format: PROJECT-NUMBER (e.g., JIRA-123, PROJ-456, SKILLS-001)

This will be used for:
- Branch name: feature/{ticket}
- Work directory: $WORK_DIR/{ticket}/
- Commit messages: [{ticket}] type(scope): description
- Output files: {ticket}-TECHNICAL_REQUIREMENTS.md
```

**VALIDATION**: The identifier MUST match pattern `[A-Z]+-[0-9]+` (e.g., JIRA-123, SKILLS-001).
If user provides a slug instead of ticket number, ask them to provide the ticket number.

Store as `{identifier}`.

#### 1.2 Get Feature Description

If not provided in $ARGUMENTS, use AskUserQuestion:
```
Describe the feature or task to create requirements for:
```

Store as `{feature_description}`.

#### 1.3 Refine Requirements

**Goal**: Clarify ambiguous requirements before running heavy agent pipeline.

Ask 3-5 targeted questions to refine the user's requirements. Use AskUserQuestion with multi-select where appropriate.

**Question categories** (select relevant ones based on feature description):

1. **Scope clarification**:
   ```
   What should be IN scope for this feature?
   - [ ] New API endpoints
   - [ ] Database changes
   - [ ] UI changes
   - [ ] Background jobs
   - [ ] External integrations
   - [ ] Other: ___
   ```

2. **User/Actor identification**:
   ```
   Who will use this feature?
   - [ ] End users (customers)
   - [ ] Admin users
   - [ ] System/automated processes
   - [ ] External services
   - [ ] Other: ___
   ```

3. **Edge cases & constraints**:
   ```
   Are there specific constraints or edge cases to consider?
   - Performance requirements (e.g., must handle X requests/sec)
   - Data volume expectations
   - Backward compatibility needs
   - Security/compliance requirements
   - Other: ___
   ```

4. **Success criteria**:
   ```
   How will we know this feature is complete?
   Describe the key acceptance criteria:
   ```

5. **Dependencies & blockers**:
   ```
   Are there any dependencies or blockers?
   - Waiting on external API access
   - Depends on another feature
   - Needs design approval
   - Other: ___
   ```

**Output**: Store refined requirements as `{refined_requirements}` with:
- Original description
- Scope (in/out)
- Actors
- Constraints
- Acceptance criteria
- Dependencies

**Skip refinement if**: User provides comprehensive requirements upfront (includes scope, acceptance criteria, and constraints). Use judgment.

#### 1.3b Load Prior Brainstorm (Optional)

If `$ARGUMENTS` contains `--from-brainstorm {slug}`, extract the slug. Otherwise, ask:

```
AskUserQuestion:
Do you have a prior brainstorm session for this feature?
Enter the brainstorm slug (e.g., "user-data-export"), or leave blank to skip.
```

**If a slug is provided:**

1. Check `$WORK_DIR/{brainstorm-slug}/state.json` exists and has `"type": "brainstorm"`.
2. If not found, warn and continue without brainstorm context.
3. If found, load available context files:
   ```bash
   BRAINSTORM_CONTEXT_DIR="$WORK_DIR/{brainstorm-slug}/context"
   BRAINSTORM_STATE="$WORK_DIR/{brainstorm-slug}/state.json"
   ```
4. Store as `{brainstorm_slug}` and `{has_brainstorm_context: true}`.
5. **Write bidirectional link** — mark the brainstorm as promoted and link both directions:
   ```bash
   # Update brainstorm state: mark promoted
   jq --arg tid "{identifier}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.status = "promoted" | .promoted_to = $tid | .updated_at = $ts' \
     "$WORK_DIR/{brainstorm-slug}/state.json" > /tmp/bs-tmp.json \
     && mv /tmp/bs-tmp.json "$WORK_DIR/{brainstorm-slug}/state.json"

   # Update manifest entry for brainstorm (if manifest exists)
   if [[ -f "$WORK_DIR/manifest.json" ]]; then
     jq --arg slug "{brainstorm-slug}" --arg tid "{identifier}" \
       '(.items[] | select(.identifier == $slug)) |= (.status = "promoted" | .promoted_to = $tid)' \
       "$WORK_DIR/manifest.json" > /tmp/mf-tmp.json && mv /tmp/mf-tmp.json "$WORK_DIR/manifest.json"
   fi
   ```
6. Store `{promoted_from: "{brainstorm-slug}"}` — this will be written into the requirements state file at Stage 1.6.
7. Announce to user: `"Loading brainstorm context from: {brainstorm_slug} (marking as promoted → {identifier})"`

**If blank / not found:** Set `{has_brainstorm_context: false}`. Continue normally.

**Brainstorm context is injected at two points downstream:**
- Stage 2.2 (context-builder): receives brainstorm exploration as seed context
- Stage 3.2 (all deep-dive agents): receive selected approach and implementation picture as directional context

---

#### 1.4 Select Base Branch

Fetch available branches and present options:

```bash
git fetch origin
git branch -r | grep -E 'origin/(master|main|release/)' | head -10
```

Use AskUserQuestion:
```
Select base branch for this work:

[1] origin/master (default)
[2] origin/main
[3] origin/release/v{latest}
...
[Other] Enter custom branch
```

Store as `{base_branch}`.

#### 1.5 Create Feature Branch (Local Only)

**CRITICAL**: This step MUST complete successfully before proceeding.

Create the branch locally. Remote push is deferred to Stage 2 (after initial context has been gathered).

**Use Task tool with `subagent_type: "git-operator"`:**

```
Prompt: Create a new local branch feature/{identifier} from {base_branch}.
Do NOT push to remote yet.
```

**VERIFICATION** (required):
```bash
# Verify we're on the feature branch
current_branch=$(git branch --show-current)
if [[ "$current_branch" != "feature/{identifier}" ]]; then
  echo "ERROR: Not on expected branch. Expected: feature/{identifier}, Actual: $current_branch"
  exit 1
fi
echo "✓ On feature branch: $current_branch"
```

**If branch creation fails**: See Error Handling section.

#### 1.6 Initialize Work Directory

```bash
mkdir -p $WORK_DIR/{identifier}/context
```

#### 1.7 Initialize State File

Write `$WORK_DIR/{identifier}/state.json`:

```json
{
  "schema_version": 1,
  "type": "requirements",
  "identifier": "{identifier}",
  "title": "{feature_description_summary}",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "execution_mode": "{EXEC_MODE}",

  "branches": {
    "base": "{base_branch}",
    "feature": "feature/{identifier}",
    "remote_pushed": false
  },

  "requirements": {
    "original": "{feature_description}",
    "refined": {
      "scope": ["..."],
      "actors": ["..."],
      "constraints": ["..."],
      "acceptance_criteria": ["..."],
      "dependencies": ["..."]
    }
  },

  "brainstorm": {
    "promoted_from": "{brainstorm_slug or null}",
    "has_context": "{has_brainstorm_context}"
  },

  "stages": {
    "setup":                  {"stage": 1,   "status": "completed"},
    "discovery":              {"stage": 2,   "status": "pending", "agent": "context-builder"},
    "deep_dive":              {"stage": 3,   "status": "pending", "agents_to_run": []},
    "synthesis":              {"stage": 4,   "status": "pending", "agent": "business-analyst"},
    "resolve_flags":          {"stage": 4.5, "status": "pending", "conditional": true},
    "re_synthesis":           {"stage": 4.6, "status": "pending", "conditional": true},
    "architecture_validation":{"stage": 4.7, "status": "pending", "conditional": true},
    "skeptic_validation":     {"stage": 4.8, "status": "pending", "conditional": true}
  },

  "team": {
    "name": null,
    "created": false
  },

  "outputs": {
    "technical_requirements": null,
    "jira_ticket": null
  },

  "updates": []
}
```

**If `{has_brainstorm_context}` is false**, omit the `brainstorm` key or set both fields to `null`.

**VERIFICATION** (required):
```bash
# Verify state file was created successfully
if [[ ! -f "$WORK_DIR/{identifier}/state.json" ]]; then
  echo "ERROR: Failed to create state file"
  echo "Location: $WORK_DIR/{identifier}/state.json"
  exit 1
fi

# Verify it's valid JSON
if jq empty "$WORK_DIR/{identifier}/state.json" 2>/dev/null; then
  echo "✓ State file created and validated"
else
  echo "ERROR: State file is not valid JSON"
  cat "$WORK_DIR/{identifier}/state.json"
  exit 1
fi
```

#### 1.8 Update Work Manifest

After creating the state file, upsert into `${WORK_DIR}/manifest.json` (see [docs/manifest-system.md](../../docs/manifest-system.md)).

Read or initialize manifest, then upsert item using `identifier` as unique key:

```json
{
  "identifier": "{identifier}",
  "title": "{feature_description_summary}",
  "type": "requirements",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "current_phase": "setup",
  "progress": "Stage 1/4",
  "branch": "feature/{identifier}",
  "tags": [],
  "path": "{identifier}/"
}
```

Update `last_updated` and `total_items` in the envelope.

---

### Stage 1.5: Feasibility Check

**Goal**: Verify that an existing implementation doesn't already satisfy the ticket before running the full pipeline.

After setup completes, run a quick feasibility check:

1. **Search for existing implementations** matching the feature description:
   ```bash
   # Use Grep to search for existing implementations matching the feature description
   # Search for key terms from the feature description in controllers, services, endpoints
   ```

2. **If a match is found**, present it to the user:
   ```
   Use AskUserQuestion:

   Existing implementation found that may satisfy this requirement:

   File: {path}
   Match: {brief description of what was found}

   Does this already satisfy the requirement?
   [y] Yes — halt pipeline and document the finding
   [n] No — continue with full requirements pipeline
   [p] Partial — continue but note existing implementation as context
   ```

3. **If YES**: Halt the pipeline. Update state:
   ```json
   {
     "status": "completed",
     "completed_at": "{ISO_TIMESTAMP}",
     "resolution": "existing_implementation",
     "existing_path": "{path}",
     "note": "Existing implementation already satisfies requirement"
   }
   ```
   Report to the user and stop.

4. **If PARTIAL**: Save the existing implementation path to `$WORK_DIR/{identifier}/context/existing-implementation.md` and continue to Stage 2. This context will inform downstream agents.

5. **If NO or no match found**: Continue to Stage 2.

---

### Stage 2: Discovery

**Goal**: Build structured context inventory using `context-builder` agent. If team mode, also create the agent team.

#### 2.1 [TEAM MODE ONLY] Create Team and Task Graph

**Skip this step if `EXEC_MODE == "subagent"`.**

```
TeamCreate(team_name="req-{identifier}")
```

Update state:
```json
{
  "team": {
    "name": "req-{identifier}",
    "created": true
  }
}
```

Create task graph with dependencies using TaskCreate:

```
T1: "Run context-builder discovery" (no deps)
T2: "Run archaeologist deep-dive" (blocked by T1)
T2b: "Run architect deep-dive" (blocked by T1)
T3: "Run data-modeler deep-dive" (blocked by T1) — if applicable
T4: "Run integration-analyst deep-dive" (blocked by T1) — if applicable
T5: "Run aws-architect deep-dive" (blocked by T1) — if applicable
T6: "Run security-requirements deep-dive" (blocked by T1) — if applicable
T7: "Run archivist deep-dive" (blocked by T1) — if applicable
T8: "Run product-expert deep-dive" (blocked by T1) — if applicable
T9: "Run business-analyst synthesis" (blocked by ALL deep-dive tasks)
```

Use TaskUpdate to set `addBlockedBy` relationships.

#### 2.2 Run Context Builder

**Sub-agent mode** — Use Task tool with `subagent_type: "context-builder"`:

**Team mode** — Use Task tool with `subagent_type: "context-builder"`, `team_name: "req-{identifier}"`, `name: "context-builder"`:

Prompt (same for both modes):
```
Build a structured context inventory for the following feature.

Feature: {feature_description}
Repository: {current_repo}
{IF has_brainstorm_context: "Prior brainstorm context available at: $WORK_DIR/{brainstorm_slug}/context/exploration.md and context/business-context.md — use these as your starting inventory and verify/extend rather than re-discovering from scratch."}

Create an inventory of:
1. Endpoints - existing API endpoints that may be affected
2. Services - service classes involved
3. Entities - database entities related to this feature
4. Config - environment variables and configuration
5. External APIs - third-party integrations
6. Documentation - existing docs (README, Swagger, etc.)
7. Gaps - areas where documentation is missing

Return a structured JSON inventory that downstream agents can use.
```

**Team mode extra**: Add to prompt: `"Save your output to $WORK_DIR/{identifier}/context/discovery.json. Mark task T1 as completed when done."`

Save output to `$WORK_DIR/{identifier}/context/discovery.json`

#### 2.3 Push Feature Branch to Remote

Push the branch to remote for team visibility and resume capability, now that initial context has been gathered.

**Use Task tool with `subagent_type: "git-operator"`:**

```
Prompt: Push branch feature/{identifier} to origin with upstream tracking (-u flag).
```

**VERIFICATION** (required):
```bash
if ! git rev-parse --verify origin/feature/{identifier} &>/dev/null; then
  echo "WARNING: Failed to push feature branch to remote"
  echo "Branch exists locally but not on origin"
  echo "Continuing with local branch only - remote push can be retried later"
else
  echo "✓ Branch pushed to remote: origin/feature/{identifier}"
fi
```

**Note**: Remote push failure is a WARNING, not a blocker. Requirements gathering can continue with a local branch. Update state:

```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "branches": {
    "remote_pushed": true
  }
}
```

#### 2.4 Update State

Update `state.json`:
```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "discovery": {"stage": 2, "status": "completed", "agent": "context-builder"},
    "deep_dive": {
      "stage": 3,
      "status": "in_progress",
      "agents_to_run": ["archaeologist", ...]
    }
  }
}
```

---

### Stage 3: Deep Dive (Parallel Execution)

**Goal**: Run specialized agents based on what the feature involves.

**IMPORTANT**: Run all applicable agents **in parallel** using multiple Task tool calls in a single message. This significantly reduces execution time.

#### 3.1 Determine Required Agents

Based on discovery findings, determine which agents to run.

**Always run:**

| Agent | Purpose |
|-------|---------|
| `archaeologist` | Analyze code patterns, data flow, modification risks |
| `architect` | Map architectural constraints any implementation must satisfy |

**Conditionally run based on discovery findings:**

| Condition | Agent | Purpose |
|-----------|-------|---------|
| If DB entities found in discovery | `data-modeler` | Analyze schema and relationships |
| If external APIs found in discovery | `integration-analyst` | Map API contracts |
| If AWS/cloud resources detected | `aws-architect` | Infrastructure requirements |
| If auth/sensitive data involved | `security-requirements` | Security requirements |

**Conditionally run based on project configuration:**

Check `.claude/configuration.yml` for optional integrations:

```bash
# CONFIG already resolved in the Configuration section above

# Check for requirements artifact config (enables archivist)
yq -e '.storage.artifacts.requirements' "$CONFIG" 2>/dev/null

# Check for product knowledge artifact config (enables product-expert)
yq -e '.storage.artifacts.product-knowledge' "$CONFIG" 2>/dev/null
```

| Condition | Agent | Purpose |
|-----------|-------|---------|
| `storage.artifacts.requirements` exists in configuration.yml | `archivist` | Search historical requirements for similar work |
| `storage.artifacts.product-knowledge` exists in configuration.yml | `product-expert` | Product-specific patterns and context |

#### 3.2 Run All Applicable Agents in Parallel

**Execute in a single message with multiple Task tool calls.**

**Sub-agent mode**: Each agent runs as an independent sub-agent via `Task(subagent_type=...)`.

**Team mode**: Each agent runs as a teammate via `Task(subagent_type=..., team_name="req-{identifier}", name="{agent-name}")`. Each agent's prompt gets this extra instruction:

```
Check $WORK_DIR/{identifier}/context/ for files from other agents.
If files exist from agents that completed before you, incorporate relevant findings into your analysis.
After completing your analysis, save your output to $WORK_DIR/{identifier}/context/{agent-name}.md as your FINAL action before returning.
Mark your task as completed when done.
```

**Before launching agents, distill discovery gaps into targeted questions.**

Review context-builder's discovery output for flagged gaps, inconsistencies, or open questions. Inject these as additional targeted questions into the relevant agent prompts:

- Security/auth gaps from discovery → append to security-requirements prompt: "Discovery found: {existing_pattern}. Align recommendations with this pattern or justify deviation."
- Product/business gaps from discovery → append to product-expert prompt: "Discovery flagged these questions: {questions}. Answer these specifically."
- Data state ambiguities from discovery → append to data-modeler prompt: "Discovery found config table {table}. Confirm whether per-merchant records exist or only global defaults."

This prevents broad, undirected analysis and eliminates second-pass supplements.

**Agent prompts (shared between both modes):**

Read `references/deep-dive-agent-prompts.md` for the complete prompt templates for each deep-dive agent (Tasks 1-7). Each prompt includes the template variables to fill from Stage 1-2 outputs.

#### 3.3 [TEAM MODE ONLY] Monitor and Cross-Pollinate

**Skip this step if `EXEC_MODE == "subagent"`.**

While teammates are running:

1. Monitor progress via TaskList
2. When an agent finishes, use SendMessage to notify still-running agents:
   ```
   SendMessage(
     type="message",
     recipient="{agent-name}",
     content="Findings from {completed-agent} are now available at $WORK_DIR/{identifier}/context/{completed-agent}.md. Check for relevant patterns and risks.",
     summary="{completed-agent} findings available"
   )
   ```
3. Repeat for each agent that finishes while others are still running

#### 3.4 Verify and Save Agent Outputs

For each agent that completed, verify its output file exists on disk. In team mode, agents save their own files. In sub-agent mode, the orchestrator saves them. In both modes, verify with Glob.

**Verification loop** — run for each agent that was launched:

```bash
for agent in archaeologist architect data-modeler integration-analyst aws-architect security-requirements archivist product-expert; do
  expected="$WORK_DIR/{identifier}/context/${agent}.md"
  if [[ agent was run ]]; then
    # Glob check — lightweight verification
    if [[ ! -f "$expected" ]] || [[ ! -s "$expected" ]]; then
      echo "WARNING: ${agent} output missing or empty — saving from agent response"
      # Save agent's returned content using Write tool (fallback)
    else
      echo "  ✓ ${agent}.md"
    fi
  fi
done
```

**Note**: Only `discovery.json` (context-builder) is JSON. All other agent outputs are markdown.

**Priority:** File verification MUST complete before proceeding to Stage 4 (Synthesis). Business-analyst reads files from disk — missing files cause gaps in synthesis.

**VERIFICATION** (required):
```bash
# Verify required agent outputs were saved
if [[ ! -f "$WORK_DIR/{identifier}/context/archaeologist.md" ]]; then
  echo "WARNING: Missing archaeologist output (required agent)"
  echo "This may cause issues in implementation phase"
fi

# Verify discovery.json is valid JSON (only context-builder outputs JSON)
if [[ -f "$WORK_DIR/{identifier}/context/discovery.json" ]]; then
  if ! jq empty "$WORK_DIR/{identifier}/context/discovery.json" 2>/dev/null; then
    echo "WARNING: Invalid JSON in discovery.json"
  fi
fi

# List saved context files
for file in $WORK_DIR/{identifier}/context/*; do
  if [[ -f "$file" ]] && [[ -s "$file" ]]; then
    echo "  ✓ $(basename $file)"
  fi
done

echo "✓ Agent outputs verified and saved"
```

#### 3.5 Update State

Update `state.json`:
```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "deep_dive": {"stage": 3, "status": "completed", "agents_run": ["archaeologist", ...]},
    "synthesis": {"stage": 4, "status": "in_progress", "agent": "business-analyst"}
  }
}
```

---

### Stage 4: Synthesis

**Goal**: Consolidate all findings into final requirements documents.

#### 4.1 Run Business Analyst

**Sub-agent mode** — Use Task tool with `subagent_type: "business-analyst"`.

**Team mode** — Use Task tool with `subagent_type: "business-analyst"`, `team_name: "req-{identifier}"`, `name: "business-analyst"`.

**IMPORTANT**: Do NOT inline all agent outputs into the prompt. Instead, tell the business-analyst where to find them. This avoids token overflow when many agents ran.

Prompt (same for both modes):
```
Consolidate all agent findings into final requirements.

Feature: {feature_description}
Refined Requirements: {refined_requirements}
Work directory: $WORK_DIR/{identifier}/

Agent findings are saved in the context directory. Read each file that exists:
- $WORK_DIR/{identifier}/context/discovery.json (context-builder inventory — JSON format)
- $WORK_DIR/{identifier}/context/archaeologist.md (code patterns, data flow, risks)
- $WORK_DIR/{identifier}/context/architect.md (architectural constraints, layer rules, patterns)
- $WORK_DIR/{identifier}/context/data-modeler.md (if exists - DB schema analysis)
- $WORK_DIR/{identifier}/context/integration-analyst.md (if exists - external API mapping)
- $WORK_DIR/{identifier}/context/aws-architect.md (if exists - infrastructure requirements)
- $WORK_DIR/{identifier}/context/security-requirements.md (if exists - security needs)
- $WORK_DIR/{identifier}/context/archivist.md (if exists - historical context from similar work)
- $WORK_DIR/{identifier}/context/product-expert.md (if exists - product-specific patterns)

Tasks:
1. Read all available context files above
2. Resolve any conflicts between agent findings
3. Prioritize requirements (MoSCoW)
4. Identify risks (Technical, Business, Timeline)
5. Validate against user's acceptance criteria from refinement phase
6. Note any performance considerations (queries, caching, scalability)

Produce TWO documents, separated by the exact markers shown below.

Use this EXACT format:

---BEGIN TECHNICAL_REQUIREMENTS---
(Complete technical specification for developers)
- Full implementation details
- File paths and code references
- Data schemas
- API contracts
- Error handling
- Performance requirements
---END TECHNICAL_REQUIREMENTS---

---BEGIN JIRA_TICKET---
(Light version for JIRA - business + developer overview)
- Summary (1 paragraph)
- Background (problem, impact, solution)
- Requirements (business terms)
- Acceptance criteria
- Technical notes (2-3 bullets max)
- Out of scope
---END JIRA_TICKET---

IMPORTANT: Use the exact ---BEGIN/END--- markers. They are used to extract each document into separate files.
```

**Team mode extra**: Add to prompt: `"Mark your task as completed when done."`

**Note**: Performance review is deferred to implementation phase where code-reviewer can analyze actual code changes.

#### 4.2 Save Outputs

Save all synthesis outputs to the work directory:

```bash
# Save business-analyst raw output
# Write to: $WORK_DIR/{identifier}/context/business-analyst.md

# Save the two requirement documents
# Write to: $WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md
# Write to: $WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md
```

Extract the two documents using the `---BEGIN/END---` markers:

1. Content between `---BEGIN TECHNICAL_REQUIREMENTS---` and `---END TECHNICAL_REQUIREMENTS---` → save as `$WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md`
2. Content between `---BEGIN JIRA_TICKET---` and `---END JIRA_TICKET---` → save as `$WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md`
3. Save the complete raw business-analyst response → `$WORK_DIR/{identifier}/context/business-analyst.md`

**If markers are missing**: The business-analyst did not follow the output format. Save the entire response as `{identifier}-TECHNICAL_REQUIREMENTS.md` and log a warning that JIRA ticket was not separately extracted.

**VERIFICATION** (required):
```bash
# Verify technical requirements doc was saved
if [[ ! -f "$WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md" ]]; then
  echo "ERROR: Technical requirements document not saved"
  exit 1
fi

# Verify JIRA ticket doc was saved
if [[ ! -f "$WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md" ]]; then
  echo "WARNING: JIRA ticket not separately extracted - check TECHNICAL_REQUIREMENTS.md"
fi

# Verify business-analyst output was saved
if [[ ! -f "$WORK_DIR/{identifier}/context/business-analyst.md" ]]; then
  echo "WARNING: Business analyst raw output not saved to context/"
fi

echo "✓ All synthesis outputs saved"
```

#### 4.5 Resolve Flagged Issues (Conditional)

**Goal**: If the business-analyst flagged contradictions, coverage gaps, or unresolved assumptions in its "Challenge & Cross-Validate" section, resolve them by spawning targeted re-analysis agents.

**Check for flags**: Read the saved business-analyst output at `$WORK_DIR/{identifier}/context/business-analyst.md`. Look for:
- Explicit contradiction flags between agent findings
- Coverage gaps (areas no agent analyzed)
- Challenged assumptions or severity mismatches

**If NO flags found**: Update state and skip to Stage 4.9 (Update Final State).

```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "resolve_flags": {"stage": 4.5, "status": "skipped", "reason": "no flags found"}
  }
}
```

**If flags found**: Continue with targeted re-analysis.

Update state:
```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "resolve_flags": {"stage": 4.5, "status": "in_progress", "flags_found": ["contradiction: ...", "gap: ...", "assumption: ..."]}
  }
}
```

##### Sub-agent Mode (`EXEC_MODE == "subagent"`)

For each flagged issue, identify which agent(s) from Stage 3 need to provide targeted clarification. Spawn them **in parallel** via Task tool calls in a single message.

**IMPORTANT**: Do NOT re-run general analysis. Each prompt must be a SPECIFIC question about the flagged issue.

Example prompts:

```
Task 1 (contradiction resolution): subagent_type: "{agent-name}"
Prompt: Your finding about {Agent A's position} conflicts with {Agent B's finding}.
Specifically: {describe the contradiction}.
Analyze whether these two approaches can coexist, and recommend a compatible approach.
If they cannot coexist, recommend which approach should take priority and why.

Task 2 (coverage gap): subagent_type: "{appropriate-agent}"
Prompt: During synthesis, a coverage gap was identified: {describe the gap}.
No agent analyzed {gap area}. Investigate this specific area and provide findings:
- What exists currently in the codebase for {gap area}
- What changes are needed for the feature
- What risks does this gap introduce

Task 3 (assumption challenge): subagent_type: "{agent-name}"
Prompt: Your analysis assumed {describe assumption}. This assumption was challenged because {reason}.
Verify whether this assumption holds. If it does not, re-analyze your recommendation
for {specific area} under the corrected assumption.
```

Save each targeted response to `$WORK_DIR/{identifier}/context/{agent-name}-reanalysis.md`.

##### Team Mode (`EXEC_MODE == "team"`)

Business-analyst sends targeted messages to relevant agents via SendMessage:

```
SendMessage(
  type="message",
  recipient="{agent-name}",
  content="Your finding about {issue} conflicts with {other agent's finding}. {specific question}. Please respond with your clarification.",
  summary="Resolve: {brief issue description}"
)
```

Collect responses from agents. Save each to `$WORK_DIR/{identifier}/context/{agent-name}-reanalysis.md`.

##### Save and Update State

**VERIFICATION** (required):
```bash
# List re-analysis files
for file in $WORK_DIR/{identifier}/context/*-reanalysis.md; do
  if [[ -f "$file" ]] && [[ -s "$file" ]]; then
    echo "  ✓ $(basename $file)"
  fi
done

echo "✓ Targeted re-analysis outputs saved"
```

Update state:
```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "resolve_flags": {"stage": 4.5, "status": "completed", "agents_rerun": ["agent-name", ...]}
  }
}
```

#### 4.6 Re-Synthesis (Conditional)

**Goal**: Re-run business-analyst to incorporate targeted re-analysis findings. Only runs if Stage 4.5 (Resolve Flagged Issues) executed.

**If Stage 4.5 was skipped**: Skip this stage too.

```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "re_synthesis": {"stage": 4.6, "status": "skipped", "reason": "no flags to resolve"}
  }
}
```

**If Stage 4.5 ran**: Continue with re-synthesis.

Update state:
```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "re_synthesis": {"stage": 4.6, "status": "in_progress", "agent": "business-analyst"}
  }
}
```

##### Run Business Analyst (Re-Synthesis Pass)

Read `references/re-synthesis-prompt.md` for the complete re-synthesis business-analyst prompt template. Use it with sub-agent or team mode as appropriate.

##### Save Re-Synthesis Outputs

Overwrite the original synthesis outputs with the updated versions:

```bash
# Overwrite business-analyst raw output
# Write to: $WORK_DIR/{identifier}/context/business-analyst.md

# Overwrite the two requirement documents
# Write to: $WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md
# Write to: $WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md
```

Extract using the same `---BEGIN/END---` marker logic as Stage 4.2.

**If markers are missing**: Save the entire response as `{identifier}-TECHNICAL_REQUIREMENTS.md` and log a warning.

**VERIFICATION** (required):
```bash
# Verify re-synthesized documents were saved
if [[ ! -f "$WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md" ]]; then
  echo "ERROR: Re-synthesized technical requirements not saved"
  exit 1
fi

if [[ ! -f "$WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md" ]]; then
  echo "WARNING: Re-synthesized JIRA ticket not separately extracted"
fi

echo "✓ Re-synthesis outputs saved (overwriting initial synthesis)"
```

##### Update State

```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "re_synthesis": {"stage": 4.6, "status": "completed", "agent": "business-analyst"}
  }
}
```

**One pass only.** If issues persist after re-synthesis, they are documented in the requirements as "REQUIRES HUMAN DECISION" sections. No further iteration occurs.

#### 4.7 Architecture Validation (Optional)

**Goal**: For requirements that touch shared/core services, introduce new injection patterns, or modify global config scope — validate the business-analyst's conflict resolutions before declaring requirements complete.

**When to run**: Check the TECHNICAL_REQUIREMENTS output. If any of these conditions are true, run this step:
- Requirements modify shared/core services used by multiple features
- Requirements introduce new dependency injection or service wiring patterns
- Requirements change global configuration scope or environment variables

**If none of the conditions are met**: Skip this stage.

**Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Validate the architectural decisions in these requirements.

Requirements: $WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md

Focus on:
1. Are conflict resolutions between agents architecturally sound?
2. Do proposed patterns align with existing codebase architecture?
3. Are there hidden coupling or scaling concerns?

If you find issues, recommend specific corrections.
Return: Validation result (APPROVED / CONCERNS) with details.
```

**If CONCERNS raised**: Present to user via AskUserQuestion with the architect's feedback. Allow the user to accept, modify, or override.

Save architect output to `$WORK_DIR/{identifier}/context/architect-validation.md`.

#### 4.8 Skeptic Validation

**Goal**: Challenge the synthesized requirements through an independent adversarial review before declaring them complete.

**Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Review these synthesized requirements as a skeptic challenger.

Requirements document: $WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md
JIRA ticket: $WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md
Agent context files: $WORK_DIR/{identifier}/context/

Your job:
1. Read the TECHNICAL_REQUIREMENTS and JIRA_TICKET documents
2. Cross-reference claims against the actual codebase — verify file paths, patterns, and assumptions
3. Check for: unstated assumptions, missing edge cases, vague acceptance criteria, scope gaps, contradictions
4. Produce a Quality Review Gates report

Focus on Level 1 (Requirements Validation). Do NOT review implementation code — there is none yet.
```

**Process the skeptic's verdict:**

- **APPROVED**: Continue to completion. Log: `"skeptic_verdict": "approved"`
- **CONDITIONAL**: Present the blocking gates to the user via AskUserQuestion. The user decides whether to:
  - **Address gates**: Re-run targeted agents (like Stage 4.5) to resolve, then re-run skeptic
  - **Override**: Accept requirements as-is, note overridden gates in state
  - **Abort**: Stop and revisit requirements
- **REJECTED**: Present fundamental issues to the user. Requirements need rework — return to appropriate stage.

**Max iterations**: 2. If skeptic raises gates, agents address them, and skeptic still has concerns after a second pass, document remaining concerns as "OPEN QUESTIONS" in the TECHNICAL_REQUIREMENTS and proceed.

Save skeptic output to `$WORK_DIR/{identifier}/context/quality-guard.md`.

Update state:
```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "skeptic_validation": {
      "stage": 4.8,
      "status": "completed",
      "verdict": "approved|conditional_override|conditional_resolved",
      "gates_raised": 3,
      "gates_resolved": 3,
      "iterations": 1
    }
  }
}
```

#### 4.8.5 [TEAM MODE ONLY] Shutdown Team

**Skip this step if `EXEC_MODE == "subagent"`.**

Send shutdown requests to all teammates:

```
SendMessage(type="shutdown_request", recipient="context-builder", content="Work complete")
SendMessage(type="shutdown_request", recipient="archaeologist", content="Work complete")
... (for each spawned teammate)
```

After all teammates have shut down:

```
TeamDelete()
```

Update state:
```json
{
  "team": {
    "name": "req-{identifier}",
    "created": true,
    "deleted": true
  }
}
```

#### 4.9 Update Final State

Update `state.json`:

```json
{
  "status": "completed",
  "completed_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",

  "stages": {
    "setup":     {"stage": 1, "status": "completed"},
    "discovery": {"stage": 2, "status": "completed"},
    "deep_dive":     {"stage": 3, "status": "completed", "agents_run": [...]},
    "synthesis":     {"stage": 4, "status": "completed"},
    "resolve_flags": {"stage": 4.5, "status": "completed|skipped"},
    "re_synthesis":  {"stage": 4.6, "status": "completed|skipped"},
    "architecture_validation": {"stage": 4.7, "status": "completed|skipped", "conditional": true},
    "skeptic_validation": {"stage": 4.8, "status": "completed", "verdict": "..."}
  },

  "outputs": {
    "technical_requirements": "{identifier}-TECHNICAL_REQUIREMENTS.md",
    "jira_ticket": "{identifier}-JIRA_TICKET.md"
  }
}
```

#### 4.10 Update Work Manifest (Final)

Update the work manifest to reflect completion (see [docs/manifest-system.md](../../docs/manifest-system.md)).

Upsert item using `identifier` as unique key with updated fields:

```json
{
  "identifier": "{identifier}",
  "title": "{feature_description_summary}",
  "type": "requirements",
  "status": "completed",
  "created_at": "{from_state}",
  "updated_at": "{ISO_TIMESTAMP}",
  "current_phase": "completed",
  "progress": "Stage 4/4 (feedback loop: completed|skipped)",
  "branch": "feature/{identifier}",
  "tags": [],
  "path": "{identifier}/"
}
```

#### 4.11 Report Completion

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Requirements Complete: {identifier}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Feature: {title}
Branch: feature/{identifier}
Base: {base_branch}
Mode: {EXEC_MODE} {if team: "(cross-pollination enabled)"}

Work Directory: $WORK_DIR/{identifier}/

Output Files:
  - {identifier}-TECHNICAL_REQUIREMENTS.md
  - {identifier}-JIRA_TICKET.md

Agents Used:
  ✓ context-builder (discovery) {if team: "[teammate]"}
  ┌ ✓ archaeologist (code analysis) {if team: "[teammate]"}
  │ {✓ data-modeler - if used}
  │ {✓ integration-analyst - if used}
  │ {✓ aws-architect - if used}          [PARALLEL]
  │ {✓ security-requirements - if used}
  │ {✓ archivist - if used}
  └ {✓ product-expert - if used}
  ✓ business-analyst (synthesis) {if team: "[teammate]"}
  {if feedback loop ran:}
  ┌ {✓ agent-name (re-analysis: contradiction) - for each}
  └ {✓ agent-name (re-analysis: gap/assumption) - for each}  [FEEDBACK]
  ✓ business-analyst (re-synthesis)
  {end if}
  ✓ quality-guard (validation: {verdict})
    Gates: {gates_resolved}/{gates_raised} resolved

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Requirements are complete. This skill has finished.

Next Steps (for YOU to run when ready):
  1. Implement: /implement $WORK_DIR/{identifier}/
  2. Resume later: /resume-work {identifier}
```

**STOP HERE. Do not enter plan mode. Do not propose implementation. Do not ask to proceed with implementation. The user will invoke `/implement` when ready.**

---

## Error Handling

Read `references/error-handling.md` for error recovery procedures (branch creation fails, agent fails, team creation fails, remote push fails). All error recovery uses AskUserQuestion.

---

## Quality Checklist

Read `references/quality-checklist.md` for the full stage-by-stage verification checklist.
