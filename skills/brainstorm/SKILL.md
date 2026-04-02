---
name: brainstorm
category: planning
model: opus
userInvocable: true
description: Explore implementation strategies for business requirements. Interactive brainstorming that presents multiple approaches, trade-offs, and creates high-level implementation picture before committing to detailed specs.
argument-hint: [--light] [feature-description] | promote <slug> [ticket-id]
allowed-tools: Read, Write, Glob, Grep, Bash(git:*), Bash(mkdir:*), Bash(jq:*), Bash(yq:*), Task, AskUserQuestion
---

# Brainstorm Implementation

Transform brief business requirements into clear implementation strategy through interactive exploration.

## Purpose

This skill sits in the **early thinking phase** - after you get business requirements but before you commit to detailed technical specs. It helps you:

1. Explore different ways to implement something
2. Understand trade-offs between approaches
3. Get a clear picture of what implementation looks like
4. Outline tickets/work items needed

**Use this when:** You have a business request and want to think through implementation options.

**Don't use this when:** You already know the approach and need detailed specs (use `/create-requirements` instead).

## Context

Current directory: !`pwd`

Git status: !`git status --short 2>/dev/null || echo "Not a git repository"`

Arguments: $ARGUMENTS

---

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work sessions |

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
```

Use `$WORK_DIR` instead of hardcoded `.claude/work` throughout this workflow.

**Important:** All path references in this skill MUST use `$WORK_DIR`. Never use hardcoded `.claude/work/` paths.

---

## Promote Subcommand

If `$ARGUMENTS` begins with `promote`, handle the promote flow instead of normal brainstorm.

**Syntax:** `/brainstorm promote {slug} [{ticket-id}]`

**Behavior:**

1. Parse `$ARGUMENTS`: extract `{slug}` (word after "promote") and optional `{ticket-id}` (next word).
2. Verify `$WORK_DIR/{slug}/state.json` exists. If not found, output error and stop:
   ```
   Error: Brainstorm session not found: {slug}
   Available sessions:
   {list from manifest.json or $WORK_DIR/ dirs}
   ```
3. Read `state.json`. Warn if `"status"` is already `"promoted"`:
   ```
   Warning: This brainstorm is already promoted to {promoted_to}.
   Re-promote? [y/n]
   ```
   Use AskUserQuestion. On **n**: stop.

4. If `{ticket-id}` was not provided, ask:
   ```
   AskUserQuestion: Enter the ticket/identifier for this work (e.g., PROJ-123 or leave blank to use the brainstorm slug as draft):
   ```
   If blank, use `{slug}` as the identifier.

5. **Update brainstorm state** (`$WORK_DIR/{slug}/state.json`):
   ```json
   {
     "status": "promoted",
     "promoted_to": "{ticket-id}",
     "updated_at": "{ISO_TIMESTAMP}"
   }
   ```
   Merge these fields into the existing JSON (preserve all other fields).

6. **Update manifest** (`$WORK_DIR/manifest.json`) — find the entry where `identifier == {slug}`, update `status` to `"promoted"` and add `promoted_to`.

7. Announce:
   ```
   Brainstorm '{slug}' promoted → {ticket-id}

   Launching /create-requirements with brainstorm context pre-loaded...
   ```

8. Continue directly into Stage 1 of the `create-requirements` workflow with:
   - `--from-brainstorm {slug}` flag effectively active
   - `{identifier}` pre-set to `{ticket-id}` (skip the identifier prompt in Stage 1.1)
   - Brainstorm context loaded per Stage 1.3b

   To achieve this, output the following instruction and stop — do not run the full brainstorm phases:
   ```
   Run: /create-requirements --from-brainstorm {slug} {ticket-id}
   ```
   Then stop. The user will run this, or you may invoke the create-requirements workflow inline if the tool allows it.

---

## Lightweight Mode

If `$ARGUMENTS` begins with `--light`, strip the flag and enable lightweight mode:

- Output to user: "Lightweight mode enabled: all agents use Sonnet."
- **Explore agent**: unchanged (already Sonnet)
- **business-analyst**: spawn with model **sonnet** instead of opus (only meaningful downgrade)
- **Plan agent**: unchanged (already Sonnet)
- **architect**: unchanged (already Sonnet)
- All orchestration flow and output formats remain identical

This reduces cost for exploratory brainstorming where deep reasoning is less critical than in requirements or implementation.

---

## Workflow

### Phase 0: Check for Existing Session

Before starting, check whether an active brainstorm session already exists for this topic.

```bash
# Check manifest for active brainstorm sessions
if [[ -f "${WORK_DIR}/manifest.json" ]]; then
  jq -r '.items[] | select(.type == "brainstorm" and .status != "completed") | "\(.identifier)\t\(.title)\t\(.current_phase)\t\(.updated_at)"' "${WORK_DIR}/manifest.json"
fi
```

**If active sessions exist AND an argument was provided:**
Check whether any session identifier or title fuzzy-matches `$ARGUMENTS`. If a match is found, present it:

```
Found active brainstorm: {title} ({identifier})
Status: {current_phase} — last updated {updated_at}

Resume this session? [y] Yes  [n] No, start fresh  [s] Show status
```

Use AskUserQuestion. On **yes**: load state from `$WORK_DIR/{identifier}/state.json` and resume from the last incomplete phase. On **show status**: display phase completion table, then ask again. On **no**: continue to Phase 1.

**If no argument and active sessions exist:** Skip this check — Phase 1 will ask for the feature description and can detect duplicates at that point.

**If no active sessions:** Proceed directly to Phase 1.

---

### Phase 1: Capture Requirements

#### 1.1 Get Feature Description

**From $ARGUMENTS:**
- If provided → Use as feature description
- If empty → Use AskUserQuestion:

```
What feature or change do you want to brainstorm?

Provide a brief description (1-3 sentences):
- What problem are you solving?
- What does the business want?
- Any key constraints?

Examples:
- "Users need to export their data to Excel"
- "Integrate SSO with Azure AD for authentication"
- "Add webhook notifications when orders complete"
```

Store as `{feature_description}`.

#### 1.2 Gather Business Context

Use AskUserQuestion to understand context:

```
Questions:
1. What's the business driver?
   - New customer requirement
   - Compliance/regulatory need
   - Performance issue
   - User experience improvement
   - Technical debt reduction

2. What's the urgency?
   - Critical (blocking customers)
   - High (planned for next sprint)
   - Medium (on roadmap)
   - Low (nice to have)

3. Any known constraints?
   - Must use specific technology
   - Budget limitations
   - Timeline restrictions
   - Integration requirements
```

#### 1.3 Create Work Directory and State File

```bash
mkdir -p $WORK_DIR/{slug}/context
```

Where `{slug}` is kebab-case version of feature (e.g., "user-data-export").

Initialize state file `$WORK_DIR/{slug}/state.json`:

```json
{
  "schema_version": 1,
  "identifier": "{slug}",
  "type": "brainstorm",
  "title": "{feature_description_summary}",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "selected_approach": null,
  "phases": {
    "exploration": {"status": "pending"},
    "approaches": {"status": "pending"},
    "refinement": {"status": "pending"},
    "quality_guard": {"status": "pending"},
    "work_breakdown": {"status": "pending"}
  },
  "outputs": {
    "exploration": "context/exploration.md",
    "business_context": "context/business-context.md",
    "approaches": "context/approaches.md",
    "architecture_validation": "context/architecture-validation.md",
    "implementation_picture": "implementation-picture.md",
    "work_breakdown": "work-breakdown.md",
    "summary": "brainstorm-summary.md"
  },
  "updates": []
}
```

---

### Phase 2: Exploration

**Goal:** Understand what exists and what's needed.

#### 2.1 Explore Codebase

Use Task tool with `subagent_type: "Explore"`:

```
Prompt: Explore the codebase to understand existing patterns for this feature.

Feature: {feature_description}

Find:
1. Similar features already implemented
2. Existing patterns we should follow
3. Related entities, services, controllers
4. External integrations or APIs involved
5. Existing infrastructure that could be leveraged

**Depth limit:** Describe interfaces and patterns — method signatures, key properties, how the system works conceptually. Do not reproduce full method implementations or dump complete file contents. One example of an existing pattern is sufficient. Full code reads are for implementation phases.

Provide file paths and interface descriptions of relevant existing implementations.
```

Save output to `$WORK_DIR/{slug}/context/exploration.md`. Update state: `phases.exploration = completed`.

#### 2.2 Understand Business Requirements

Use Task tool with `subagent_type: "business-analyst"`:

```
Prompt: Analyze business requirements for this feature.

Feature: {feature_description}
Business Context: {from_phase_1}

Analyze:
1. Core problem being solved
2. User personas affected
3. Success metrics
4. Edge cases to consider
5. Assumptions to validate

Provide a structured business context summary.
```

Save output to `$WORK_DIR/{slug}/context/business-context.md`. Update state: `phases.exploration = completed` (covers both exploration agents).

**Before launching parallel agents, define non-overlapping scopes.** Each agent should own one domain of knowledge with no shared territory. Split by system/component boundary, not by feature keyword. Example:
- Agent 1 (Explore): "How does {system A} work — services, commands, flags, data flow"
- Agent 2 (business-analyst): "Business requirements — problem, personas, success metrics, edge cases"

Do NOT include supporting context from one agent's domain in the other's prompt.

**Run both agents in parallel.**

---

### Phase 3: Generate Approaches

**Goal:** Present 2-3 different ways to implement this feature.

#### 3.1 Brainstorm Implementation Options

Use Task tool with `subagent_type: "Plan"`:

```
Prompt: Design 2-3 different implementation approaches for this feature.

Feature: {feature_description}
Codebase patterns: {from_exploration}
Business requirements: {from_business_analyst}

For each approach, document:
1. **Name** - Short descriptive name
2. **Architecture** - How it's structured (components, layers)
3. **Technology choices** - Libraries, frameworks, services
4. **Pros** - Benefits of this approach
5. **Cons** - Drawbacks and risks
6. **Complexity** - Estimated complexity (Simple | Moderate | Complex)
7. **Timeline** - Rough estimate (Days | Weeks | Months)

Approaches must differ architecturally — in where logic lives, which layer enforces it, what triggers the check, or what system boundary it crosses. Do not present parameter-count or flag-count variants of the same architecture as separate approaches. If two approaches share the same component placement, migration path, and check points, merge them into one approach with a granularity sub-option.

Trade-off dimensions:
- Where the logic lives (service layer vs middleware vs database)
- Extension point (existing component vs new component)
- Synchronous vs asynchronous
- Configuration-driven vs code-driven

Provide 2-3 distinct, viable approaches.
```

Save output to `$WORK_DIR/{slug}/context/approaches.md`. Update state: `phases.approaches = in_progress`.

#### 3.1b Validate Architecture Context

**Run in PARALLEL with 3.1** — the architect works from exploration context, not from Plan's approaches.

Use Task tool with `subagent_type: "architect"`:

```
Prompt: Analyze the project's architectural constraints and patterns relevant to this feature.

Feature: {feature_description}
Codebase patterns: {from exploration.md}

Assess:
1. Architecture style in use (layered, hexagonal, modular, MVC) and its constraints
2. Established patterns that any implementation MUST follow
3. Integration points and their architectural boundaries
4. Known technical debt or fragile areas to avoid
5. Scalability constraints relevant to this feature

Provide:
- A list of architectural constraints any approach must satisfy
- Patterns that must be followed (with file path examples)
- Risk areas to avoid
- A feasibility checklist for evaluating approaches
```

Save output to `$WORK_DIR/{slug}/context/architecture-validation.md`.

**IMPORTANT: Wait for both 3.1 (Plan agent) and 3.1b (architect) to complete before proceeding.** After both complete: Annotate each approach from 3.1 with architect constraints from 3.1b. Flag any approach that violates identified constraints. Add feasibility rating: Recommended / Feasible / Risky / Not Recommended.

#### 3.2 Present Approaches to User

Display the approaches in a clear format:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Implementation Approaches: {feature}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### Approach 1: {Name}
Complexity: {Simple|Moderate|Complex} | Timeline: {estimate}

**Architecture:**
{high-level description}

**Pros:**
✓ {benefit 1}
✓ {benefit 2}

**Cons:**
✗ {drawback 1}
✗ {drawback 2}

**Best for:** {when to choose this approach}

---

### Approach 2: {Name}
...

---

### Approach 3: {Name}
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 3.3 Get User Feedback

Use AskUserQuestion:

```
Which approach interests you most?

1. {Approach 1 name}
2. {Approach 2 name}
3. {Approach 3 name}
4. Combination of approaches
5. None - need different options

Or provide specific feedback on what you like/dislike.
```

Update state with selected approach: `"selected_approach": "{approach_name}", "phases.approaches": "completed"`.

---

### Phase 4: Refine & Iterate

**Goal:** Refine the chosen approach based on feedback.

#### 4.1 Deep Dive on Selected Approach

Based on user selection, use Task tool with `subagent_type: "Plan"`:

```
Prompt: Refine and detail the selected approach.

Feature: {feature_description}
Selected Approach: {approach_name}
User Feedback: {feedback_from_user}

Create a detailed implementation picture:

1. **Component Breakdown**
   - Controllers (which endpoints)
   - Services (what business logic)
   - Entities (database tables)
   - Models (request/response objects)
   - External integrations

2. **Data Flow**
   - Step-by-step request/response flow
   - Data transformations
   - State changes

3. **Database Changes**
   - New tables needed
   - Migrations required
   - Indexes for performance

4. **API Design** (if applicable)
   - Endpoints
   - Request/response formats
   - Error cases

5. **Security Considerations**
   - Authentication/authorization
   - Data validation
   - Sensitive data handling

6. **Testing Strategy**
   - Unit tests
   - Integration tests
   - Manual testing steps

Provide a clear, detailed implementation picture.
```

Save to `$WORK_DIR/{slug}/implementation-picture.md`. Update state: `phases.refinement = completed`.

#### 4.2 Validate Architecture

Use Task tool with `subagent_type: "architect"`:

```
Prompt: Validate this implementation approach against architecture rules.

Implementation plan: {from_phase_4.1}

Check:
1. Follows project architectural patterns
2. Proper layer separation
3. Appropriate file structure
4. Integration points are sound
5. Scalability concerns addressed

Identify any architectural risks or violations.
Suggest improvements if needed.
```

**Run architect AFTER Plan refinement completes** — architect needs the refined implementation picture from 4.1 to validate effectively.

#### 4.3 Present Refined Approach

Show the detailed implementation picture:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Implementation Picture: {approach_name}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Components

**Controllers:**
- {Controller1} - {purpose}
- {Controller2} - {purpose}

**Services:**
- {Service1} - {business logic}
- {Service2} - {business logic}

**Entities:**
- {Entity1} - {table/fields}
- {Entity2} - {table/fields}

**External APIs:**
- {API1} - {integration points}

## Data Flow

1. {Step 1}
2. {Step 2}
3. {Step 3}
...

## Database Changes

- Migration: Create {table_name}
  - field1: type
  - field2: type
  - index on (field1, field2)

## API Endpoints

### POST /api/path
Request: {...}
Response: {...}
Errors: {...}

## Security

- {Security consideration 1}
- {Security consideration 2}

## Testing

- Unit: {what to test}
- Integration: {what to test}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 4.4 Ask if More Refinement Needed

Use AskUserQuestion:

```
Is this implementation picture clear?

1. Yes, I understand the approach
2. Need more detail on specific area (tell me which)
3. Want to explore a different approach
4. Ready to outline work items
```

If user wants more detail, repeat refinement on specific areas.

---

### Phase 4.5: Quality Guard Validation

**Goal**: Independently challenge the implementation picture before committing to the work breakdown.

Use Task tool with `subagent_type: "quality-guard"`:

```
Prompt: Challenge this implementation picture for '{feature_description}'.

Read these files:
- $WORK_DIR/{slug}/implementation-picture.md
- $WORK_DIR/{slug}/context/architecture-validation.md
- $WORK_DIR/{slug}/context/approaches.md
- $WORK_DIR/{slug}/context/exploration.md (if exists)

Review:
1. Is the selected approach architecturally sound? Does it match the architectural constraints found in the codebase?
2. Are all component boundaries clearly defined with no hidden overlap or missing pieces?
3. What assumptions were made that weren't verified against actual code?
4. Are there missing components, edge cases, or failure modes not captured?
5. Is the scope realistic, or does it need further decomposition?
6. Are any stated trade-offs real, or are they assumptions?

Return: APPROVED / CONDITIONAL / REJECTED
- APPROVED: No blocking concerns.
- CONDITIONAL: List specific concerns that should be noted in work breakdown.
- REJECTED: Fundamental issue — describe what must change before proceeding.
```

**Process the verdict:**

- **APPROVED**: Update state `phases.quality_guard = completed/approved`. Proceed to Phase 5.
- **CONDITIONAL**: Present concerns to user. Annotate them in the work breakdown as risks. Update state `phases.quality_guard = completed/conditional`. Proceed to Phase 5.
- **REJECTED**: Present the fundamental issue to the user via AskUserQuestion. Options:
  1. Return to Phase 3 to select/refine a different approach
  2. Override and proceed (user accepts the risk)

Save quality-guard output to `$WORK_DIR/{slug}/context/quality-guard.md`. Update state: `phases.quality_guard = completed`.

---

### Phase 5: Work Breakdown

**Goal:** Outline tickets/tasks needed.

#### 5.1 Break Down Into Work Items

Based on the implementation picture, create logical work items:

```markdown
## Work Items

### 1. Database Schema
**Type:** Database
**Description:** Create migrations for new entities
**Files affected:**
- migrations/Version{timestamp}.php
- Entity/{Entity1}.php
- Entity/{Entity2}.php

**Dependencies:** None
**Estimate:** Small (< 1 day)

---

### 2. Service Layer
**Type:** Backend
**Description:** Implement core business logic
**Files affected:**
- Service/{Feature}/{ServiceName}.php
- Tests/Service/{Feature}/{ServiceName}Test.php

**Dependencies:** #1 (Database Schema)
**Estimate:** Medium (1-2 days)

---

### 3. API Endpoints
**Type:** Backend
**Description:** Create REST endpoints
**Files affected:**
- Controller/{Feature}/{HTTPMethod}Controller.php
- Model/{Feature}/{HTTPMethod}Request.php
- Model/{Feature}/{HTTPMethod}Response.php

**Dependencies:** #2 (Service Layer)
**Estimate:** Medium (1-2 days)

---

{Additional work items...}
```

Save to `$WORK_DIR/{slug}/work-breakdown.md`. Update state: `phases.work_breakdown = completed`.

#### 5.2 Create Visual Summary

Generate ASCII diagram showing relationships:

```
Work Item Flow:

[1] Database Schema
     ↓
[2] Service Layer
     ↓
[3] API Endpoints
     ↓
[4] Frontend (if applicable)

Parallel work:
- [5] External API Integration (independent)
- [6] Documentation (can start anytime)

Estimated total: {X} days/weeks
```

#### 5.3 Present Work Breakdown

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Work Breakdown: {feature}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total Items: {N}
Estimated Effort: {X} days/weeks

{work_items_summary}

{visual_flow_diagram}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Files Created:

$WORK_DIR/{slug}/
├── state.json
├── context/
│   ├── exploration.md
│   ├── business-context.md
│   ├── approaches.md
│   ├── architecture-validation.md
│   └── quality-guard.md
├── implementation-picture.md
├── work-breakdown.md
└── brainstorm-summary.md

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next Steps:

1. Review the work breakdown
2. Create detailed requirements: /create-requirements --from-brainstorm {slug}
3. Or break into epic: /epic "{feature}"
4. Or start implementing first item directly

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

### Phase 5.5: Update Manifest

After saving all brainstorm outputs, update the brainstorms manifest.

**Read or initialize** `${WORK_DIR}/manifest.json` (see [docs/manifest-system.md](../../docs/manifest-system.md)):

```bash
MANIFEST="${WORK_DIR}/manifest.json"
# Initialize if missing
if [[ ! -f "$MANIFEST" ]]; then
  # Create empty manifest with artifact_type: "work"
fi
```

**Upsert item** using `identifier` (the slug) as unique key:

```json
{
  "identifier": "{slug}",
  "title": "{feature_description_summary}",
  "type": "brainstorm",
  "status": "completed",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "current_phase": "completed",
  "progress": "Brainstorm complete",
  "branch": null,
  "tags": [],
  "path": "{slug}/"
}
```

Update `last_updated` and `total_items` in the envelope.

---

### Phase 6: Create Summary

Write a comprehensive summary document:

**`$WORK_DIR/{slug}/brainstorm-summary.md`:**

```markdown
# Brainstorm Summary: {feature}

**Date:** {timestamp}
**Status:** Completed

## Business Context

{summary_from_phase_2}

## Approaches Considered

### Approach 1: {name}
{brief_description}
**Outcome:** {Selected | Rejected - why}

### Approach 2: {name}
{brief_description}
**Outcome:** {Selected | Rejected - why}

## Selected Approach: {name}

### Why This Approach?
{rationale}

### Implementation Picture

**Components:**
{list}

**Data Flow:**
{steps}

**Database:**
{changes}

**APIs:**
{endpoints}

### Work Breakdown

{work_items_summary}

**Total Effort:** {estimate}

## Risks & Considerations

- Risk 1: {description}
  - Mitigation: {how to address}

- Risk 2: {description}
  - Mitigation: {how to address}

## Next Steps

1. {action 1}
2. {action 2}
3. {action 3}

## Decision Log

- **{Date}:** Selected {approach_name} because {reason}
- **{Date}:** Decided to {decision} based on {rationale}

## References

- Codebase examples: {file_paths}
- Related features: {links}
- External docs: {urls if any}
```

Update state: `"status": "completed", "updated_at": "{ISO_TIMESTAMP}"`.

---

## Key Features

### Interactive & Iterative
- Asks questions to understand context
- Presents options, gets feedback
- Refines based on user input
- Doesn't commit prematurely

### Multiple Perspectives
- Business analyst view (why?)
- Architect view (how?)
- Explorer view (what exists?)
- Planning view (trade-offs?)

### Output Formats
- **Markdown files** - Easy to read and version control
- **Visual diagrams** - ASCII art showing relationships
- **Work breakdowns** - Ready to convert to tickets

### Smooth Transitions
- Can feed into `/create-requirements`
- Can scale up to `/epic` for large efforts
- Can lead directly to implementation

---

## Error Handling

**No feature description:**
```
Error: Feature description required.

Usage:
  /brainstorm "Add user data export to Excel"
  /brainstorm "Integrate Azure AD SSO"

Or run /brainstorm and I'll ask you interactively.
```

**Feature too vague:**
```
The description is quite vague. Let me ask some questions to clarify...

[Proceed to Phase 1.2 for detailed questions]
```

**All approaches rejected:**
```
It seems none of these approaches fit your needs.

Let me ask a few questions to better understand what you're looking for...

[Return to exploration with new constraints]
```

---

## Important Notes

- **Non-committal** - Brainstorming doesn't create branches or modify code
- **Lightweight** - Files saved to `$WORK_DIR/` for reference only
- **Flexible** - Can iterate multiple times before moving forward
- **Educational** - Explains trade-offs to help decision-making
- **Transition-ready** - Outputs can feed into next workflow stage

---

## Workflow Integration

```
Business Request
      ↓
/brainstorm ← [You are here]
      ↓
   Decision: What next?
      ↓
      ├─→ /create-requirements (single feature)
      ├─→ /epic (large initiative, multiple tickets)
      ├─→ /create-proposal (formal proposal needed)
      └─→ Direct implementation (simple, well-understood)
```

---

## Tips for Success

1. **Start broad** - Don't commit to details too early
2. **Explore options** - Consider at least 2 approaches
3. **Ask questions** - Better to clarify than assume
4. **Think trade-offs** - Every approach has pros and cons
5. **Stay flexible** - Willing to pivot based on findings
6. **Document decisions** - Record why you chose an approach
7. **Involve stakeholders** - Use this as basis for discussion
