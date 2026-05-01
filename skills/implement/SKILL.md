---
name: implement
category: implementation
model: claude-opus-4-7
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

#### 0.5 Register Active Session (for auto-context hook)

If the optional `auto-context.sh` PostToolUse hook is enabled (opt-in via `hooks.auto_context.enabled` in `.claude/configuration.yml`), it resolves the active work-id by reading `${WORK_DIR}/.active-sessions` — a JSON map keyed by the Claude Code `session_id`. Session-starting skills maintain this map.

Register the current session → work-id mapping:

```bash
if [ -n "${CLAUDE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
  mkdir -p "$WORK_DIR"
  touch "$WORK_DIR/.active-sessions.lock"
  (
    flock -x -w 2 200 || exit 0
    [ -s "$WORK_DIR/.active-sessions" ] || echo '{}' > "$WORK_DIR/.active-sessions"
    jq --arg s "$CLAUDE_SESSION_ID" --arg w "{identifier}" \
       '. + {($s): $w}' "$WORK_DIR/.active-sessions" \
       > "$WORK_DIR/.active-sessions.tmp.$$" \
       && mv "$WORK_DIR/.active-sessions.tmp.$$" "$WORK_DIR/.active-sessions" \
       || rm -f "$WORK_DIR/.active-sessions.tmp.$$"
  ) 200>"$WORK_DIR/.active-sessions.lock"
fi
```

This step is a no-op when `CLAUDE_SESSION_ID` is unset, `jq` is missing, or the hook is disabled — it never fails the skill. A matching clear block runs in the Worktree Exit / completion section at the end of this skill.

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
[ -f "$WORK_DIR/{identifier}/spec.md" ] && [ -f "$WORK_DIR/{identifier}/plan.md" ] && [ -f "$WORK_DIR/{identifier}/tasks.md" ] && TRIAD_FULL=true

# Epic-ticket from /epic (spec-only, parent EPIC_PLAN.md provides shared HOW)
EPIC_TICKET=false
PARENT_DIR="$(dirname "$WORK_DIR/{identifier}")"
if [ -f "$WORK_DIR/{identifier}/spec.md" ] \
   && [ ! -f "$WORK_DIR/{identifier}/plan.md" ] \
   && [ -f "$PARENT_DIR/EPIC_PLAN.md" ]; then
  EPIC_TICKET=true
fi

# Legacy single-doc format
LEGACY=false
[ -f "$WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md" ] && [ "$TRIAD_FULL" = false ] && [ "$EPIC_TICKET" = false ] && LEGACY=true

# Guard: partial triad (e.g. crashed mid-Stage-4.2) — none of the three cases matches
if [ "$TRIAD_FULL" = false ] && [ "$EPIC_TICKET" = false ] && [ "$LEGACY" = false ]; then
  echo "ERROR: No complete input found for {identifier}."
  echo "  Expected one of:"
  echo "    A) Full triad: spec.md + plan.md + tasks.md"
  echo "    B) Epic ticket: spec.md + parent EPIC_PLAN.md"
  echo "    C) Legacy: {identifier}-TECHNICAL_REQUIREMENTS.md"
  echo "  Found files in $WORK_DIR/{identifier}/:"
  ls "$WORK_DIR/{identifier}/" 2>/dev/null || echo "    (directory does not exist)"
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
   git commit -m "$(cat <<'EOF'
[TICKET-123] type(scope): description

Chunk: {chunk_description}
EOF
)"
   ```

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

Before running QA agents, determine whether the implementation includes frontend changes that warrant Playwright E2E testing:

```bash
FRONTEND_CHANGED=false

# Check implemented files for frontend extensions or directories
if echo "{implemented_files}" | grep -qE '\.(tsx|jsx|vue|svelte)$'; then
  FRONTEND_CHANGED=true
elif echo "{implemented_files}" | grep -qE '/(pages|components|views)/'; then
  FRONTEND_CHANGED=true
elif [[ -f "playwright.config.ts" ]] || [[ -f "playwright.config.js" ]]; then
  FRONTEND_CHANGED=true
fi
```

If `FRONTEND_CHANGED=true`, a `playwright-engineer` Task is added to the parallel QA block in Step 4.1.

---

#### 4.1 Run QA Agents (Autonomous Collaboration)

**Design principle**: QA agents work autonomously, validate each other's findings, and resolve issues among themselves before presenting results to the user. The user reviews a consolidated, pre-validated report — not raw agent output.

**If `$QA_EXEC_MODE` = `"subagent"`:**

##### Step 1: Parallel Initial Review

Run QA agents in parallel as independent tasks (3 always; 4 if `FRONTEND_CHANGED=true`).

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

Requirements:
- Detect existing Playwright setup (playwright.config.ts, test files, page objects) before writing
- Write tests covering user-visible behavior for the changed components/pages
- Follow existing test patterns; use Page Object Model if already in use
- Prefer getByRole/getByLabel locators; avoid CSS selectors and XPath
- Return: test files created and a brief coverage summary
```

Save all agent outputs to `$WORK_DIR/{identifier}/context/`:
- `qa-test-writer.md`
- `qa-code-reviewer.md`
- `qa-security-auditor.md`

##### Step 1b: Output-Presence Check (mandatory)

After the parallel QA tasks return, verify every expected output file exists and has non-trivial content before advancing to the skeptic step:

```bash
qa_agents=(test-writer code-reviewer security-auditor)
[[ "$FRONTEND_CHANGED" == "true" ]] && qa_agents+=(playwright-engineer)

for agent in "${qa_agents[@]}"; do
  f="$WORK_DIR/{identifier}/context/qa-${agent}.md"
  if [[ ! -s "$f" ]] || [[ $(wc -c <"$f") -lt 200 ]]; then
    echo "⚠ Missing or under-threshold output: $f — halting. Re-spawn the responsible agent with the same prompt. After one re-spawn failure, escalate via AskUserQuestion. Do NOT advance to the skeptic step."
    exit 1
  fi
done
```

Rationale: a silent agent failure (no output file) has historically advanced the pipeline to PR without security or test coverage. The skeptic can only verify findings it receives — it cannot detect *missing* agents. The presence check catches the failure at the earliest stage and blocks progression.

##### Step 2: Skeptic Challenge

After all three QA agents complete, run the quality-guard to challenge their combined findings.

**Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Review the QA findings from three agents and challenge their work.

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

#### 4.1.5 Distill QA Outputs to Disk

After Phase 4.1 converges (both modes have produced the four QA files, and any agent-resolution rounds are complete), write a distilled `-summary.md` sibling for each full output. This keeps `/resume-work` and `/load-context` cheap on resume — they prefer the summary variant by default.

For each file at `$WORK_DIR/{identifier}/context/qa-{agent}.md` that exists (`qa-test-writer.md`, `qa-code-reviewer.md`, `qa-security-auditor.md`, `qa-quality-guard.md`, and `qa-playwright-engineer.md` if frontend changes were detected):

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

```bash
gh pr create \
  --base {target_branch} \
  --head feature/{identifier} \
  --title "[{identifier}] <type>(<scope>): <description>" \
  --body "$(cat <<'EOF'
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
EOF
)"
```

For a **large commit range** (10+ commits or wide file changes), delegate PR body authoring only (not the `gh pr create` call itself):

```
Use Task tool with subagent_type: "git-operator"
Prompt: Author a PR body for feature/{identifier} covering commits {base}..HEAD. Return title + body only.
```

Then run `gh pr create` with the returned title/body inline.

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
| playwright-engineer | sonnet | Phase 4 | E2E tests (frontend changes only) |
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
- **Git-operator delegation**: All git mutation operations (checkout, commit, push, PR creation) go through git-operator agent. Read-only checks (`git branch --show-current`, `git diff-index`) and worktree setup (`git worktree add`) run inline — git-operator does not support worktree operations
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
