---
name: implement
category: implementation
model: claude-opus-5
userInvocable: true
description: Implement a feature from saved requirements. Chunk-based commits, parallel QA (tests + review + security), and PR creation. Resumes interrupted sessions from saved state. Runs in the current working tree by default — set `worktree.enabled: true` in `.claude/configuration.yml` to isolate work in a git worktree.
argument-hint: "[--light] [identifier]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage, EnterWorktree, ExitWorktree
---

# Implement Based on Requirements

## Purpose

End-to-end implementation skill that:
1. Detects incomplete work in `$WORK_DIR/` for smart resume
2. Understands requirements from multiple input formats
3. Explores codebase and plans implementation
4. Implements changes with state persistence
5. Commits each chunk separately inline (hook-guarded, `record-audit.sh`)
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
| `implement.deviation_checkpoint.enabled` | `true` | Phase 3.2b plan-vs-diff sanity check after each chunk commit; set `false` to opt out |
| `implement.playwright_scoping.enabled` | `true` | Phase 4.0 yes/no/scope question before writing Playwright E2E tests for a project with no existing Playwright config; set `false` to opt out (reverts to `implement.playwright_scoping.default`) |
| `implement.playwright_scoping.default` | `"heuristic"` | Only consulted when `enabled: false`. `"heuristic"` keeps the prior silent file-extension detection; `"skip"` never runs `playwright-engineer` for this project regardless of files touched |

```bash
# Source resolve-config: marketplace installs get ${CLAUDE_PLUGIN_ROOT} substituted
# inline before bash runs; legacy local copies fall back to ~/.claude. If neither
# path resolves, fail loudly rather than letting resolve_artifact be undefined.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
  exit 1
fi
WORK_DIR=$(resolve_artifact work work)
QA_EXEC_MODE=$(resolve_exec_mode qa_review team)
echo "WORK_DIR=$WORK_DIR"
```

Use `$WORK_DIR` instead of a hardcoded `.claude/work` — but only inside this block. Each later block is its own Bash tool call and does not inherit the variable, so those substitute the value printed above instead.
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

See `${CLAUDE_PLUGIN_ROOT}/shared/write-safety.md` (or `~/.claude/shared/write-safety.md` for local/dev copies) for the full conventions.

---

## Lightweight Mode

If `$ARGUMENTS` begins with `--light`, strip the flag and enable lightweight mode:

- Output to user: "Lightweight mode enabled: execution agents use Sonnet. Quality gates unchanged."
- **Explore agent**: unchanged
- **Plan agent**: spawn with model **sonnet**
- **architect**: unchanged — its frontmatter already pins Sonnet, so there is nothing to downgrade
- **code-reviewer**: unchanged (ALWAYS Opus — quality gate)
- **security-auditor**: unchanged (ALWAYS Opus — quality gate)
- **quality-guard**: unchanged (ALWAYS Opus — quality gate)
- **test-writer**: unchanged
- **test-fixer**: unchanged
- **git-operator**: unchanged
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

> **Identifier source.** `/implement` does **not** create work directories
> on its own. It always consumes an existing `{identifier}` produced by
> `/create-requirements` (or `/epic` for ticketed sub-tickets), which
> enforce the `{TICKET}-{slug}` Work Directory Naming Convention defined
> in `CLAUDE.md`. The validation in §0.2 will fail if no `state.json`
> exists for the supplied identifier — at which point the user is told to
> run `/create-requirements` first.

#### 0.1 Check for Incomplete Work

If no arguments provided, scan for incomplete implementations:

```bash
# Check for work directories with incomplete implementation
ls -1 <WORK_DIR printed above>/*/state.json 2>/dev/null
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

**Epic-ticket carve-out** (checked first): `/epic` writes only `spec.md` per ticket —
never a per-ticket `state.json` — because shared HOW context lives in the parent
epic's `EPIC_PLAN.md`. This must match the `EPIC_TICKET` detection Phase 1.2 uses
later, so the state.json requirement below is waived under the same condition:

```bash
EPIC_TICKET_NO_STATE=false
PARENT_DIR="$(dirname "<WORK_DIR printed above>/{identifier}")"
if [[ ! -f "<WORK_DIR printed above>/{identifier}/state.json" ]] \
   && [[ -f "<WORK_DIR printed above>/{identifier}/spec.md" ]] \
   && [[ -f "$PARENT_DIR/EPIC_PLAN.md" ]]; then
  EPIC_TICKET_NO_STATE=true
  echo "✓ Epic ticket detected (<WORK_DIR printed above>/{identifier}/spec.md + $PARENT_DIR/EPIC_PLAN.md) — no per-ticket state.json expected yet"
fi
# Printed because three later blocks substitute it as
# `<EPIC_TICKET_NO_STATE printed above>`, and this is the block that decides it.
# Without the echo there is nothing for them to substitute.
echo "EPIC_TICKET_NO_STATE=$EPIC_TICKET_NO_STATE"
```

**VALIDATION** (required, skipped when `EPIC_TICKET_NO_STATE == true`):
```bash
# Substitute the literal the earlier block printed: this is a decision already
# made, and recomputing it here would re-decide it against different inputs.
EPIC_TICKET_NO_STATE=<EPIC_TICKET_NO_STATE printed above>
if [[ "$EPIC_TICKET_NO_STATE" == false ]]; then
  # CRITICAL: Verify requirements state file exists
  if [[ ! -f "<WORK_DIR printed above>/{identifier}/state.json" ]]; then
    echo "ERROR: No requirements found for {identifier}"
    echo "Expected: <WORK_DIR printed above>/{identifier}/state.json"
    echo ""
    echo "Please run /create-requirements first (or /epic for a ticketed sub-ticket)."
    exit 1
  fi

  # Validate requirements state file is valid JSON
  if ! jq empty "<WORK_DIR printed above>/{identifier}/state.json" 2>/dev/null; then
    echo "ERROR: Corrupted requirements state file"
    echo "File: <WORK_DIR printed above>/{identifier}/state.json"
    echo ""
    echo "The state file is not valid JSON. It may have been corrupted."
    echo "You may need to regenerate requirements."
    exit 1
  fi

  # Validate requirements phase completed
  req_status=$(jq -r '.status' "<WORK_DIR printed above>/{identifier}/state.json")
  if [[ "$req_status" != "completed" ]]; then
    echo "WARNING: Requirements phase status is: $req_status"
    echo "Expected: completed"
    echo ""
    echo "The requirements may be incomplete. Continue anyway? [y/n]"
    # Use AskUserQuestion or read input
  fi

  echo "✓ Requirements state validated"
fi
```

```bash
# Substitute the literal the earlier block printed: this is a decision already
# made, and recomputing it here would re-decide it against different inputs.
EPIC_TICKET_NO_STATE=<EPIC_TICKET_NO_STATE printed above>
if [[ "$EPIC_TICKET_NO_STATE" == true ]]; then
  # No state.json to read yet — identifier is the argument itself, and the
  # feature branch is resolved/created in the checkout step below (it may
  # not exist yet: /epic never creates branches, only work directories).
  identifier="{identifier}"
  feature_branch="feature/{identifier}"
  base_branch=""
else
  # Load and parse state files
  identifier=$(jq -r '.identifier' "<WORK_DIR printed above>/{identifier}/state.json")
  # After the 0.3 type transition (requirements -> implementation), branches
  # move under .requirements.branches; a fresh requirements-phase state.json
  # still has them at the top level. Try the post-transition path first so
  # resume doesn't silently null these out and empty Phase 5.2's PR target.
  base_branch=$(jq -r '.requirements.branches.base // .branches.base' "<WORK_DIR printed above>/{identifier}/state.json")
  feature_branch=$(jq -r '.requirements.branches.feature // .branches.feature' "<WORK_DIR printed above>/{identifier}/state.json")
fi

# Load implementation state if exists
if [[ -f "<WORK_DIR printed above>/{identifier}/state.json" ]]; then
  if ! jq empty "<WORK_DIR printed above>/{identifier}/state.json" 2>/dev/null; then
    echo "WARNING: Implementation state file is corrupted"
    echo "Starting fresh implementation"
  else
    impl_status=$(jq -r '.status' "<WORK_DIR printed above>/{identifier}/state.json")
    chunks_completed=$(jq -r '.phases.implement.chunks_completed // 0' "<WORK_DIR printed above>/{identifier}/state.json")
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

```bash
WORKTREE_ENABLED=$(resolve_worktree_enabled)
```

Skip this step if `WORKTREE_ENABLED == "false"`.

**If WORKTREE_ENABLED == "true":** Read `references/worktree-setup.md` for the single-mode and multi-mode worktree creation flows plus the `state.json` schema for `worktree`. Apply the procedure that matches `WORKSPACE_MODE`.

---

Ensure on correct branch:

**Single mode (in worktree):** checkout feature branch inside the worktree.
**Multi mode:** branches already set during worktree creation.
**No worktree:** standard checkout.

Run inline — the guard hook allows branch checkout without agent delegation:

```bash
# Substitute the literal the earlier block printed: this is a decision already
# made, and recomputing it here would re-decide it against different inputs.
EPIC_TICKET_NO_STATE=<EPIC_TICKET_NO_STATE printed above>
if git show-ref --verify --quiet "refs/heads/feature/{identifier}"; then
  git checkout feature/{identifier}
elif [[ "$EPIC_TICKET_NO_STATE" == true ]]; then
  # First implementation of this epic ticket — /epic never creates branches,
  # only work directories, so this is the first time feature/{identifier}
  # is created. Branch from wherever the user currently is (epic doesn't
  # switch branches, so this is expected to be the repo's default branch).
  base_branch=$(git branch --show-current)
  git checkout -b feature/{identifier}
  echo "✓ Created feature/{identifier} from $base_branch"
else
  echo "ERROR: Branch feature/{identifier} not found and no epic-ticket bootstrap applies."
  echo "If requirements exist but the branch was deleted, recreate it manually or re-run /create-requirements."
  exit 1
fi
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

If `state.json` doesn't exist or has `type == "implementation"` (resuming), skip creation or load as-is. **If `EPIC_TICKET_NO_STATE == true`**, there is no prior state.json to transition from — go straight to writing the fresh `state.json` below, with `bootstrap_from_epic: true` (this is the one-time epic-ticket bootstrap referenced in Important Notes).

**Transition**: Replace the requirements state by writing a new `state.json` with `type: "implementation"`. Preserve key requirements fields in the `requirements` sub-object:

```json
{
  "schema_version": 1,
  "type": "implementation",
  "identifier": "{identifier}",
  "status": "in_progress",
  "started_at": "{ISO_TIMESTAMP}",
  "bootstrap_from_epic": "{true if EPIC_TICKET_NO_STATE else omit field}",

  "requirements": {
    "branches": {
      "base": "{base_branch from requirements state, or the branch resolved during checkout for epic tickets}",
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

After creating or loading `state.json`, upsert into `${WORK_DIR}/manifest.json` (see `${CLAUDE_PLUGIN_ROOT}/shared/manifest-schema.md` for the envelope/upsert contract).

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

#### 0.5 Register Active Session (for auto-context hook)

If the optional `auto-context.sh` PostToolUse hook is enabled (opt-in via `hooks.auto_context.enabled` in `.claude/configuration.yml`), it resolves the active work-id by reading `${WORK_DIR}/.active-sessions` — a JSON map keyed by the Claude Code `session_id`. Session-starting skills maintain this map.

Register the current session → work-id mapping:

```bash
# A wrong or missing substitution must fail here, not write next to `/`.
[ -n "<WORK_DIR printed above>" ] && [ -d "<WORK_DIR printed above>" ] || exit 1
SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -n "$SID" ] && command -v jq >/dev/null 2>&1; then
  mkdir -p "<WORK_DIR printed above>"
  touch "<WORK_DIR printed above>/.active-sessions.lock"
  (
    flock -x -w 2 200 || exit 0
    [ -s "<WORK_DIR printed above>/.active-sessions" ] || echo '{}' > "<WORK_DIR printed above>/.active-sessions"
    jq --arg s "$SID" --arg w "{identifier}" \
       '. + {($s): $w}' "<WORK_DIR printed above>/.active-sessions" \
       > "<WORK_DIR printed above>/.active-sessions.tmp.$$" \
       && mv "<WORK_DIR printed above>/.active-sessions.tmp.$$" "<WORK_DIR printed above>/.active-sessions" \
       || rm -f "<WORK_DIR printed above>/.active-sessions.tmp.$$"
  ) 200>"<WORK_DIR printed above>/.active-sessions.lock"
fi
```

This step is a no-op when neither `CLAUDE_SESSION_ID` nor `CLAUDE_CODE_SESSION_ID` is set, `jq` is missing, or the hook is disabled — it never fails the skill. The runtime injects `CLAUDE_CODE_SESSION_ID` (preferring `CLAUDE_SESSION_ID` if a future CLI sets it), which equals the id the hook reads from its stdin payload, so the map key matches. A matching clear block runs in the Worktree Exit / completion section at the end of this skill.

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

**Detect input shape first:**

```bash
# Standalone ticket from /create-requirements (full triad)
TRIAD_FULL=false
[ -f "<WORK_DIR printed above>/{identifier}/spec.md" ] && [ -f "<WORK_DIR printed above>/{identifier}/plan.md" ] && [ -f "<WORK_DIR printed above>/{identifier}/tasks.md" ] && TRIAD_FULL=true

# Epic-ticket from /epic (spec-only, parent EPIC_PLAN.md provides shared HOW)
EPIC_TICKET=false
PARENT_DIR="$(dirname "<WORK_DIR printed above>/{identifier}")"
if [ -f "<WORK_DIR printed above>/{identifier}/spec.md" ] \
   && [ ! -f "<WORK_DIR printed above>/{identifier}/plan.md" ] \
   && [ -f "$PARENT_DIR/EPIC_PLAN.md" ]; then
  EPIC_TICKET=true
fi

# Legacy single-doc format
LEGACY=false
[ -f "<WORK_DIR printed above>/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md" ] && [ "$TRIAD_FULL" = false ] && [ "$EPIC_TICKET" = false ] && LEGACY=true

# Guard: partial triad (e.g. crashed mid-Stage-4.2) — none of the three cases matches
if [ "$TRIAD_FULL" = false ] && [ "$EPIC_TICKET" = false ] && [ "$LEGACY" = false ]; then
  echo "ERROR: No complete input found for {identifier}."
  echo "  Expected one of:"
  echo "    A) Full triad: spec.md + plan.md + tasks.md"
  echo "    B) Epic ticket: spec.md + parent EPIC_PLAN.md"
  echo "    C) Legacy: {identifier}-TECHNICAL_REQUIREMENTS.md"
  echo "  Found files in <WORK_DIR printed above>/{identifier}/:"
  ls "<WORK_DIR printed above>/{identifier}/" 2>/dev/null || echo "    (directory does not exist)"
  echo "If a previous /create-requirements run crashed mid-way, re-run it to regenerate the missing files."
  exit 1
fi
```

**Case A — Full triad (from `/create-requirements`):**
```
Load:
- $WORK_DIR/{identifier}/spec.md    ← WHAT/WHY (user stories, Given/When/Then AC with stable IDs)
- $WORK_DIR/{identifier}/plan.md    ← HOW (files to touch, constraints, data model, risks, decision log)
- $WORK_DIR/{identifier}/tasks.md   ← dependency-ordered task list with AC back-references

Plus supporting agent outputs from $WORK_DIR/{identifier}/context/.

Populate pipeline variables:
- {requirements_summary}  = spec.md § Summary + user stories
- {requirements_list}     = acceptance criteria IDs + Given/When/Then from spec.md
- {technical_context}     = plan.md (do NOT re-derive)
- {task_list}             = tasks.md (feed to Plan agent as starting decomposition; refine, don't re-derive)
```

**Case B — Epic-ticket (from `/epic`): bootstrap plan.md + tasks.md before Phase 3.**

The ticket has `spec.md` only; the parent epic provides shared technical context in `EPIC_PLAN.md`. `/implement` must materialize the ticket's `plan.md` and `tasks.md` before Phase 3.

```
1. Read:
   - $WORK_DIR/{identifier}/spec.md           (ticket spec — WHAT/WHY for this ticket)
   - $PARENT_DIR/EPIC_PLAN.md                 (shared epic HOW context)
   - $WORK_DIR/{identifier}/context/*.md      (any context-builder output from epic Phase 5)

2. Use Task tool with subagent_type: "Plan":
   Prompt: |
     Derive a per-ticket Spec-Driven plan.md and tasks.md from this epic ticket's spec
     and the parent epic's shared technical plan.

     Ticket spec:    $WORK_DIR/{identifier}/spec.md
     Parent epic:    $PARENT_DIR/EPIC_PLAN.md
     Ticket context: $WORK_DIR/{identifier}/context/

     Produce TWO marker-delimited blocks (same contract as /create-requirements Stage 4.1):

     ---BEGIN PLAN---
     # Technical Plan — {ticket title}
     ## Approach           (1–2 paragraphs, scoped to this ticket; reference epic plan for shared decisions)
     ## Files to Touch
     ## Architecture Constraints   (inherit from EPIC_PLAN.md, restate only what applies to this ticket)
     ## Data Model        (omit if N/A)
     ## External Integrations  (omit if N/A)
     ## Security & Infrastructure Notes  (cross-ref AC IDs from spec.md, do NOT restate AC)
     ## Risks & Mitigations
     ## Decision Log      (decisions specific to this ticket; defer to EPIC_PLAN.md for cross-ticket calls)
     ---END PLAN---

     ---BEGIN TASKS---
     # Implementation Tasks — {ticket title}
     ## Wave 1 ... (dependency-ordered; every task cites AC IDs from this ticket's spec.md)
     ## Coverage Check (every AC-{ticket-number}.{n} maps to ≥1 task)
     ---END TASKS---

     Layer rules (strict): no HOW in spec; no AC restatement in plan; every task cites AC IDs.

3. Extract blocks → write $WORK_DIR/{identifier}/plan.md and $WORK_DIR/{identifier}/tasks.md.

4. Verify both files exist and tasks.md cites at least one AC ID. If extraction fails, re-invoke
   Plan agent with the missing-block list (same recovery as /create-requirements Stage 4.2).

5. Continue to populate pipeline variables as in Case A.
```

This is a one-time bootstrap per epic ticket — `state.json` records `bootstrap_from_epic: true` so resumes don't re-run it.

**Case C — Legacy single-doc (`{identifier}-TECHNICAL_REQUIREMENTS.md`):** Load as `{technical_context}` and derive `{requirements_list}` + `{task_list}` manually via the Plan agent (no triad expected).

**From file:**
```
Read the requirements file and extract:
- Summary
- Requirements list / acceptance criteria
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
if [[ -f "<WORK_DIR printed above>/{identifier}/context/archaeologist.md" ]]; then
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
  if [[ ! -f "<WORK_DIR printed above>/{identifier}/context/$file" ]]; then
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
  for file in <WORK_DIR printed above>/{identifier}/context/*.json; do
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

Include a **Test Impact** section in the plan listing:
- Existing test fixtures that break due to proposed signature/contract changes (grep callers of any changed constructor, method, or interface — list each affected fixture file)
- Per-fixture changes required to keep the suite green
- New fixtures needed for new code paths (happy path, opt-out, edge cases such as warm-start state)

If a signature change has zero fixture callers, state so explicitly. Do not skip the section.

When the implementation plan spans 2+ independent services (no shared write targets),
recommend parallel chunk execution. Note which chunks are independent and can be
implemented by separate agents simultaneously.
```

#### 2.3 Architecture Validation

**Pre-check**: Before spawning the architect, confirm the Plan agent produced an implementation plan with a non-empty **Test Impact** section (required by 2.2). If absent or empty, re-spawn the Plan agent once with explicit instruction to include the section. Do not proceed with an incomplete plan.

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

### Phase 2 exit: Distill before proceeding

Before moving on to Phase 3, produce a **≤10-line phase summary** of Phase 2 and carry ONLY this summary forward in the orchestration context. Drop the verbose archaeologist / data-modeler / discovery outputs from working memory — they remain on disk at `$WORK_DIR/{identifier}/context/` for re-loading on demand.

The summary should cover:
- **Patterns found** (1–2 lines): the specific existing patterns the plan will follow
- **Plan shape** (2–3 lines): chunks, file boundaries, what each chunk commits
- **Open questions** (1–2 lines): anything explicitly deferred to a later phase
- **Context file paths** (1 line): `context/archaeologist.md`, `context/data-modeler.md`, etc. — for Read()-back if needed

From here on, Phase 3/4/5/6 prompts use this summary. Re-`Read()` a Phase 2 context file **only** when a later phase surfaces a specific question the summary does not answer. Do NOT re-include the full outputs by default.

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

3. **Commit the chunk inline:**

   Review the diff, author a conventional-commit message, and commit. The `git-mutation-guard.sh` hook runs the credential scan on staged files automatically.

   ```bash
   git status --short
   git diff --stat HEAD
   # Per-file diff only when the commit message needs it:
   # git diff HEAD -- <file>
   git add <files>
   ```

   Author the message in this shape:

   ```text
   [{identifier}] <type>(<scope>): <description>

   Chunk: {chunk_description}
   ```

   > **The message never passes through shell source.** It summarises the diff
   > and the ticket text, so by the provenance rule in
   > [`kb-write-pattern.md`](../../shared/kb-write-pattern.md) it is
   > third-party content even though you composed the sentence:
   > "you wrote the words" is not the same as "you made it up".
   > Use the `Write` tool, not a heredoc, not `echo`, not `printf`, to create
   > the message file with the message as its exact contents. A quoted heredoc
   > disables expansion inside the body, but the
   > body still decides where the heredoc *ends*: a diff hunk or a ticket line
   > equal to the delimiter closes it early and everything after it is parsed
   > as commands.
   >
   > The file goes in this session's own work directory, which already exists
   > and already belongs to this session — so there is no `mkdir`/`chmod` step,
   > and no fixed name in a shared `~/.claude/tmp` that a concurrent worktree
   > could overwrite between the `Write` and the commit. One worktree per
   > ticket is this repository's own convention, so concurrent sessions are the
   > normal case. `Write` does not expand `$WORK_DIR`, so pass the resolved
   > absolute path: `<WORK_DIR printed above>/{identifier}/.commit-msg.txt`.
   >
   > The verb below leads its own call: the mutation guard anchors on
   > `^git commit` / `^git push`, so anything ahead of it in the same call
   > skips the credential scan and the push gate. That is also why the `Write`
   > happens before this fence rather than as a step inside it.

   Guard the file in its own call — the commit verb cannot share a block with
   anything ahead of it, and a shell variable would not survive between the two
   calls anyway, so the path is written out in both:

   ```bash
   [ -s "<WORK_DIR printed above>/{identifier}/.commit-msg.txt" ] \
     || { echo "ERROR: commit message file missing or empty" >&2; exit 1; }
   ```

   ```bash
   git commit -F "<WORK_DIR printed above>/{identifier}/.commit-msg.txt" \
     && rm -f "<WORK_DIR printed above>/{identifier}/.commit-msg.txt"
   ```

   The guard matters because the heredoc could not fail this way: the message
   was inline, so it was always there. Reading it from a file introduces a path
   where the `Write` was skipped or failed and `git commit` would otherwise be
   handed an empty message. The delete is gated on the commit succeeding — a
   hook block or a pre-commit failure keeps the message so the retry does not
   have to re-author it.

   No push here — push happens once at the end of the implementation (Phase 5), after security-auditor confirms the full delta.

   **Error Handling for Commit Failure:**

   If the commit fails (hook block, pre-commit hook, merge conflict):
   ```
   ⚠ Failed to commit chunk {N}: {error_message}

   Options:
   [r] Retry commit (re-run after fixing the cause)
   [m] Manual fix (you commit manually, then continue)
   [s] Skip commit (DANGEROUS - work is done but not committed)
   [a] Abort implementation

   Select [r/m/s/a]:
   ```

   Use AskUserQuestion for selection.

   - **r (Retry)**: Re-run the commit (surface any hook findings to the user first)
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

#### 3.2b Deviation Checkpoint

**Goal**: Catch silent scope drift at the chunk it happened in, not at Phase 4.8's end-of-run gap analysis. Codifies the "stop and re-plan if deviating" principle from `plugin/rules/workflow.md` as a pipeline gate instead of leaving it a high-level rule only Phase 4.8 enforces.

```bash
DEVIATION_CHECKPOINT_ENABLED=$(resolve_deviation_checkpoint_enabled)
```

Skip this step if `DEVIATION_CHECKPOINT_ENABLED == "false"` (opt-out via `implement.deviation_checkpoint.enabled: false` in `.claude/configuration.yml` — see Configuration table above). Default is enabled.

**If enabled**, after the chunk commits (3.2 step 3) and before updating state (3.2 step 4), run a fast plan-vs-diff sanity check — this is a mechanical comparison, not a delegated agent call, and it must stay lightweight:

1. Compare the chunk's declared file scope (`chunk.files` from the plan) against `git diff --name-only HEAD~1 HEAD` (the files the commit actually touched).
2. Skim the commit diff against the chunk's `description` for plausibility — does the diff look like it implements what the chunk said it would, or does it read as a different change entirely?

Flag a deviation when either is true:
- The diff touches files outside `chunk.files` (scope creep).
- The diff doesn't plausibly implement the chunk's stated intent.

**No deviation detected**: proceed silently to 3.2 step 4.

**Deviation detected**: use AskUserQuestion with exactly these 3 options:

```
⚠ Chunk {N}/{total} deviated from plan: {one-line description of what changed}

Options:
[1] Re-plan with architect — reassess the remaining chunks given this deviation
[2] Document deviation and continue — record it, keep going as planned
[3] Abort — stop implementation, save state, exit
```

- **1 (Re-plan)**: Use Task tool with `subagent_type: "architect"` — prompt it with the original plan, the deviating chunk's diff, and remaining chunks; apply its revised plan for chunks not yet started.
- **2 (Document and continue)**: Append a `deviation_note` field to the chunk's entry in `state.json` (plan-vs-actual, one line) and proceed to 3.2 step 4.
- **3 (Abort)**: Same abort handling as the 3.2 commit-failure path — save state, exit.

This checkpoint is intentionally shallow — it is not a re-run of Phase 4.8's full requirements-implementation gap analysis (which cross-references every requirement/AC against the whole branch diff via the `architect` agent). It only asks "did *this* chunk stay in its own lane," once per chunk, so it stays fast enough to run unconditionally.

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

#### 4.0 Detect Frontend Changes

Before running QA agents, determine whether the implementation includes frontend changes that warrant Playwright E2E testing.

**Check spec.md for an explicit decision first (AC-6.2), falling back to
the file-change heuristic only when it's absent (AC-6.3 — pre-existing work
from before this AC shipped). Both checks run in one fence** — a value set
in one `Bash` call does not survive into the next tool call, so splitting
this into separate fenced blocks would silently make the fallback always
win:

```bash
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
else
  source "$HOME/.claude/shared/resolve-config.sh"
fi
WORK_DIR=$(resolve_artifact work work)

FRONTEND_CHANGED=""
PLAYWRIGHT_CONFIG_EXISTS=false

[[ -f "playwright.config.ts" ]] || [[ -f "playwright.config.js" ]] && PLAYWRIGHT_CONFIG_EXISTS=true

SPEC_FILE="$WORK_DIR/{identifier}/spec.md"

if [[ -f "$SPEC_FILE" ]] && grep -qE '^AC-E2E-SCOPE:\s*(required|not-required)\s*$' "$SPEC_FILE"; then
  # Anchored, exact-token match only — a free-prose scope description
  # legitimately contains the word "required" either way, so sniffing for
  # it anywhere in the paragraph would make the gate ignore the actual verdict.
  if grep -qE '^AC-E2E-SCOPE:\s*required\s*$' "$SPEC_FILE"; then
    FRONTEND_CHANGED=true
  else
    FRONTEND_CHANGED=false
  fi
  echo "✓ AC-E2E-SCOPE found — using its decision (FRONTEND_CHANGED=$FRONTEND_CHANGED), skipping file-change heuristic"
fi

if [[ -z "$FRONTEND_CHANGED" ]]; then
  FRONTEND_CHANGED=false

  # The file list goes to a file, not onto a command line: a path can legally
  # contain a quote, a backtick or $( ), and echo "{implemented_files}" would
  # execute it. The delimiter is QUOTED so nothing in the body expands.
  # `-m 700` applies only to a directory mkdir actually CREATES, so an existing
  # ~/.claude/tmp at 755 keeps its mode and leaves this list world-readable.
  # The chmod is what closes that, and it runs before anything is written.
  mkdir -p -m 700 "$HOME/.claude/tmp" && chmod 700 "$HOME/.claude/tmp"
  cat > "$HOME/.claude/tmp/implemented-files.txt" <<'IMPLEMENTED_FILES_EOF'
{implemented_files}
IMPLEMENTED_FILES_EOF

  # Check implemented files for frontend extensions or directories
  if grep -qE '\.(tsx|jsx|vue|svelte)$' "$HOME/.claude/tmp/implemented-files.txt"; then
    FRONTEND_CHANGED=true
  elif grep -qE '/(pages|components|views)/' "$HOME/.claude/tmp/implemented-files.txt"; then
    FRONTEND_CHANGED=true
  elif [[ "$PLAYWRIGHT_CONFIG_EXISTS" == "true" ]]; then
    FRONTEND_CHANGED=true
  fi
  echo "✓ No AC-E2E-SCOPE — file-change heuristic used (FRONTEND_CHANGED=$FRONTEND_CHANGED)"
fi
```

**If `$PLAYWRIGHT_CONFIG_EXISTS == "true"`**: the project already opted into Playwright — behavior is unchanged from before. If `FRONTEND_CHANGED=true`, a `playwright-engineer` Task is added to the parallel QA block in Step 4.1 with no further question.

**If `$PLAYWRIGHT_CONFIG_EXISTS == "false"` and `FRONTEND_CHANGED=true`** (frontend files were touched, but the project has no existing Playwright setup): this is a project that has never adopted Playwright — don't silently start generating E2E tests. Resolve the gate:

```bash
PLAYWRIGHT_SCOPING_ENABLED=$(resolve_playwright_scoping_enabled)
```

If `PLAYWRIGHT_SCOPING_ENABLED == "false"` (opt-out via `implement.playwright_scoping.enabled: false` — see Configuration table above), skip the question and resolve the fixed decision instead of asking every run:

```bash
PLAYWRIGHT_SCOPING_DEFAULT=$(resolve_playwright_scoping_default)
```

- `PLAYWRIGHT_SCOPING_DEFAULT == "skip"` (`implement.playwright_scoping.default: skip`) — set `FRONTEND_CHANGED=false` unconditionally; `playwright-engineer` never runs for this project regardless of which files were touched.
- Otherwise (`"heuristic"`, the default when `default` is absent or unrecognized) — fall back to the prior silent-detection behavior: keep `FRONTEND_CHANGED` as the file-extension heuristic already computed it, and `playwright-engineer` runs.

If `PLAYWRIGHT_SCOPING_ENABLED == "true"` (the default), ask via `AskUserQuestion`:

```
Question: "This change touches frontend code and the project has no existing Playwright setup. Write Playwright E2E tests for it?"
Header: "Playwright"
Options:
  - "This change only" — Cover the components/pages touched by this implementation.
  - "Broader coverage" — Also scaffold coverage for related existing frontend flows, not just this diff.
  - "No, skip for now" — Don't write E2E tests; this implementation gets unit/integration coverage only.
```

Set `FRONTEND_CHANGED=false` if "No, skip for now" is chosen (drops `playwright-engineer` from Step 4.1 entirely). Otherwise keep `FRONTEND_CHANGED=true` and record the chosen scope as `PLAYWRIGHT_SCOPE` (`"this change only"` or `"broader coverage"`) — Task 4 in Step 4.1 passes it to `playwright-engineer`.

---

#### 4.0b Architecture Review Gate

`architect` validated the **plan** back in Phase 2.3 — but it never sees the **built code**, which may have drifted from the intended design. This gate adds a design-drift review of the actual diff, but only when the change touches structure (mirrors the conditional in Phase 2.3 and `/pr-review`). Decide `INCLUDE_ARCHITECT` (true/false) by inspecting `{git_diff}` and `{implemented_files}`:

**Include `architect` when the diff does any of:**
- Adds or moves modules/packages, or changes directory/layer boundaries
- Touches shared, core, or cross-cutting services consumed by multiple callers
- Introduces a new dependency direction, DI wiring, or integration seam
- Establishes a new pattern (new base class, abstraction, framework convention) or appears to deviate from an existing one
- Changes public interfaces/contracts between components

**Skip `architect` when the diff is** localized bug fixes, copy/string/config tweaks, test-only changes, dependency bumps, or edits contained within a single existing module that follow its established pattern.

When in doubt on a non-trivial diff, include it. State the gate decision and reason in one line (e.g. `Architecture review: INCLUDED — adds a new shared HttpClient consumed across services`). If `INCLUDE_ARCHITECT=true`, an `architect` Task is added to the parallel QA block in Step 4.1.

---

#### 4.1 Run QA Agents (Autonomous Collaboration)

**Design principle**: QA agents work autonomously, validate each other's findings, and resolve issues among themselves before presenting results to the user. The user reviews a consolidated, pre-validated report — not raw agent output.

**If `$QA_EXEC_MODE` = `"subagent"`:**

##### Step 1: Parallel Initial Review

Run QA agents in parallel as independent tasks (3 always; +1 if `FRONTEND_CHANGED=true`; +1 if `INCLUDE_ARCHITECT=true`).

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

---

Task 4 (only if FRONTEND_CHANGED=true): subagent_type: "playwright-engineer"
Prompt: Write or update Playwright E2E tests for the following frontend changes.

Implemented files:
{implemented_files}

Implementation context:
{what_was_implemented}

Scope: {PLAYWRIGHT_SCOPE if set, e.g. "this change only" or "broader coverage"; omit this line entirely when $PLAYWRIGHT_CONFIG_EXISTS was already true — no scoping question ran, so no scope was chosen}

Requirements:
- Detect existing Playwright setup (playwright.config.ts, test files, page objects) before writing
- Write tests covering user-visible behavior for the changed components/pages; honor the Scope above when writing to a project that just adopted Playwright for this change
- Follow existing test patterns; use Page Object Model if already in use
- Prefer getByRole/getByLabel locators; avoid CSS selectors and XPath
- Return: test files created and a brief coverage summary

---

Task 5 (only if INCLUDE_ARCHITECT=true): subagent_type: "architect"
Prompt: Validate this implementation against the codebase's established architecture and patterns. You are reviewing finished code, not a plan — assess whether what was built drifted from the intended design.

Diff: {git_diff}
Implemented files: {implemented_files}
Intended plan (validate the code against it): $WORK_DIR/{identifier}/plan.md

Focus on:
- Architecture/layer compliance — does the change respect module boundaries and dependency direction?
- SOLID violations introduced by the implementation
- Design-pattern consistency — does new code follow established patterns, or invent a divergent one?
- Naming and structural conventions versus the surrounding codebase
- Drift from the Phase 2.3 plan — did implementation diverge from the approved design without justification?

Report design-level findings only, with file/line references, categorized CRITICAL/IMPORTANT/MINOR. Do not duplicate correctness or security review (those run separately).
```

Save all agent outputs to `$WORK_DIR/{identifier}/context/`:
- `qa-test-writer.md`
- `qa-code-reviewer.md`
- `qa-security-auditor.md`
- `qa-architect.md` (if `INCLUDE_ARCHITECT=true`)

##### Step 1b: Output-Presence Check (mandatory)

After the parallel QA tasks return, verify every expected output file exists and has non-trivial content before advancing to the skeptic step:

```bash
# Substitute the literal the earlier block printed.
FRONTEND_CHANGED=<FRONTEND_CHANGED printed above>
qa_agents=(test-writer code-reviewer security-auditor)
[[ "$FRONTEND_CHANGED" == "true" ]] && qa_agents+=(playwright-engineer)
# `architect` is added here too when the Phase 4 gate above decided to include
# it. That decision is yours, made by reading the diff — it is not a shell value
# and no block computes it, so there is nothing to carry and nothing to
# substitute. Add the element when the gate said INCLUDED, and leave this line
# out when it did not. Reading `$INCLUDE_ARCHITECT` here, as this block used to,
# read an unset variable and never added the agent at all.

for agent in "${qa_agents[@]}"; do
  f="<WORK_DIR printed above>/{identifier}/context/qa-${agent}.md"
  if [[ ! -s "$f" ]] || [[ $(wc -c <"$f") -lt 200 ]]; then
    echo "⚠ Missing or under-threshold output: $f — halting. Re-spawn the responsible agent with the same prompt. After one re-spawn failure, escalate via AskUserQuestion. Do NOT advance to the skeptic step."
    exit 1
  fi
done
```

Rationale: a silent agent failure (no output file) has historically advanced the pipeline to PR without security or test coverage. The skeptic can only verify findings it receives — it cannot detect *missing* agents. The presence check catches the failure at the earliest stage and blocks progression.

##### Step 2: Skeptic Challenge

After the QA agents complete, run the quality-guard to challenge their combined findings.

**Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Independently review this implementation, THEN reconcile against the QA findings. Review the actual diff yourself first and form your own view of where it breaks before reading the agents' findings below — the new issues you find come from your own pass, not from re-litigating their list.

Implementation diff: {git_diff}
Spec (acceptance criteria — verify implementation satisfies each AC ID): $WORK_DIR/{identifier}/spec.md
Plan (intended approach): $WORK_DIR/{identifier}/plan.md
Tasks (expected coverage): $WORK_DIR/{identifier}/tasks.md
(Fallback: $WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md if triad absent.)

QA agent outputs (read these files):
- $WORK_DIR/{identifier}/context/qa-test-writer.md
- $WORK_DIR/{identifier}/context/qa-code-reviewer.md
- $WORK_DIR/{identifier}/context/qa-security-auditor.md
- $WORK_DIR/{identifier}/context/qa-playwright-engineer.md (if present — frontend changes only)
- $WORK_DIR/{identifier}/context/qa-architect.md (if present — architecture gate fired)

Your job (Level 2 — Implementation Validation), in this order:
1. Independent pass FIRST: trace the code paths in the diff yourself and surface issues the agents missed — this is your primary value, not an afterthought.
2. Verify the implementation matches the requirements — not just "code works" but "code does what was asked".
3. Check test coverage: do the tests actually cover the critical paths, or do they test trivial cases?
4. Now reconcile the agents' findings: verify each CRITICAL finding against the actual code — did the reviewer cite the right file/line? Are any over- or under-stated?
5. Cross-reference: does the code-reviewer's "no issues" on a file contradict what security-auditor found? If architect findings are present, check whether a proposed design change conflicts with a correctness or security constraint.

This is the terminal review before PR — report all severities (BLOCKING / IMPORTANT / ADVISORY); do not suppress medium/low findings to save space. There is no later pass to catch what you drop.

When a gate maps to one or more acceptance criteria from the spec, prefix it with the AC ID(s) (e.g., `GATE 3: AC-2.1 — ...`) and note each AC's grader-typed evidence — this feeds the per-AC PASS/FAIL table assembled in Phase 4.5. See `${CLAUDE_PLUGIN_ROOT}/shared/eval-concepts.md` (or `~/.claude/shared/eval-concepts.md` for local/dev copies).

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

**Deadlock protocol (max resolution iterations: 2)**: After two rounds of agent resolution, remaining open gates are escalated to the user in Phase 4.5. Do NOT continue iterating — present all submissions, objections, and attempted resolutions to the user for a decision: override, provide guidance, or abort. See `${CLAUDE_PLUGIN_ROOT}/shared/principles.md` (or `~/.claude/shared/principles.md` for local/dev copies) for the full deadlock protocol.

---

**If `$QA_EXEC_MODE` = `"team"` (default):**

Read `references/qa-team-mode.md` for team mode QA execution details (TeamCreate, task assignment, cross-pollination, shutdown). In team mode, the quality-guard joins as a teammate and challenges findings via SendMessage in real-time rather than in sequential steps.

**IMPORTANT**: Regardless of mode, the output of Phase 4.1 is the same — a set of QA findings categorized by severity, plus test files written, PLUS a skeptic validation report. Subsequent phases (4.2 onward) process these findings identically.

#### 4.1.5 Distill QA Outputs to Disk

After Phase 4.1 converges (both modes have produced the QA files, and any agent-resolution rounds are complete), write a distilled `-summary.md` sibling for each full output. This keeps `/resume-work` and `/load-context` cheap on resume — they prefer the summary variant by default.

For each file at `$WORK_DIR/{identifier}/context/qa-{agent}.md` that exists (`qa-test-writer.md`, `qa-code-reviewer.md`, `qa-security-auditor.md`, `qa-quality-guard.md`, `qa-playwright-engineer.md` if frontend changes were detected, and `qa-architect.md` if the architecture gate fired):

1. `Read()` the full file
2. Distill to **≤10 lines**, concrete only:
   - Verdict line (e.g., `APPROVED`, `CRITICAL: 2 / IMPORTANT: 3 / MINOR: 1`, `PASSED`)
   - Top 3–5 findings with `file:line` references — actionable items only, no prose
   - Outstanding blockers or deferred items (if any)
3. `Write()` to `$WORK_DIR/{identifier}/context/qa-{agent}-summary.md`

The full `.md` files remain authoritative and are retained for audit and for on-demand `Read()` when a downstream step needs detail. Consumers (`/resume-work`, `/load-context`) fall back to the full file when the summary is absent (e.g., legacy work dirs).

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

For auto-fixable issues, apply fixes and create an additional commit inline:

```bash
git add <files>
```

> The verb below leads its own call: the mutation guard anchors on
> `^git commit` / `^git push`, so anything ahead of it in the same call
> skips the credential scan and the push gate.

```bash
git commit -m "[TICKET-123] fix(review): address review feedback"
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

Per-AC Verification (only when spec.md present — see assembly note below):
  | AC ID  | Verdict | Grader | Evidence                    |
  |--------|---------|--------|-----------------------------|
  | AC-1.1 | PASS    | rule   | src/Foo.php:45              |
  | AC-2.1 | FAIL    | code   | UserTest::testExport failed |
```

**Per-AC table assembly** (only when `$WORK_DIR/{identifier}/spec.md` exists): correlate the AC-tagged gate entries in `context/qa-quality-guard.md` against the AC list in `spec.md`. Emit **one row per AC** — when a single gate covers several ACs, repeat that gate's evidence on each AC's row (never collapse). The Grader column is the AC's own `grader:` tag from spec.md; Verdict ∈ PASS / FAIL / UNVERIFIED; Evidence follows the grader type (`code`→file:line or test excerpt, `rule`→structural assertion, `model`→judgment note, `human`→sign-off) per `${CLAUDE_PLUGIN_ROOT}/shared/eval-concepts.md` (or `~/.claude/shared/eval-concepts.md` for local/dev copies). Source is `qa-quality-guard.md` only — never `gap-analysis.md`. Phase 4.5 is a single pass (pass@1): do **not** print pass^k framing here. When no spec.md exists, omit this section entirely.

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

**If critical issues found**: Read `references/quality-gate-auto-fix.md` for the auto-fix loop (up to 2 refactorer attempts per issue, sequential, with re-validation) and the commit step that follows (4.7.3). After the loop completes, return here and continue with 4.7.4.

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

→ Proceed to Phase 4.8 (requirements gap analysis)
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
- **2 (Proceed anyway)**: Continue to Phase 4.8 (gap analysis still runs) with critical issues documented in PR description as warnings:
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

#### 4.8 Requirements-Implementation Gap Analysis (mandatory)

**Goal**: Before PR creation, verify each requirement from Phase 1 was actually implemented in the branch diff. Blocks silent scope drift and missed requirements from reaching PR.

Run this *after* the quality gate passes and *before* Phase 5.

**Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Produce a diff-level implementation gap analysis.

Requirements (from Phase 1):
{requirements_list}

Acceptance Criteria:
{acceptance_criteria}

Branch diff:
{output of `git diff {base_branch}...HEAD`}

Commits:
{commit_list from state}

Cross-reference each requirement and acceptance criterion against the actual diff:

For each item, produce a row:
| Requirement | Status       | Evidence (file:line / commit) |
|-------------|--------------|-------------------------------|
| Req 1       | IMPLEMENTED  | src/Foo.php:45, commit abc123 |
| Req 2       | PARTIAL      | Only happy-path added; opt-out path missing |
| Req 3       | MISSING      | No diff touches this area     |

Also flag:
- Any diff hunks that do NOT trace back to a specific requirement (scope creep)
- Any known pre-implementation risks (from planning phase) not addressed in the diff

Return the table plus a verdict line: COMPLETE | PARTIAL | MISSING_ITEMS.
```

Save output to `$WORK_DIR/{identifier}/gap-analysis.md`.

**Gate decision:**

- **COMPLETE**: Proceed to Phase 5.
- **PARTIAL or MISSING_ITEMS**: Use AskUserQuestion:
  ```
  Gap analysis found {n} unimplemented/partial requirements:
  {rows}

  Options:
  [1] Return to implementation to address gaps
  [2] Proceed to PR with gaps documented in description
  [3] Abort
  ```

When proceeding with gaps (option 2), the PR body MUST include a "Known Gaps" section listing the PARTIAL/MISSING rows verbatim.

Update state:
```json
{
  "phases": {
    "gap_analysis": {
      "status": "completed",
      "verdict": "COMPLETE | PARTIAL | MISSING_ITEMS",
      "report_path": "{identifier}/gap-analysis.md"
    }
  }
}
```

---

### Phase 4 exit: Distill before proceeding

Before moving on to Phase 5, produce a **≤10-line phase summary** of the Phase 4 QA outcome and carry ONLY this summary forward. Drop the verbose per-agent findings (`context/qa-test-writer.md`, `context/qa-code-reviewer.md`, `context/qa-security-auditor.md`, `context/qa-quality-guard.md`) and the aggregated `$WORK_DIR/{identifier}/qa-gate-report.md` from working memory — they remain on disk.

The summary should cover:
- **Gate verdict** (1 line): APPROVED / CONDITIONAL / REJECTED from quality-guard
- **What was fixed and what was accepted** (2–3 lines): auto-fix outcomes, accepted-with-rationale items
- **Test results** (1–2 lines): count by type, coverage, any known skips
- **Outstanding risks** (1–2 lines): items the PR description should mention explicitly
- **Context file paths** (1 line): the four per-agent QA files under `context/` plus the aggregated `qa-gate-report.md` at `$WORK_DIR/{identifier}/` — for Read()-back if needed

Phase 5 (PR creation) and Phase 6 (final report) prompts use this summary. Re-`Read()` a QA file **only** when the PR description genuinely needs a verbatim finding or line reference the summary does not provide.

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

Before the push, record the security-auditor confirmation for the final HEAD (the push hook will block otherwise):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
```

> The verb below leads its own call: the mutation guard anchors on
> `^git commit` / `^git push`, so anything ahead of it in the same call
> skips the credential scan and the push gate.

```bash
git push -u origin feature/{identifier}
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

Fetch the target branch before computing the commit range so the PR body reflects the real delta against current upstream:

```bash
git fetch -q origin {target_branch} 2>/dev/null || true
```

For a short commit range (≤ 10 commits, a handful of files), author the PR inline with `gh pr create`:

The title and the body are both assembled from the diff, the ticket and the QA
findings, so both are third-party content by the provenance rule in
[`kb-write-pattern.md`](../../shared/kb-write-pattern.md) — neither goes through
a heredoc. `Write` them to this session's own work directory, each the exact
value and nothing else; `Write` does not expand `$WORK_DIR`, so pass resolved
absolute paths.

Author the title in this shape — the ticket prefix is not optional, and it is
the only place the convention is stated for the PR:

```text
[{identifier}] <type>(<scope>): <description>
```

Author the body in this shape:

```text
## Summary
{feature_summary}

## Ticket
{identifier}

## Changes
- {bullet per logical change}

## Technical Details
{notable patterns}

## Testing
- [ ] {verification steps}

{If FAILED_OVERRIDE:}
⚠️ KNOWN CRITICAL ISSUES (user approved proceeding):
- [{issue_id}] {description} in {file}:{line}

{If remaining findings:}
## Remaining Review Findings
🟡 Important: {important_issues}
🔵 Minor: {minor_issues}
```

Then:

```bash
[ -s "<WORK_DIR printed above>/{identifier}/.pr-title.txt" ] \
  && [ -s "<WORK_DIR printed above>/{identifier}/.pr-body.md" ] \
  || { echo "ERROR: PR title or body file missing or empty" >&2; exit 1; }
```

```bash
gh pr create \
  --base {target_branch} \
  --head feature/{identifier} \
  --title "$(cat "<WORK_DIR printed above>/{identifier}/.pr-title.txt")" \
  --body-file "<WORK_DIR printed above>/{identifier}/.pr-body.md" \
  && rm -f "<WORK_DIR printed above>/{identifier}/.pr-title.txt" \
           "<WORK_DIR printed above>/{identifier}/.pr-body.md"
```

> `--body-file` rather than `--body "$(cat …)"`: the body never becomes a shell
> word at all, so its size is not bounded by `ARG_MAX` and no quoting question
> arises. The title still goes through `"$(cat …)"` because `gh pr create` has
> no `--title-file` — that is safe, because command substitution makes the
> content an argument *value* rather than shell source. What is not safe is the
> shape this replaced: a `--title "[{identifier}] <type>(<scope>): <description>"`
> built by interpolation, where a `"` or `$(…)` in the description breaks out of
> the quoted string as this command is constructed, before `gh` ever sees it.
>
> Both deletes are gated on `gh` succeeding, so a failed create keeps the files
> and the retry does not have to re-author the body.


For a **large commit range** (10+ commits or wide file changes), delegate PR body authoring only (not the `gh pr create` call itself):

```
Use Task tool with subagent_type: "git-operator"
Prompt: Author a PR body for feature/{identifier} covering commits {base}..HEAD. Return title + body only.
```

Then run `gh pr create` with the returned title/body inline.

#### 5.3b Offer Archival (PR-creation trigger)

**Goal**: Honor `requirements.archive_on_pr` — the "a pull request was just opened" trigger. This is one of **two distinct** archive trigger points; the other is Phase 6.3 (ticket completion). They are deliberately not collapsed into a single OR-checked call site: PR creation happens here in Phase 5, structurally before Phase 6, so a single post-Phase-6 site could not tell the two occasions apart.

**Skip this step entirely if no PR was created** (the user chose to skip at 5.2). The trigger is "a PR was just opened"; with no PR there is nothing to trigger on, and no config check is needed to establish that — it falls out of control flow.

Read the flag. **Read nothing else** — in particular do NOT `source resolve-config.sh` and do NOT call `resolve_artifact_typed`. That resolver fabricates a default `.claude/requirements` path for an install that never configured a KB, where the archivist's own resolution correctly refuses. Deciding *whether to offer* needs one boolean; deciding *whether the KB is usable* is the archivist's job:

```bash
# Walk up for the config: a hardcoded relative path fails when /implement runs
# from a subdirectory, and a failed read must not silently become "offer anyway".
CFG=""; _d="$PWD"
while [[ "$_d" != "/" ]]; do
  [[ -f "$_d/.claude/configuration.yml" ]] && { CFG="$_d/.claude/configuration.yml"; break; }
  _d="$(dirname "$_d")"
done

# Do NOT write `// true` here. yq and jq treat a literal `false` as empty, so
# `archive_on_pr // true` returns true for `archive_on_pr: false` and the
# documented opt-out silently stops working. Test the raw value instead — the
# same reasoning resolve-config.sh states at its deviation-checkpoint helper.
ARCHIVE_ON_PR=true
if [[ -n "$CFG" ]]; then
  _raw=$(yq -r '.requirements.archive_on_pr' "$CFG" 2>/dev/null)
  [[ "$_raw" == "false" ]] && ARCHIVE_ON_PR=false
fi
ARCHIVED_STATUS=$(jq -r '.phases.archived.status // "pending"' "<WORK_DIR printed above>/{identifier}/state.json" 2>/dev/null || echo pending)
echo "ARCHIVE_ON_PR=$ARCHIVE_ON_PR ARCHIVED_STATUS=$ARCHIVED_STATUS"
```

**If `ARCHIVE_ON_PR` is not `true`**: skip silently. No offer, no archivist dispatch (AC-4.2).

**If `ARCHIVED_STATUS` is `completed`**: skip silently — already archived this run.

**Otherwise**, present a genuine offer via AskUserQuestion:

```
This ticket's requirements can be archived to the team knowledge base, so future
requirements work can find them.

  [1] Yes — archive now (the archive is carried into the PR you just opened)
  [2] No  — skip archival
```

Then apply the **negative-consent rule** in §5.3c below before acting on any answer.

**On an affirmative selection**: dispatch `Task(archivist, "STORE ...")` for `{identifier}`. The archivist resolves the KB path and storage type itself and refuses cleanly if none is configured. Then branch on **what it actually reported** — do not assume it stored:

- **Stored successfully** → record `status: completed` per §5.3e, then follow §5.3d for the publish. **Say so**: name what was archived and where. Its two sibling branches below both report; a silent success is the one outcome the user cannot distinguish from nothing having happened.
- **Refused because no KB is configured** → record `status: unavailable` per §5.3e. Skip §5.3d entirely (there is nothing to publish), and say plainly that archival was skipped because no requirements knowledge base is configured. This is a configuration state, not a transient failure — do not offer again at Phase 6.3.
- **Failed for any other reason** → record `status: failed` per §5.3e, skip §5.3d, and follow §6.3b's fail-soft reporting including the manual retry command.

Recording `completed` for an archive that did not happen is the failure mode this branch exists to prevent: Phase 6.3 would then skip silently and the user would be told nothing was wrong.

**On a decline**: write nothing. Leave `phases.archived.status` at `pending` so Phase 6.3 can offer once more at completion — a materially different occasion, not a repeat of this one. The knowledge base must be byte-identical to its pre-offer state (AC-3.5, AC-SEC-5).

#### 5.3c Negative consent — the offer must fail closed

This rule applies at **both** trigger points (5.3b and 6.3) and exists because an unattended run must never archive on presumed consent.

**Archive only when an option the run actually offered is selected and echoed back verbatim in the run's own output.** Treat every other outcome as a decline:

| Outcome | Action |
|---|---|
| `AskUserQuestion` is unavailable in this session | **Skip** — do not archive, do not improvise a prose question and proceed |
| The tool errors | **Skip** |
| The tool returns no selection | **Skip** |
| The run cannot obtain an answer (non-interactive, timeout) | **Skip** |
| An echo that matches no option this run offered | **Skip** |
| A verbatim match to an offered affirmative option, evidenced by the tool's own result | Archive |

**A prose echo of the option text is not evidence.** The affirmative option's wording appears verbatim in this file, so an improvising agent can reproduce it without any user having chosen anything. Consent requires the `AskUserQuestion` tool result itself; absent that result object, treat it as a decline no matter what the transcript says.

The unavailable-tool row is not hypothetical. Measured on Claude Code 2.1.235: under `claude -p`, `AskUserQuestion` is **absent from the toolset entirely** — a `ToolSearch` for it returns "No matching deferred tools found" — and an agent that finds no tool will otherwise improvise a prose question that nobody answers, then carry on with the run reporting success. Tool absence does not by itself produce a safe default; this table is what produces one.

**A user who wants archival in unattended runs opts in through configuration, never through a defaulted-yes prompt.** Note that `auto_archive` and `archive_on_pr` govern *whether to offer*, not whether consent may be presumed — neither is standing consent (AC-4.1, AC-SEC-6).

#### 5.3d Publish the archive into the open PR

**Applies only when 5.3b actually archived AND the archivist reported it took the directory branch.** If it reported the git-backed branch, it has already pushed the archive to the separate KB remote and the host branch gained no commit — there is nothing here to publish, so skip this step entirely. Running it anyway would spend a security-auditor pass, stamp an audit, push the host branch, and report the archive was carried into the PR when it was not.

This keys on the archivist's **reported outcome** (its STORE step 8), not on resolving `_TYPE` here — the call sites resolve nothing themselves.

The archivist commits but never pushes (its STORE step 7 branch B is publish-free by design, so the archive operation itself cannot disable this repo's protections). Carrying the archive into the already-open PR is therefore **this skill's** ordinary guarded publish, performed here.

> **The audit gate makes this conditional on a fresh review — this is not optional.** `git-mutation-guard.sh` blocks any push whose recorded audit sha differs from current HEAD. Phase 5.1 stamped the audit record immediately before its push; the archive commit moves HEAD past that stamp, so this publish is **stale by construction**. Re-stamping with `record-audit.sh` without an actual review would assert a security review that never happened, which AC-SEC-7 exists to forbid.

1. Run a genuine `security-auditor` pass over **everything this push will publish**, not just the archive commit:

```bash
git diff @{u}..HEAD
```

   The scope matters. `record-audit.sh` stamps HEAD and `git push` publishes *every* unpushed commit on the branch — so auditing only `HEAD~1..HEAD` would stamp as reviewed any commit made between Phase 5.1's push and this one. Review what actually ships. The archive commit itself carries content copied wholesale from the work directory, including `context/` agent outputs that may hold externally-authored text, so this is a real review rather than a formality.
2. Only if it comes back clean, record it and publish:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
```
```bash
git push
```

3. **If the auditor is not clean, or the push is blocked**: do not retry with any bypass. Fall back to Phase 6.3's local-only semantics — report that the archive is committed locally and did not reach the PR, and name the manual retry. Never promise review coverage that did not occur.

#### 5.3e Record the archive outcome (shared by both trigger points)

**Both** Phase 5.3b and Phase 6.3 write this; it is stated once here and referenced from both so the two cannot drift. Only the skill lead writes `state.json` — the archivist never does.

Write it **immediately after the archivist returns**, before attempting any publish. If the write is skipped, `phases.archived.status` stays `pending`, Phase 6.3 reads `pending`, and the user is offered archival a second time and a second archivist STORE runs for the same ticket in the same run — precisely the double-ask the two-site design exists to prevent (AC-3.3).

```json
{
  "phases": {
    "archived": {
      "status": "completed",
      "trigger": "archive_on_pr | auto_archive",
      "published": false,
      "declined_at": []
    }
  }
}
```

- `status`: one of —
  - `completed` — the archivist reported a successful store. Set this **independent of whether the publish in §5.3d then succeeds**: the archive exists either way, and publishing only determines whether it rides along in the PR.
  - `pending` — not yet attempted, or offered and declined. The other trigger may still offer.
  - `unavailable` — the archivist refused because no knowledge base is configured. Both triggers treat this as skip-silently: re-offering cannot succeed, because the cause is configuration and will not change mid-run.
  - `failed` — the archivist errored for any other reason. Both triggers treat this as skip-silently too, and the run reports the failure with the manual retry per §6.3b. Distinguished from `unavailable` so the report can say which happened.
- `trigger`: which flag produced the accepted offer.
- `published`: set `true` only after §5.3d's push actually succeeds; leave `false` on the local-only fallback path, and on every non-`completed` status.
- `declined_at`: append the trigger name on a decline (`"archive_on_pr"` or `"auto_archive"`) and leave `status` at `pending`. This is what lets a report distinguish "never offered" from "offered and turned down".

**Never record `completed` on a path where the archivist did not report a successful store.** A false `completed` makes Phase 6.3 skip silently, so the user is never told the archive did not happen.

#### 5.4 Offer PR Review

```
✓ PR created: {pr_url}

Would you like to run /pr-review on this PR? [y/n]
```

If yes, trigger `/pr-review {pr_number}`.

#### 5.5 Update Work Manifest (Final)

Update the work manifest to reflect completion (see `${CLAUDE_PLUGIN_ROOT}/shared/manifest-schema.md` for the envelope/upsert contract).

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
| Explore | built-in | Phase 2 | Codebase exploration |
| Plan | built-in | Phase 2 | Implementation planning |
| {agent} | {tier} | {phase} | {purpose} |

## Summary
- Opus agents: {count}
- Sonnet agents: {count}
- Lightweight mode: {yes/no}
```

**Read `{tier}` from each agent's own frontmatter — never from a list written here.**
Emit one row per agent this run actually spawned, in spawn order, and take its tier from
that agent's static frontmatter at the time you write the summary:
`grep -m1 '^model:' "${CLAUDE_PLUGIN_ROOT}/agents/{agent}.md"` (quoted; or
`"$HOME/.claude/agents/{agent}.md"` for local/dev copies), or the `Read` tool, which has
no shell-interpolation surface at all. Validate `{agent}` against `^[a-z][a-z0-9-]*$`
before it reaches any command, and omit the row rather than run an unvalidated value.
Map the pinned ID to its bare tier word by reading the tier segment of the ID itself
(`claude-<tier>-<version>` → `<tier>`), never by matching a hardcoded list of IDs — a
list goes stale on the next model bump, the segment does not. `/create-requirements`
builds its own telemetry table exactly this way.

A table of agent names and tiers written out here would be a second source of truth for
data that already lives in frontmatter: correct on the day it is written, silently wrong
the first time an agent changes tier, and invisible to the reader of either file. Keep
the row templated.

`Explore` and `Plan` are built-in Claude Code subagent types, not files in this
plugin, so their tier is set by the runtime rather than by frontmatter we can read.
Record them as `built-in` and leave them out of the Opus/Sonnet counts — this repo has
no way to verify which tier they resolve to, and three skills previously asserted two
different answers for `Plan`. Counting a guess would make the cost summary confidently
wrong rather than honestly incomplete.


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

Requirements archive: {one of —
  "archived to {kb_path}, carried into the PR"        (status completed, published true)
  "archived to {kb_path}, committed locally only"     (status completed, published false)
  "declined"                                          (status pending, declined_at non-empty)
  "not offered"                                       (both triggers disabled)
  "skipped — no knowledge base configured"            (status unavailable)
  "FAILED — retry with /archive-requirements {identifier}"  (status failed)}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

> **Ordering note.** §6.2 prints the final report, and this section can still change
> `phases.archived`. Read `phases.archived` when composing §6.2's archive line, and if the
> completion offer below then archives, state that outcome too rather than leaving the printed
> report as the last word. The two must not disagree.

#### 6.3 Offer Archival (ticket-completion trigger)

**Goal**: Honor `requirements.auto_archive` — the "the ticket is finished" trigger. The second of the two distinct trigger points (see Phase 5.3b for why they are separate call sites).

Unlike 5.3b this fires regardless of whether a PR exists.

```bash
# Same walk-up and same explicit-false handling as §5.3b — see the comment there
# for why `// true` cannot be used for a boolean that ships defaulting to true.
CFG=""; _d="$PWD"
while [[ "$_d" != "/" ]]; do
  [[ -f "$_d/.claude/configuration.yml" ]] && { CFG="$_d/.claude/configuration.yml"; break; }
  _d="$(dirname "$_d")"
done

AUTO_ARCHIVE=true
if [[ -n "$CFG" ]]; then
  _raw=$(yq -r '.requirements.auto_archive' "$CFG" 2>/dev/null)
  [[ "$_raw" == "false" ]] && AUTO_ARCHIVE=false
fi
ARCHIVED_STATUS=$(jq -r '.phases.archived.status // "pending"' "<WORK_DIR printed above>/{identifier}/state.json" 2>/dev/null || echo pending)
echo "AUTO_ARCHIVE=$AUTO_ARCHIVE ARCHIVED_STATUS=$ARCHIVED_STATUS"
```

**If `AUTO_ARCHIVE` is not `true`**: skip silently (AC-4.2).

**If `ARCHIVED_STATUS` is `completed`**: skip **silently** — 5.3b already archived this run.

**If `ARCHIVED_STATUS` is `unavailable` or `failed`**: skip, and do not re-offer. 5.3b already tried and reported why. `unavailable` means no knowledge base is configured, which a second prompt cannot fix; `failed` is surfaced with its retry command by §6.3b. Re-asking here would be nagging about something the user has already been told. Present no second offer and dispatch no second archivist. This is what keeps "both flags enabled" — the shipped default — from becoming a guaranteed double-ask. To be precise about the ceiling: accepting anywhere means one offer; declining at the PR trigger means two offers at two genuinely different moments, and zero archives unless one is accepted.

**If `ARCHIVED_STATUS` is `pending` and 5.3b offered and was declined**: offer once more. The decline at PR creation was a decline of *that* occasion; ticket completion is a materially different one.

Read nothing but the flag — the same no-path-resolution rule as 5.3b applies here.

Present the same offer, then apply §5.3c's negative-consent rule.

**On an affirmative selection**: dispatch `Task(archivist, "STORE ...")`. No publish step follows here — Phase 5's push is long past — so the archive is **local-only**. Say so plainly in the report (AC-1.5): name what was preserved, state that it is committed locally and reaches the team through the operator's normal review-and-merge flow, and warn that an unmerged archive commit is discarded if its branch is later abandoned. Do not describe it as "shared" or "durable" without that qualification.

**On a decline**: write nothing; the knowledge base stays byte-identical (AC-3.5, AC-SEC-5).

**Record the outcome** exactly as specified in §5.3e — same fields, same rules. `published` is always `false` here: no publish step follows Phase 6.

#### 6.3b Archive failure is never fatal

An archive failure at either trigger MUST NOT block completion. Report it plainly and continue to a normal finish.

**Name the manual retry explicitly: `/archive-requirements {identifier}`.** This matters more than it looks. Phase 5.6 already wrote `status: "completed"` to `state.json` **before** Phase 6 runs, and `/resume-work` filters out completed items — so an interrupted or failed 6.3 is **not reachable through resume**. The single-ticket skill is the only path back, and it is explicitly designed for this case. A user who is not told the command has no way to discover it (AC-3.6, AC-5.1).

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
- **Git mutations run inline**: commit, push, checkout, and worktree setup run inline via Bash, hook-guarded by `git-mutation-guard.sh` (branch protection, credential scan, security-auditor push gate via `record-audit.sh`). `git-operator` is used only for large-commit-range PR body authoring (Phase 5, conditional) — not for routine commits or pushes
- **Quality gate**: Critical QA issues must be resolved (or explicitly overridden) before PR creation
- **Auto-fix feedback loop**: Critical issues get up to 2 auto-fix attempts via refactorer (second attempt includes failure context), with targeted re-validation
- **PR workflow**: Target branch from requirements phase, with confirmation
- **Review integration**: Offers `/pr-review` after PR creation
- **Branch protection**: NEVER push directly to release/main/master branches
- **Ticket requirement**: Commit messages MUST include ticket number from branch in `[TICKET-123]` format
- **Worktree isolation**: When `worktree.enabled: true`, implementation runs in an isolated worktree. State files persist in the original workspace root. On completion, the worktree is kept (not removed) so the user can inspect or continue work

## Completion Cleanup

After Phase 5 (PR creation) completes — or if the skill ends early for any reason — clear the session from the auto-context sentinel (complements Phase 0.5). No-op when the feature is not in use:

```bash
# A wrong or missing substitution must fail here, not write next to `/`.
[ -n "<WORK_DIR printed above>" ] && [ -d "<WORK_DIR printed above>" ] || exit 1
SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -n "$SID" ] \
   && [ -f "<WORK_DIR printed above>/.active-sessions" ] \
   && command -v jq >/dev/null 2>&1; then
  (
    flock -x -w 2 200 || exit 0
    jq --arg s "$SID" 'del(.[$s])' "<WORK_DIR printed above>/.active-sessions" \
       > "<WORK_DIR printed above>/.active-sessions.tmp.$$" \
       && mv "<WORK_DIR printed above>/.active-sessions.tmp.$$" "<WORK_DIR printed above>/.active-sessions" \
       || rm -f "<WORK_DIR printed above>/.active-sessions.tmp.$$"
  ) 200>"<WORK_DIR printed above>/.active-sessions.lock"
fi
```

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
