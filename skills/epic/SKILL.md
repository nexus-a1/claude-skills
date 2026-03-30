---
name: epic
category: planning
model: sonnet
userInvocable: true
description: Decompose large initiatives into dependency-mapped, wave-sequenced tickets with per-ticket requirements. Use when a feature is too large for a single /create-requirements run — typically 5+ tickets with complex interdependencies.
argument-hint: <epic-description>
allowed-tools: Read, Write, Grep, Glob, Bash(git:*), Bash(mkdir:*), Bash(yq:*), Task, AskUserQuestion
---

# Epic Command

Break down large initiatives (epics) into sequential, implementable tickets with proper dependencies.

## Context

Current directory: !`pwd`

Git status: !`git status --short 2>/dev/null || echo "Not a git repository"`

Arguments: $ARGUMENTS

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work state and context |

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

**Important:** All path references in this skill MUST use `$WORK_DIR`. Never use hardcoded `.claude/work/` paths.

---

## Your Task

Transform a large initiative into a structured set of implementable tickets with dependencies.

**IMPORTANT**: Complete all steps using parallel tool calls where possible.

---

## Phase 1: Parse Epic Description

**From $ARGUMENTS:**

If empty or insufficient:
```
Error: Epic description required.

Usage:
  /epic "Implement user authentication system"
  /epic "Add payment processing with Stripe"
  /epic "Migrate to microservices architecture"
```

Extract:
- Epic title (short, kebab-case slug)
- Epic description (what needs to be built)

---

## Phase 2: Analyze Initiative

Use the Task tool with `business-analyst` agent to:

```
Analyze this initiative and break it down:

Epic: {description}

Requirements:
1. Identify major components/features needed
2. Understand technical scope (frontend, backend, DB, infrastructure)
3. Identify external dependencies (APIs, services)
4. Consider security/compliance requirements
5. Estimate overall complexity

Provide:
- List of major components
- Technical areas involved
- Dependencies and constraints
- Risk factors
```

Use the Task tool with `architect` agent to validate technical feasibility:

```
Review the technical approach for this initiative:

Epic: {description}
Components identified: {from business-analyst}

Validate:
1. Architecture patterns to use
2. Layer compliance
3. File structure/organization
4. Integration points
5. Any architectural risks

Provide:
- Recommended architecture approach
- File structure suggestions
- Integration strategy
- Risk mitigation
```

**Run both agents in parallel.**

---

## Phase 2.5: Conditional Specialist Deep Dive

**Goal**: Based on Phase 2 findings, run specialist agents to gather deeper context for areas that will significantly impact the epic breakdown.

**IMPORTANT**: This phase is conditional. Only run agents when the scope warrants it. Skip entirely if the initiative is straightforward and doesn't touch databases, external APIs, cloud infrastructure, or security-sensitive areas.

### 2.5.1 Determine Required Specialists

Review the combined output from `business-analyst` and `architect` in Phase 2. Check for signals that warrant specialist agents:

| Signal in Phase 2 Findings | Agent | Purpose |
|----------------------------|-------|---------|
| New tables, schema modifications, migrations, entity changes | `data-modeler` | Analyze schema impacts, migration complexity, relationship constraints |
| Third-party API integrations, webhooks, external service calls | `integration-analyst` | Map API contracts, auth requirements, error handling patterns |
| New AWS/cloud resources, infrastructure changes, IaC modifications | `aws-architect` | Assess infrastructure needs, IAM requirements, cost implications |
| Authentication, authorization, PII handling, payments, compliance | `security-requirements` | Identify security constraints, compliance needs, audit requirements |

**If no signals are detected**: Skip to Phase 3 immediately.

**If one or more signals are detected**: Proceed to 2.5.2.

### 2.5.2 Run Applicable Specialist Agents in Parallel

**Execute all applicable agents in a single message with multiple Task tool calls.**

```
Task (IF DB changes detected): subagent_type: "data-modeler"
Prompt: Analyze database implications for this initiative.

Epic: {description}
Components identified: {from business-analyst}
Architecture approach: {from architect}

Analyze:
1. Existing entity relationships and constraints in affected areas
2. Required schema changes across the initiative
3. Migration complexity and ordering
4. Index needs for new queries
5. Data integrity considerations across tickets

Return concise schema analysis (~1000 tokens) focused on what impacts ticket breakdown.

---

Task (IF external APIs involved): subagent_type: "integration-analyst"
Prompt: Analyze external API integrations for this initiative.

Epic: {description}
External dependencies identified: {from business-analyst}
Integration points: {from architect}

Analyze:
1. API contracts and versioning requirements
2. Authentication/authorization for external services
3. Error handling and retry patterns needed
4. Rate limits and throttling considerations
5. Integration testing requirements

Return concise integration analysis (~1000 tokens) focused on what impacts ticket breakdown.

---

Task (IF AWS/cloud changes needed): subagent_type: "aws-architect"
Prompt: Review infrastructure requirements for this initiative.

Epic: {description}
Infrastructure scope: {from architect}

Analyze:
1. Required AWS services (new or modifications to existing)
2. IAM permissions and security boundaries
3. Infrastructure-as-Code changes needed
4. Cross-service dependencies
5. Cost implications and resource sizing

Return concise infrastructure analysis (~1000 tokens) focused on what impacts ticket breakdown.

---

Task (IF security-sensitive scope): subagent_type: "security-requirements"
Prompt: Identify security and compliance requirements for this initiative.

Epic: {description}
Sensitive areas identified: {from business-analyst}
Security boundaries: {from architect}

Analyze:
1. Authentication/authorization requirements across the initiative
2. Data sensitivity classification
3. Compliance requirements (GDPR, PCI, etc.)
4. Security boundaries and constraints between components
5. Audit logging needs

Return concise security analysis (~1000 tokens) focused on what impacts ticket breakdown.
```

### 2.5.3 Incorporate Specialist Findings

Feed specialist agent outputs into the subsequent phases:
- **Phase 3 (Decompose)**: Use specialist findings to ensure tickets properly account for DB migrations, API integration steps, infrastructure provisioning, and security hardening.
- **Phase 4 (Dependencies)**: Use specialist findings to identify cross-cutting dependency chains (e.g., infrastructure must be provisioned before services that depend on it).
- **Phase 5 (Technical Requirements)**: Include relevant specialist context in each ticket's technical details and implementation notes.

---

## Phase 3: Decompose into Tickets

Based on analysis from Phase 2 and specialist findings from Phase 2.5 (if any), break the epic into tickets:

**Ticket sizing rules:**
- Each ticket: 1-3 days of work max
- One focused change per ticket
- Should be independently testable
- Should have clear acceptance criteria

**Ticket structure:**
```
{epic-slug}-001: {Title}
  Description: {What this ticket accomplishes}
  Components: {Files/areas affected}
  Dependencies: {Which other tickets must complete first}
  Estimate: Small | Medium | Large
  Type: Database | Backend | Frontend | Infrastructure | Integration
```

**Common decomposition patterns:**

For full-stack features:
1. Database schema/migrations
2. Entity/model layer
3. Repository/data access
4. Service/business logic
5. API endpoints
6. Frontend components
7. Integration tests

For migrations:
1. Setup/infrastructure
2. Parallel implementation (old + new)
3. Migration scripts
4. Cutover/toggle
5. Cleanup old code

For integrations:
1. Research/API analysis
2. Client implementation
3. Service layer integration
4. Error handling/retry logic
5. Monitoring/logging

---

## Phase 4: Create Dependency Graph

Analyze ticket dependencies:

```
Dependency Analysis:

{epic-slug}-001: Database schema
  Blocks: -002, -004
  Blocked by: None

{epic-slug}-002: Entity layer
  Blocks: -005, -006
  Blocked by: -001

{epic-slug}-003: External API client
  Blocks: -005
  Blocked by: None
  (Can run in parallel with -001, -002)

...

Implementation Waves:
  Wave 1 (parallel): -001, -003
  Wave 2: -002
  Wave 3: -004, -005
  Wave 4: -006
```

Identify opportunities for parallel work.

---

## Phase 5: Generate Technical Requirements

For each ticket, create lightweight requirements:

**Use the Task tool with `context-builder` agent** to gather context for each ticket area.

For each ticket, generate:

```markdown
# {epic-slug}-{number}: {Title}

## Description
{What this ticket accomplishes and why}

## Scope
**In scope:**
- {specific changes}

**Out of scope:**
- {what's NOT included - deferred to other tickets}

## Technical Details
- Files to create: {list}
- Files to modify: {list}
- Dependencies: {packages, services}

## Acceptance Criteria
- [ ] {testable criterion 1}
- [ ] {testable criterion 2}
- [ ] {testable criterion 3}

## Dependencies
- Blocked by: {ticket-slug} (must complete first)
- Blocks: {ticket-slug} (others waiting on this)

## Estimate
{Small: <1 day | Medium: 1-2 days | Large: 2-3 days}

## Implementation Notes
{Key patterns to follow, pitfalls to avoid}
```

Save each to: `$WORK_DIR/{epic-slug}/{ticket-slug}/{ticket-slug}-TECHNICAL_REQUIREMENTS.md`

---

## Phase 5.5: Quality Guard Review

**Goal**: Validate the ticket breakdown before saving the epic structure.

Use Task tool with `subagent_type: "quality-guard"`:

```
Prompt: Challenge this epic breakdown for '{epic_description}'.

Epic plan context (from Phase 2-4):
- Business analyst findings: {business_analyst_output}
- Architect validation: {architect_output}
- Tickets generated: {ticket_list_summary}

Review:
1. Is every ticket independently testable and deliverable? Flag any that are too broad or too vague.
2. Are the dependencies complete and correct? Are there hidden dependencies not captured?
3. Are the wave assignments valid — can Wave 1 tickets actually start in parallel?
4. Are there missing tickets (e.g., infrastructure setup, migration rollback, documentation)?
5. Is the scope appropriate — are any tickets doing too much (should be split) or too little (should be merged)?
6. Does the epic cover the full feature, or are there gaps between tickets?

Return: APPROVED / CONDITIONAL (list specific issues) / REJECTED (fundamental restructuring needed).
```

**Process the verdict:**

- **APPROVED**: Proceed to Phase 6.
- **CONDITIONAL**: Adjust the ticket breakdown based on findings before saving.
- **REJECTED**: Return to Phase 3 to re-decompose the epic.

---

## Phase 6: Create Epic Structure

Create directory structure:

```bash
mkdir -p $WORK_DIR/{epic-slug}
```

For each ticket:
```bash
mkdir -p $WORK_DIR/{epic-slug}/{ticket-slug}
```

Save files:
1. `$WORK_DIR/{epic-slug}/EPIC_PLAN.md` - Overall plan
2. `$WORK_DIR/{epic-slug}/state.json` - Epic tracking
3. `$WORK_DIR/{epic-slug}/{ticket-slug}/{ticket-slug}-TECHNICAL_REQUIREMENTS.md` - Each ticket's requirements

---

## Epic Plan Template

**EPIC_PLAN.md:**

```markdown
# Epic: {Title}

## Overview
{What this epic accomplishes}

## Business Context
**Problem**: {Current state/pain point}
**Goal**: {Desired outcome}
**Impact**: {Who benefits and how}

## Technical Scope
- **Frontend**: {Yes/No - what components}
- **Backend**: {Yes/No - what services}
- **Database**: {Yes/No - what changes}
- **Infrastructure**: {Yes/No - what resources}
- **Integrations**: {Yes/No - what APIs}

## Tickets ({count})

### {epic-slug}-001: {Title}
**Type**: {Database|Backend|Frontend|etc}
**Estimate**: {Small|Medium|Large}
**Dependencies**: None
**Status**: Pending

{Brief description}

### {epic-slug}-002: {Title}
**Type**: {Database|Backend|Frontend|etc}
**Estimate**: {Small|Medium|Large}
**Dependencies**: Blocked by {epic-slug}-001
**Status**: Pending

{Brief description}

...

## Implementation Order

### Wave 1 (Start first - no dependencies)
- {epic-slug}-001: {Title}
- {epic-slug}-003: {Title} *(can run in parallel)*

### Wave 2 (After Wave 1)
- {epic-slug}-002: {Title}
- {epic-slug}-004: {Title}

### Wave 3 (After Wave 2)
- {epic-slug}-005: {Title}

...

## Progress Tracking

- [ ] {epic-slug}-001: {Title}
- [ ] {epic-slug}-002: {Title}
- [ ] {epic-slug}-003: {Title}
...

## Notes
{Any important considerations, risks, or decisions made}
```

---

## Epic State Schema

**state.json:**

```json
{
  "schema_version": 1,
  "type": "epic",
  "identifier": "{epic-slug}",
  "title": "{Epic Title}",
  "description": "{Full description}",
  "status": "planning",
  "created_at": "{ISO timestamp}",
  "updated_at": "{ISO timestamp}",

  "agents_used": {
    "always": ["business-analyst", "architect"],
    "specialists": ["data-modeler", "security-requirements"]
  },

  "tickets": [
    {
      "slug": "{epic-slug}-001",
      "title": "{Title}",
      "type": "database",
      "estimate": "small",
      "status": "pending",
      "blocked_by": [],
      "blocks": ["{epic-slug}-002", "{epic-slug}-004"],
      "requirements_file": "{epic-slug}-001/{epic-slug}-001-TECHNICAL_REQUIREMENTS.md",
      "implementation_status": null
    },
    {
      "slug": "{epic-slug}-002",
      "title": "{Title}",
      "type": "backend",
      "estimate": "medium",
      "status": "pending",
      "blocked_by": ["{epic-slug}-001"],
      "blocks": ["{epic-slug}-005"],
      "requirements_file": "{epic-slug}-002/{epic-slug}-002-TECHNICAL_REQUIREMENTS.md",
      "implementation_status": null
    }
  ],

  "waves": [
    {
      "wave": 1,
      "tickets": ["{epic-slug}-001", "{epic-slug}-003"],
      "status": "pending"
    },
    {
      "wave": 2,
      "tickets": ["{epic-slug}-002", "{epic-slug}-004"],
      "status": "pending"
    }
  ],

  "progress": {
    "total_tickets": 6,
    "completed": 0,
    "in_progress": 0,
    "pending": 6
  }
}
```

---

## Phase 6.5: Update Work Manifest

After saving all epic files, upsert into `${WORK_DIR}/manifest.json` (see [docs/manifest-system.md](../../docs/manifest-system.md)).

Read or initialize manifest, then upsert item using `identifier` (the epic slug) as unique key:

```json
{
  "identifier": "{epic-slug}",
  "title": "{Epic Title}",
  "type": "epic",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "current_phase": "planning",
  "progress": "0/{total_tickets} tickets",
  "branch": null,
  "tags": [],
  "path": "{epic-slug}/"
}
```

Update `last_updated` and `total_items` in the envelope.

---

## Phase 7: Present Epic Plan

Show the user a clear summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Epic Created: {epic-slug}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{Epic Title}

{Brief description}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Breakdown: {N} tickets
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Wave 1 (Start first):
  ✓ {epic-slug}-001: {Title} [{Type}, {Estimate}]
  ✓ {epic-slug}-003: {Title} [{Type}, {Estimate}] (parallel)

Wave 2 (After Wave 1):
  → {epic-slug}-002: {Title} [{Type}, {Estimate}]
  → {epic-slug}-004: {Title} [{Type}, {Estimate}]

Wave 3 (After Wave 2):
  → {epic-slug}-005: {Title} [{Type}, {Estimate}]

...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Agents Used
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✓ business-analyst (initiative analysis)
  ✓ architect (technical feasibility)
  {✓ data-modeler - if used}
  {✓ integration-analyst - if used}      [PARALLEL]
  {✓ aws-architect - if used}
  {✓ security-requirements - if used}
  ✓ context-builder (ticket context)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Files Created
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$WORK_DIR/{epic-slug}/
├── EPIC_PLAN.md
├── state.json
├── {epic-slug}-001/
│   └── {epic-slug}-001-TECHNICAL_REQUIREMENTS.md
├── {epic-slug}-002/
│   └── {epic-slug}-002-TECHNICAL_REQUIREMENTS.md
└── ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next Steps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Review the epic plan:
   cat $WORK_DIR/{epic-slug}/EPIC_PLAN.md

2. Start implementing first ticket:
   /implement {epic-slug}-001

3. Track progress:
   /resume-work {epic-slug}

4. View ticket details:
   cat $WORK_DIR/{epic-slug}/{epic-slug}-001/{epic-slug}-001-TECHNICAL_REQUIREMENTS.md
```

---

## Error Handling

**No description provided:**
```
Error: Epic description required.

Usage: /epic "description of what to build"

Examples:
  /epic "Implement user authentication with JWT"
  /epic "Add Stripe payment processing"
  /epic "Migrate from monolith to microservices"
```

**Epic too small:**
```
Analysis: This work is simple enough for a single ticket.

Recommendation: Use /create-requirements instead.

This epic feature is for complex, multi-ticket initiatives.
```

**Epic already exists:**
```
Warning: Epic '{epic-slug}' already exists.

Options:
  1. Continue with existing epic
  2. Create new epic with different name
  3. Delete existing and recreate

[Select 1-3]:
```

---

## Important Notes

- **Epic slugs** are kebab-case (e.g., "user-authentication-system")
- **Ticket slugs** follow pattern: `{epic-slug}-{number}` (e.g., "user-authentication-system-001")
- Each ticket should be **independently testable**
- Tickets are **sized appropriately** (1-3 days max)
- **Dependencies are explicit** - clear what blocks what
- **Parallel opportunities** are identified
- Epic state is **trackable** across sessions via `/resume-work`

## Integration with Existing Workflow

After epic creation:
- Each ticket can be implemented with `/implement {ticket-slug}`
- Progress tracked in `state.json`
- `/resume-work {epic-slug}` shows epic status and suggests next ticket
- After all tickets complete, epic status becomes "completed"
