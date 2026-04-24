---
name: epic
category: planning
model: claude-sonnet-4-6
userInvocable: true
description: Decompose large initiatives into dependency-mapped, wave-sequenced tickets with per-ticket requirements. Use when a feature is too large for a single /create-requirements run — typically 5+ tickets with complex interdependencies.
argument-hint: <epic-description>
allowed-tools: "Read, Write, Grep, Glob, Bash(git:*), Bash(mkdir:*), Bash(yq:*), Task, AskUserQuestion"
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
- **Epic ticket** (e.g., `EPIC-42`, `PROJ-100`) — ask via AskUserQuestion if not provided. Must match `[A-Z]+-[0-9]+`. Store as `{epic-ticket}`.
- **Epic slug** — a short, kebab-case descriptor (2–5 words) derived from the epic description. Lowercase, ASCII, `[a-z0-9-]+`. Confirm with the user before proceeding.
- **Epic identifier** `{epic-id}` = `{epic-ticket}-{slug}` (per the Work Directory Naming Convention in `CLAUDE.md`). This is the full composite identifier used throughout the rest of this skill for paths, manifest entries, and resume handles.
- Epic description (what needs to be built).

**Per-ticket naming:** each generated ticket has `{ticket-id}` = `{ticket-number}-{ticket-slug}` where `{ticket-number}` is the Jira/issue identifier the user will assign (or a placeholder like `{epic-ticket}-001` until real ticket IDs are created) and `{ticket-slug}` is a kebab-case descriptor derived from the ticket's title. The composed `{ticket-id}` is the value used in paths and references throughout this skill.

---

## Phase 2: Analyze Initiative

Read `references/agent-prompts.md` for the `business-analyst` and `architect` prompt templates. Fill in `{description}` and, for architect, `{from business-analyst}`.

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

**Execute all applicable agents in a single message with multiple Task tool calls.** Only run the agents whose Phase 2 signals matched.

Read `references/agent-prompts.md` (Phase 2.5.2 section) for the full prompt templates for `data-modeler`, `integration-analyst`, `aws-architect`, and `security-requirements`. Fill in `{description}`, `{from business-analyst}`, and `{from architect}` in each applicable prompt.

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
{ticket-id}: {Title}             # e.g., PROJ-101-db-schema
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
Dependency Analysis (use each ticket's `{ticket-id}`; example uses
`PROJ-1NN` placeholders):

PROJ-101-db-schema: Database schema
  Blocks: PROJ-102-entity-layer, PROJ-104-...
  Blocked by: None

PROJ-102-entity-layer: Entity layer
  Blocks: PROJ-105-..., PROJ-106-...
  Blocked by: PROJ-101-db-schema

PROJ-103-external-api-client: External API client
  Blocks: PROJ-105-...
  Blocked by: None
  (Can run in parallel with PROJ-101, PROJ-102)

...

Implementation Waves (use full {ticket-id} — same identifiers used in Blocks/Blocked-by above):
  Wave 1 (parallel): PROJ-101-db-schema, PROJ-103-external-api-client
  Wave 2: PROJ-102-entity-layer
  Wave 3: PROJ-104-..., PROJ-105-...
  Wave 4: PROJ-106-...
```

Identify opportunities for parallel work.

---

## Phase 5: Generate Technical Requirements

For each ticket, create lightweight requirements:

**Use the Task tool with `context-builder` agent** to gather context for each ticket area.

For each ticket, generate:

```markdown
# {ticket-id}: {Title}             # e.g., PROJ-101-db-schema

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
- Blocked by: {ticket-id} (must complete first)
- Blocks: {ticket-id} (others waiting on this)

## Estimate
{Small: <1 day | Medium: 1-2 days | Large: 2-3 days}

## Implementation Notes
{Key patterns to follow, pitfalls to avoid}
```

Save each to: `$WORK_DIR/{epic-id}/{ticket-id}/{ticket-id}-TECHNICAL_REQUIREMENTS.md`

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
mkdir -p $WORK_DIR/{epic-id}
```

For each ticket:
```bash
mkdir -p $WORK_DIR/{epic-id}/{ticket-id}
```

Save files:
1. `$WORK_DIR/{epic-id}/EPIC_PLAN.md` - Overall plan
2. `$WORK_DIR/{epic-id}/state.json` - Epic tracking
3. `$WORK_DIR/{epic-id}/{ticket-id}/{ticket-id}-TECHNICAL_REQUIREMENTS.md` - Each ticket's requirements

Register active session for the optional `auto-context.sh` PostToolUse hook (no-op when `CLAUDE_SESSION_ID` is unset):

```bash
if [ -n "${CLAUDE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
  mkdir -p "$WORK_DIR"
  touch "$WORK_DIR/.active-sessions.lock"
  (
    flock -x -w 2 200 || exit 0
    [ -s "$WORK_DIR/.active-sessions" ] || echo '{}' > "$WORK_DIR/.active-sessions"
    jq --arg s "$CLAUDE_SESSION_ID" --arg w "{epic-id}" \
       '. + {($s): $w}' "$WORK_DIR/.active-sessions" \
       > "$WORK_DIR/.active-sessions.tmp.$$" \
       && mv "$WORK_DIR/.active-sessions.tmp.$$" "$WORK_DIR/.active-sessions" \
       || rm -f "$WORK_DIR/.active-sessions.tmp.$$"
  ) 200>"$WORK_DIR/.active-sessions.lock"
fi
```

---

## Epic Plan Template

Read `references/epic-plan-template.md` for the full `EPIC_PLAN.md` markdown template (overview, business context, tickets, implementation waves, progress tracking).

---

## Epic State Schema

Read `references/state-schema.md` for the complete `state.json` schema (schema_version, tickets, waves, progress).

---

## Phase 6.5: Update Work Manifest

After saving all epic files, upsert into `${WORK_DIR}/manifest.json` (see [docs/manifest-system.md](../../docs/manifest-system.md)).

Read or initialize manifest, then upsert item using `identifier` (the epic slug) as unique key:

```json
{
  "identifier": "{epic-id}",
  "title": "{Epic Title}",
  "type": "epic",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "current_phase": "planning",
  "progress": "0/{total_tickets} tickets",
  "branch": null,
  "tags": [],
  "path": "{epic-id}/"
}
```

Update `last_updated` and `total_items` in the envelope.

---

## Phase 7: Present Epic Plan

Show the user a clear summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Epic Created: {epic-id}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{Epic Title}

{Brief description}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Breakdown: {N} tickets
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Wave 1 (Start first):
  ✓ {ticket-id}: {Title} [{Type}, {Estimate}]
  ✓ {ticket-id}: {Title} [{Type}, {Estimate}] (parallel)

Wave 2 (After Wave 1):
  → {ticket-id}: {Title} [{Type}, {Estimate}]
  → {ticket-id}: {Title} [{Type}, {Estimate}]

Wave 3 (After Wave 2):
  → {ticket-id}: {Title} [{Type}, {Estimate}]

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

$WORK_DIR/{epic-id}/
├── EPIC_PLAN.md
├── state.json
├── {ticket-id}/                # e.g., PROJ-101-db-schema/
│   └── {ticket-id}-TECHNICAL_REQUIREMENTS.md
├── {ticket-id}/                # e.g., PROJ-102-entity-layer/
│   └── {ticket-id}-TECHNICAL_REQUIREMENTS.md
└── ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next Steps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Review the epic plan:
   cat $WORK_DIR/{epic-id}/EPIC_PLAN.md

2. Start implementing first ticket:
   /implement {ticket-id}             # e.g., /implement PROJ-101-db-schema

3. Track progress:
   /resume-work {epic-id}

4. View ticket details:
   cat $WORK_DIR/{epic-id}/{ticket-id}/{ticket-id}-TECHNICAL_REQUIREMENTS.md
```

```bash
# Clear auto-context sentinel on completion
if [ -n "${CLAUDE_SESSION_ID:-}" ] \
   && [ -f "$WORK_DIR/.active-sessions" ] \
   && command -v jq >/dev/null 2>&1; then
  (
    flock -x -w 2 200 || exit 0
    jq --arg s "$CLAUDE_SESSION_ID" 'del(.[$s])' "$WORK_DIR/.active-sessions" \
       > "$WORK_DIR/.active-sessions.tmp.$$" \
       && mv "$WORK_DIR/.active-sessions.tmp.$$" "$WORK_DIR/.active-sessions" \
       || rm -f "$WORK_DIR/.active-sessions.tmp.$$"
  ) 200>"$WORK_DIR/.active-sessions.lock"
fi
```

---

## Error Handling

Read `references/error-handling.md` for error-scenario message templates (no description provided, epic too small, epic already exists).

---

## Important Notes

- **Epic identifiers** follow `{epic-ticket}-{slug}` (e.g., "PROJ-100-user-auth-system") — see Work Directory Naming Convention in `CLAUDE.md`
- **Ticket identifiers** follow `{ticket-number}-{slug}` (e.g., "PROJ-101-db-schema") or use placeholders like `{epic-ticket}-001` until real ticket IDs are assigned
- Each ticket should be **independently testable**
- Tickets are **sized appropriately** (1-3 days max)
- **Dependencies are explicit** - clear what blocks what
- **Parallel opportunities** are identified
- Epic state is **trackable** across sessions via `/resume-work`

## Integration with Existing Workflow

After epic creation:
- Each ticket can be implemented with `/implement {ticket-id}` (e.g., `/implement PROJ-101-db-schema`)
- Progress tracked in `state.json`
- `/resume-work {epic-id}` shows epic status and suggests next ticket (e.g., `/resume-work PROJ-100-user-auth-system`)
- After all tickets complete, epic status becomes "completed"
