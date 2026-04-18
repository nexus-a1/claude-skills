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
- Epic title (short, kebab-case slug)
- Epic description (what needs to be built)

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

Register active session for the optional `auto-context.sh` PostToolUse hook (no-op when `CLAUDE_SESSION_ID` is unset):

```bash
if [ -n "${CLAUDE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
  mkdir -p "$WORK_DIR"
  touch "$WORK_DIR/.active-sessions.lock"
  (
    flock -x -w 2 200 || exit 0
    [ -s "$WORK_DIR/.active-sessions" ] || echo '{}' > "$WORK_DIR/.active-sessions"
    jq --arg s "$CLAUDE_SESSION_ID" --arg w "{epic-slug}" \
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
