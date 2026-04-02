---
name: create-proposal
category: planning
model: opus
userInvocable: true
description: Create a formal design document for a feature or component. Guides through requirements, approach brainstorming, and iterative proposal drafts with approval gate before optional implementation. Use when you need a written design approved before committing to code.
argument-hint: [proposal-name or identifier]
allowed-tools: "Read, Write, Edit, Glob, Grep, Bash(git:*), Bash(mkdir:*), Bash(yq:*), Bash(grep:*), Bash(cp:*), Task, AskUserQuestion"
---

# Create Proposal

## Context

Current directory: !`pwd`
Git branch: !`git branch --show-current 2>/dev/null || echo "not a git repo"`
Arguments: $ARGUMENTS

---

This skill guides you through creating comprehensive technical proposals for new features, components, or workflows. It adapts to your project's technology stack and follows a structured 5-phase approach with **state persistence** to enable resuming interrupted work.

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work state and context |
| `storage.artifacts.proposals` | `location: local, subdir: proposals` | Final proposal output |

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
PROPOSALS_DIR=$(resolve_artifact proposals proposals)
```

Use `$WORK_DIR` and `$PROPOSALS_DIR` instead of hardcoded paths throughout this workflow.

**Important:** All path references in this skill MUST use `$WORK_DIR` and `$PROPOSALS_DIR` variables. Never use hardcoded `.claude/work/` or `.claude/proposals/` paths.

---

## When to Use This Skill

Use this skill when the user wants to:
- Plan and document a new feature or change
- Design a new feature or component (e.g., SSO integration, payment system)
- Plan a new API endpoint or workflow
- Architect a database schema or entity structure
- Implement authentication or authorization systems
- Create any significant technical change requiring planning

## Outputs

This skill produces:
1. **`state.json`** - State file for resume capability
2. **`context/`** - Cached agent outputs for reference
3. **Iterative proposals** - `proposal1.md`, `proposal2.md`, etc.
4. **Implementation** - `src/` directory with code (after approval)
5. **Documentation** - `README.md` with installation guide

Work directory: `$WORK_DIR/{identifier}/`
Final output: `$PROPOSALS_DIR/{proposal_name}/` (copied on completion)

---

## Phase 0: Setup

**Goal**: Establish identifier, initialize state, prepare work directory.

### 0.1 Get Identifier

Use AskUserQuestion:
```
What identifier should we use for this proposal?

Options:
- Ticket number (e.g., PROJ-123, SSO-001)
- Descriptive slug (e.g., sso-integration, payment-system)

This will be used for:
- Work directory: $WORK_DIR/{identifier}/
- Resume capability: /resume-work {identifier}
```

Store as `{identifier}`.

### 0.2 Get Proposal Name

If identifier is a ticket number, ask for a descriptive name:
```
What should we call this proposal? (e.g., sso-integration, user-export)
```

Store as `{proposal_name}`. If identifier is already descriptive, use it as proposal_name.

### 0.3 Get Feature Description

If not provided in $ARGUMENTS, use AskUserQuestion:
```
Describe the feature or system you want to design:
```

Store as `{feature_description}`.

### 0.4 Detect Ecosystem

Identify the project's technology stack to tailor Phase 5 implementation guidance.

**Check configuration first** (skip interactive question if set):
```bash
ECOSYSTEM=$(yq -r '.project.ecosystem // ""' "$CONFIG" 2>/dev/null)
```

**If not configured, auto-detect from project files:**
```bash
if [[ -z "$ECOSYSTEM" ]]; then
  if [[ -f "composer.json" ]]; then
    if grep -q "symfony/framework-bundle" composer.json 2>/dev/null; then
      ECOSYSTEM="php-symfony"
    else
      ECOSYSTEM="php"
    fi
  elif [[ -f "package.json" ]]; then
    if grep -qE '"react"|"next"' package.json 2>/dev/null; then
      ECOSYSTEM="react"
    else
      ECOSYSTEM="node"
    fi
  elif [[ -f "go.mod" ]]; then
    ECOSYSTEM="go"
  elif [[ -f "pom.xml" ]]; then
    ECOSYSTEM="java"
  elif [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
    ECOSYSTEM="python"
  else
    ECOSYSTEM="unknown"
  fi
fi
```

**Confirm with user** (skip if `ECOSYSTEM` was found in `configuration.yml`):

Use AskUserQuestion:
```
header: "Technology Stack"
question: "Detected: {ECOSYSTEM}. Confirm or change."
options:
  - "PHP/Symfony" / "Symfony framework, PHP 8+, Doctrine ORM"
  - "PHP" / "PHP without a specific framework"
  - "React/TypeScript" / "React frontend with TypeScript"
  - "Node.js" / "Node.js backend"
  - "Go" / "Go backend service"
  - "Python" / "Python service or application"
  - "Other" / "Specify in the text field"
```

Store confirmed value as `{ecosystem}`.

> **Tip:** Add `project.ecosystem: php-symfony` to `.claude/configuration.yml` to skip this question on future proposals.

### 0.5 Initialize Work Directory

```bash
mkdir -p $WORK_DIR/{identifier}/context
mkdir -p $WORK_DIR/{identifier}/notes
```

### 0.6 Initialize State File

Write `$WORK_DIR/{identifier}/state.json`:

```json
{
  "schema_version": 1,
  "type": "proposal",
  "identifier": "{identifier}",
  "proposal_name": "{proposal_name}",
  "title": "{feature_description_summary}",
  "ecosystem": "{ecosystem}",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",

  "phases": {
    "requirements_gathering": {"status": "pending", "agent": "business-analyst"},
    "brainstorming": {"status": "pending", "agent": "Plan"},
    "proposal_drafts": {"status": "pending", "current_iteration": 0},
    "confirm_implementation": {"status": "pending"},
    "implementation": {"status": "pending"}
  },

  "iterations": [],

  "outputs": {
    "final_proposal": null,
    "readme": null
  }
}
```

### 0.7 Update Work Manifest

After creating the state file, upsert into `${WORK_DIR}/manifest.json` (see [docs/manifest-system.md](../../docs/manifest-system.md)).

Read or initialize manifest, then upsert item using `identifier` as unique key:

```json
{
  "identifier": "{identifier}",
  "title": "{feature_description_summary}",
  "type": "proposal",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "current_phase": "requirements_gathering",
  "progress": "Phase 1/5",
  "branch": null,
  "tags": [],
  "path": "{identifier}/"
}
```

Update `last_updated` and `total_items` in the envelope.

---

## Proposal Workflow (5 Phases)

### Phase 1: Requirements Gathering

**Goal**: Gather and document requirements using `business-analyst` agent.

#### 1.1 Run Business Analyst

**Use Task tool with `subagent_type: "business-analyst"`:**

```
Prompt: Analyze requirements for the following feature request.

Feature: {feature_description}

Gather and document:
1. Problem Statement - What problem are we solving?
2. Stakeholders - Who are the users and stakeholders?
3. Technical Constraints - What limitations exist?
4. Integration Points - What existing systems need to integrate?
5. Security Requirements - What security considerations apply?
6. Performance Requirements - What are the performance expectations?

Key components to identify:
- Endpoints/routes needed
- External services/APIs
- Database entities
- Authentication/authorization needs
- Error handling requirements

Document all assumptions clearly.

Return a structured requirements summary that can be used for technical proposal creation.
```

#### 1.1b Explore Codebase (Parallel with 1.1)

**Use Task tool with `subagent_type: "Explore"`:**

```
Prompt: Explore the codebase to understand existing patterns relevant to this feature.

Feature: {feature_description}

Find:
1. Similar features already implemented
2. Existing patterns and conventions
3. Related entities, services, controllers
4. External integrations or APIs involved
5. Infrastructure that could be leveraged

Provide file paths and code examples of relevant existing implementations.
```

**Run business-analyst (1.1) and Explore (1.1b) in parallel.**

#### 1.2 Save Agent Outputs

Save business-analyst output to `$WORK_DIR/{identifier}/context/requirements.json`
Save Explore output to `$WORK_DIR/{identifier}/context/exploration.md`

Also write human-readable version of requirements to `$WORK_DIR/{identifier}/notes/requirements.md`

#### 1.3 Review with User

**After agent completes**, review the requirements with the user:
- Present the gathered requirements
- Ask clarifying questions for any gaps
- Confirm understanding before proceeding

**Example follow-up questions for an SSO proposal:**
- "Which identity provider are you integrating with?"
- "Do you need to support multiple user pools?"
- "What happens when a user doesn't exist?"
- "Should tokens be one-time use?"
- "What's the token expiration time?"

#### 1.4 Update State

Update `state.json`:
```json
{
  "phases": {
    "requirements_gathering": {"status": "completed", "agent": "business-analyst"},
    "brainstorming": {"status": "in_progress", "agent": "Plan"}
  }
}
```

### Phase 2: Brainstorming & Exploration

**Goal**: Explore approaches and select direction using `Plan` agent.

#### 2.1 Run Plan Agent

**Use Task tool with `subagent_type: "Plan"`:**

```
Prompt: Design implementation approaches for the following feature.

Feature: {feature_description}
Requirements: {load from context/requirements.json}
Codebase Patterns: {load from context/exploration.md}

Tasks:
1. Using the codebase patterns already discovered, present 2-3 different implementation approaches
2. For each approach, document:
   - Architecture pattern (MVC, service layer, etc.)
   - Technology choices (libraries, frameworks)
   - Data flow and state management
   - Pros and cons
   - Security considerations
   - Scalability implications
3. Identify risks and mitigation strategies
4. Recommend preferred approach with justification

Return a structured comparison of approaches with clear recommendation.
```

#### 2.2 Save Agent Output

Save Plan agent output to `$WORK_DIR/{identifier}/context/approaches.json`

#### 2.2b Validate Approaches

**Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Validate the feasibility of these implementation approaches against project architecture.

Approaches: {load from context/approaches.json}
Codebase Patterns: {load from context/exploration.md}

For each approach, assess:
1. Architectural feasibility - does it fit the project's existing architecture?
2. Pattern consistency - does it follow established patterns?
3. Risk areas - what could go wrong architecturally?
4. Missing considerations

Annotate each approach with a feasibility assessment.
```

Save architect output to `$WORK_DIR/{identifier}/context/architecture-validation.md`

Include architect feedback when presenting approaches to the user.

#### 2.3 Select Approach

**After agent completes**:
1. Present the approaches to the user
2. Discuss pros and cons of each
3. Ask for feedback on preferred direction
4. Record the selected approach

Save decision to `$WORK_DIR/{identifier}/notes/decisions.md`:
```markdown
# Design Decisions

## Selected Approach
{approach_name}

## Rationale
{why this approach was chosen}

## Trade-offs Accepted
{what we're giving up}
```

#### 2.4 Update State

Update `state.json`:
```json
{
  "phases": {
    "requirements_gathering": {"status": "completed"},
    "brainstorming": {"status": "completed", "agent": "Plan", "selected_approach": "{approach_name}"},
    "proposal_drafts": {"status": "in_progress", "current_iteration": 1}
  }
}
```

### Phase 3: Create Proposal Drafts

**Goal**: Create iterative proposal documents, tracking each version.

#### 3.1 Create Proposal Draft

Create proposal documents in the work directory:

**Directory structure:**
```
$WORK_DIR/{identifier}/
├── state.json
├── context/
│   ├── requirements.json
│   └── approaches.json
├── notes/
│   ├── requirements.md
│   ├── questions.md
│   └── decisions.md
├── proposal1.md  # Initial approach
├── proposal2.md  # Refined after feedback
└── proposal3.md  # Final design (if needed)
```

**Proposal document format:**
```markdown
# [Feature Name] - Proposal [N]

## Overview
Brief description of the feature/change

## Problem Statement
What problem are we solving?

## Proposed Solution
High-level description of the approach

## Architecture

### Components
List and describe all components:
- Controllers
- Services
- Entities
- Repositories
- Models (Request/Response)
- Exceptions

### Data Flow
Describe the request/response flow with sequence diagrams or step-by-step

### Database Schema
```sql
-- Table definitions
```

### Directory Structure
```
src/
├── Controller/
├── Service/
├── Entity/
├── Model/
└── ...
```

## API Endpoints

### Endpoint 1: [METHOD]:[PATH]
**Request:**
```json
{...}
```

**Response:**
```json
{...}
```

**Error Cases:**
- Case 1: ...
- Case 2: ...

## Security Considerations
- Authentication requirements
- Authorization checks
- Data validation
- Rate limiting
- Token management

## Dependencies
- External services
- PHP packages
- Environment variables

## Implementation Notes
- TODO items
- Known limitations
- Future improvements

## Testing Strategy
- Unit tests needed
- Integration tests
- Manual testing steps

## Deployment
- Migration steps
- Configuration changes
- Rollback plan
```

#### 3.2 Iterate on Proposals

- Number proposals sequentially (proposal1.md, proposal2.md, etc.)
- Each iteration addresses feedback and refines the design
- Keep previous versions for reference

#### 3.3 Track Iterations

After each proposal draft, update `state.json`:

```json
{
  "phases": {
    "proposal_drafts": {"status": "in_progress", "current_iteration": 2}
  },
  "iterations": [
    {
      "version": 1,
      "file": "proposal1.md",
      "created_at": "{ISO_TIMESTAMP}",
      "feedback": "Need more detail on token handling and error cases"
    },
    {
      "version": 2,
      "file": "proposal2.md",
      "created_at": "{ISO_TIMESTAMP}",
      "feedback": null
    }
  ]
}
```

#### 3.4 Record Feedback

When user provides feedback on a proposal:
1. Record feedback in the current iteration entry
2. Increment `current_iteration`
3. Create next proposal version addressing feedback

Save questions and clarifications to `$WORK_DIR/{identifier}/notes/questions.md`

---

### Phase 3.5: Quality Guard Review

**Goal**: Independently validate the final proposal draft before presenting it for approval.

Use Task tool with `subagent_type: "quality-guard"`:

```
Prompt: Review this technical proposal before stakeholder approval.

Final proposal: $WORK_DIR/{identifier}/{latest_proposal}.md
Architecture validation: $WORK_DIR/{identifier}/context/architecture-validation.md (if exists)

Review:
1. Are all requirements from Phase 1 addressed? List any gaps.
2. Are the API contracts, schemas, or integration points fully specified (no "TBD" gaps)?
3. Are security considerations explicitly addressed?
4. Are the proposed patterns consistent with the codebase exploration findings?
5. Is the implementation plan realistic — are there hidden dependencies or missing steps?
6. Are there contradictions between sections of the proposal?

Return: APPROVED / CONDITIONAL / REJECTED with specific findings.
```

**Process the verdict:**

- **APPROVED**: Proceed to Phase 4.
- **CONDITIONAL**: Incorporate the findings into the proposal as a "Known Concerns" section, or address them with a targeted revision. Proceed to Phase 4.
- **REJECTED**: Return to Phase 3 — create a new proposal iteration addressing the fundamental issues.

Save quality-guard output to `$WORK_DIR/{identifier}/context/quality-guard.md`.

---

### Phase 4: Confirm Implementation

**Goal**: Get explicit approval before implementing.

#### 4.1 Review Final Proposal

Before implementing, confirm with the user:

1. **Review final proposal** together
2. **Confirm all requirements** are addressed
3. **Get explicit approval** to proceed
4. **Ask**: "Are you ready to implement this proposal, or would you like to refine anything?"

**Only proceed to implementation after explicit confirmation.**

#### 4.2 Update State on Approval

Update `state.json`:

```json
{
  "phases": {
    "proposal_drafts": {"status": "completed", "current_iteration": 2, "final_version": "proposal2.md"},
    "confirm_implementation": {"status": "completed", "approved_at": "{ISO_TIMESTAMP}"},
    "implementation": {"status": "in_progress"}
  }
}
```

#### 4.3 If User Wants Changes

If user requests more iterations:
1. Return to Phase 3
2. Create next proposal version
3. Update iteration tracking
4. Return here for approval

### Phase 5: Implementation & Documentation

**Goal**: Implement the approved design and create documentation.

#### 5.1 Implementation Structure

Create implementation in the work directory:
```
$WORK_DIR/{identifier}/src/
```

Follow your project's existing conventions. Use the codebase patterns from Phase 1 exploration as your guide — match the file structure, naming, and layer separation already in use.

**General principles:**
- Mirror the directory structure of similar existing features
- Follow the naming conventions already established (check exploration.md context)
- Keep business logic in service/domain layers, not in entry points (controllers, handlers, lambdas)
- One responsibility per class/module
- Inject dependencies; avoid global state

**If this is the first feature of its kind in the project**, propose a structure in the proposal draft (Phase 3) and get user approval before implementing.

**Ecosystem structure reference** — use `{ecosystem}` as a starting point, adapt to what already exists in the codebase:

| Ecosystem | Source Dir | Entry Points | Business Logic |
|-----------|-----------|--------------|----------------|
| `php-symfony` | `src/` | `Controller/` | `Service/` |
| `node` | `src/` | `routes/` | `services/` |
| `react` | `src/` | `pages/` | `hooks/`, `contexts/` |
| `go` | root | `cmd/`, `handlers/` | `pkg/`, `internal/` |
| `python` | module dir | `routes/`, `views/` | `services/` |

#### 5.2 Create README.md

After implementation, create comprehensive documentation:

```
$WORK_DIR/{identifier}/README.md
```

**Ecosystem command reference** — substitute based on `{ecosystem}` when generating the README:

| | `php-symfony` | `node` / `react` | `go` | `python` |
|--|---------------|-----------------|------|----------|
| Install | `composer require vendor/pkg` | `npm install pkg` | `go get github.com/vendor/pkg` | `pip install pkg` |
| Migrate | `php bin/console doctrine:migrations:migrate` | *(ORM-specific)* | *(tool-specific)* | `python manage.py migrate` (Django) / `alembic upgrade head` |

**README.md structure:**
```markdown
# [Feature Name]

Brief description

## Architecture Overview
High-level description with component list

## Directory Structure
```
{source_dir}/
├── {entry_points_dir}/
├── {business_logic_dir}/
...
```
Fill in based on {ecosystem} and existing project conventions.

## Installation

### 1. Copy Files
Explain file placement

### 2. Install Dependencies
```bash
{ecosystem_install_command}
```

### 3. Configure Services
Service configuration examples

### 4. Environment Variables
List all required env vars with examples

### 5. Run Migrations (if applicable)
```bash
{ecosystem_migration_command}
```

## Usage

### Endpoint Documentation
For each endpoint:
- Request/response examples
- Error cases
- Authentication requirements

## Maintenance
Commands, cleanup tasks, scheduled jobs

## Security Considerations
Security features and best practices

## Logging
Logging configuration and channels

## Testing
Test cases to implement

## Troubleshooting
Common issues and solutions

## Architecture & Design Patterns
Explain patterns used and rationale

## Implementation Notes
Completed features and TODOs

## Compatibility
Versions and dependencies

## Support
Links to related docs
```

#### 5.3 Finalize and Copy to Proposals

After implementation is complete:

1. **Update final state:**

```json
{
  "status": "completed",
  "completed_at": "{ISO_TIMESTAMP}",
  "phases": {
    "requirements_gathering": {"status": "completed"},
    "brainstorming": {"status": "completed"},
    "proposal_drafts": {"status": "completed", "final_version": "proposal2.md"},
    "confirm_implementation": {"status": "completed"},
    "implementation": {"status": "completed"}
  },
  "outputs": {
    "final_proposal": "proposal2.md",
    "readme": "README.md",
    "proposals_dir": "$PROPOSALS_DIR/{proposal_name}/"
  }
}
```

2. **Copy to proposals directory:**

```bash
# Create final proposals directory
mkdir -p $PROPOSALS_DIR/{proposal_name}

# Copy final outputs
cp $WORK_DIR/{identifier}/{final_proposal} $PROPOSALS_DIR/{proposal_name}/proposal-final.md
cp $WORK_DIR/{identifier}/README.md $PROPOSALS_DIR/{proposal_name}/
cp -r $WORK_DIR/{identifier}/notes $PROPOSALS_DIR/{proposal_name}/
cp -r $WORK_DIR/{identifier}/src $PROPOSALS_DIR/{proposal_name}/
```

3. **Update manifests:**

Update **work manifest** (`${WORK_DIR}/manifest.json`) to reflect completion:
```json
{
  "identifier": "{identifier}",
  "type": "proposal",
  "status": "completed",
  "current_phase": "completed",
  "progress": "Phase 5/5",
  "updated_at": "{ISO_TIMESTAMP}"
}
```

Update **proposals manifest** (`${PROPOSALS_DIR}/manifest.json`) with the new proposal (see [docs/manifest-system.md](../../docs/manifest-system.md)):
```json
{
  "name": "{proposal_name}",
  "title": "{feature_description_summary}",
  "status": "final",
  "created_at": "{from_state}",
  "updated_at": "{ISO_TIMESTAMP}",
  "iterations": "{iteration_count}",
  "tags": [],
  "path": "{proposal_name}/"
}
```

4. **Report completion:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Proposal Complete: {identifier}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Proposal: {title}
Iterations: {iteration_count}

Work Directory: $WORK_DIR/{identifier}/
Final Output: $PROPOSALS_DIR/{proposal_name}/

Files:
  ✓ $PROPOSALS_DIR/{proposal_name}/proposal-final.md
  ✓ $PROPOSALS_DIR/{proposal_name}/README.md
  ✓ $PROPOSALS_DIR/{proposal_name}/src/
  ✓ $PROPOSALS_DIR/{proposal_name}/notes/

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Next Steps:
  1. Review: $PROPOSALS_DIR/{proposal_name}/README.md
  2. Copy src/ to your project
  3. Follow installation instructions
```

---

## Error Handling

**Agent fails:**
```
⚠ Agent {agent_name} failed

Error: {error_message}

Options:
[r] Retry this agent
[s] Skip and continue
[a] Abort
```

**State file corrupted:**
```
⚠ State file corrupted: state.json

Options:
[r] Reset state from existing files
[d] Delete and start fresh
[a] Abort
```

---

## Resume Support

This skill integrates with `/resume-work`:

```bash
/resume-work              # Shows incomplete proposals
/resume-work {identifier} # Resumes specific proposal
```

**Resume behavior by phase:**

| Current Phase | Resume Action |
|--------------|---------------|
| requirements_gathering | Re-run business-analyst or continue from cached output |
| brainstorming | Re-run Plan agent or continue from cached approaches |
| proposal_drafts | Load latest iteration, continue feedback loop |
| confirm_implementation | Show latest proposal, ask for approval |
| implementation | Continue implementing from src/ |

---

## Project Conventions

Follow your project's established conventions. The exploration agent (Phase 1.1b) will map the existing patterns — use those as your reference. If no established patterns exist for this type of feature, define them explicitly in the proposal and get approval before implementing.

## Tips for Success

1. **Be thorough in Phase 1** - Better questions = better proposals
2. **Don't rush to implementation** - Design first, code later
3. **Iterate proposals** - Create proposal2.md, proposal3.md as needed
4. **Document decisions** - Capture why choices were made
5. **Follow conventions** - Consistency matters in codebases
6. **Test thoroughly** - Plan testing from the start
7. **Think about operations** - Logging, monitoring, cleanup tasks

## Examples of Good Proposals

Refer to existing proposals in `$PROPOSALS_DIR/` for patterns. If none exist yet, the first proposal is your template — take extra care with structure and documentation.

## Common Proposal Types

### Authentication/SSO
- Identity provider integration
- Token management
- User synchronization
- Session handling

### API Endpoints
- REST endpoints
- Request/response models
- Validation rules
- Error handling

### Database Changes
- New entities
- Schema migrations
- Repository methods
- Indexes and constraints

### Third-Party Integration
- API clients
- Webhook handling
- Rate limiting
- Error retry logic

## Checklist Before Implementation

- [ ] All requirements documented
- [ ] Multiple approaches considered
- [ ] Trade-offs understood
- [ ] Architecture clearly defined
- [ ] Database schema designed
- [ ] API contracts specified
- [ ] Security reviewed
- [ ] Error handling planned
- [ ] Testing strategy defined
- [ ] User explicitly approved
- [ ] Deployment plan created

## Output Files Summary

For a proposal with identifier "AUTH-001" and name "user-authentication":

**Work directory (during development):**
```
$WORK_DIR/AUTH-001/
├── state.json       # State tracking for resume
├── context/
│   ├── requirements.json     # Phase 1 agent output
│   └── approaches.json       # Phase 2 agent output
├── notes/
│   ├── requirements.md       # Human-readable requirements
│   ├── questions.md          # Clarifications gathered
│   └── decisions.md          # Design decisions
├── proposal1.md              # Initial design
├── proposal2.md              # Refined design
├── src/                      # Implementation (after approval)
│   ├── Controller/
│   ├── Service/
│   ├── Entity/
│   └── ...
└── README.md                 # Final documentation
```

**Final output (on completion):**
```
$PROPOSALS_DIR/user-authentication/
├── proposal-final.md         # Approved proposal
├── README.md                 # Installation guide
├── notes/                    # Design context
└── src/                      # Implementation code
```

## Remember

- **Never skip Phase 4 confirmation** - Always get explicit approval before implementing
- **Proposals are living documents** - Update them as design evolves
- **Documentation is not optional** - README.md is the implementation guide
- **Follow existing patterns** - Look at the codebase for conventions
- **Think about the full lifecycle** - Installation, usage, maintenance, troubleshooting