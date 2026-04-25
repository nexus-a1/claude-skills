---
name: create-requirements
category: planning
model: claude-opus-4-7
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

## Outputs — Spec-Driven Triad

This skill produces the canonical **Spec-Driven Development** triad — three artifacts with distinct audiences:

1. **`state.json`** — State file for resume capability
2. **`context/`** — Cached agent outputs for reference
3. **`spec.md`** — WHAT & WHY. User stories + Given/When/Then acceptance criteria. Product-facing, no implementation details.
4. **`plan.md`** — HOW. Technical approach, files to touch, data model, integrations, risks. Implementer-facing.
5. **`tasks.md`** — EXECUTE. Dependency-ordered, AC-linked task list. Agent-/engineer-executable.
6. **`{identifier}-JIRA_TICKET.md`** — Derived view of `spec.md` for pasting into a tracker. Not a peer artifact.

All saved to `$WORK_DIR/{identifier}/`.

**Layer boundary rule:** If a statement answers *HOW* or references specific code, it belongs in `plan.md` — never in `spec.md`. `tasks.md` entries MUST cite at least one acceptance-criterion ID from `spec.md`.

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
- **State files**: Only the skill lead writes to `state.json` and final output documents (`spec.md`, `plan.md`, `tasks.md`, `{identifier}-JIRA_TICKET.md`).
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
```

**VALIDATION**: The ticket MUST match pattern `[A-Z]+-[0-9]+` (e.g., JIRA-123, SKILLS-001).
If user provides a slug instead of ticket number, ask them to provide the ticket number.

Store as `{ticket}`. The full `{identifier}` is composed in §1.4 after the feature context is known.

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

#### 1.4 Derive Work Identifier

With `{ticket}` (from §1.1) and the refined requirements (§1.3) now in hand, derive a kebab-case slug (2–5 meaningful words, lowercase, ASCII, joined with `-`) from the refined requirements. Drop filler words. Confirm with the user via AskUserQuestion:

```
Derived slug: {slug}
Proposed work identifier: {ticket}-{slug}
Accept, or enter a different slug?
```

**Compose `{identifier}` = `{ticket}-{slug}`** (per the Work Directory Naming Convention in `CLAUDE.md`).

This will be used for:
- Branch name: `feature/{identifier}`
- Work directory: `$WORK_DIR/{identifier}/`
- Commit messages: `[{ticket}] type(scope): description` (commit prefix stays ticket-only)
- Output files: `spec.md`, `plan.md`, `tasks.md`, `{identifier}-JIRA_TICKET.md`

---

#### 1.5 Select Base Branch

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

#### 1.6 Create Feature Branch (Local Only)

**CRITICAL**: This step MUST complete successfully before proceeding.

Create the branch locally. Remote push is deferred to Stage 2 (after initial context has been gathered).

Run inline — local branch creation has no hook restrictions beyond the existing guard:

```bash
git checkout -b feature/{identifier} {base_branch}
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

#### 1.7 Initialize Work Directory

```bash
mkdir -p $WORK_DIR/{identifier}/context
```

#### 1.8 Initialize State File

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

#### 1.9 Register Active Session (for auto-context hook)

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

No-op when `CLAUDE_SESSION_ID` is unset or `jq` is missing. Enables the optional `auto-context.sh` PostToolUse hook to route entries to this session's `state.json`. Cleared at Stage 4.11 completion.

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

Read `references/team-mode-protocol.md` § "Stage 2.1" for the TeamCreate call, task graph definition (T1–T9), and TaskUpdate dependency wiring.

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

Run inline. No new commits have been made yet — we're pushing the branch pointer only — so security-auditor state from the base branch's HEAD applies. Record it first:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
git push -u origin feature/{identifier}
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

Read `references/team-mode-protocol.md` § "Stage 3.3" for the TaskList monitoring loop, 10-line distillation rule, and SendMessage format for cross-pollinating completed agent findings.

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

### Stage 3 exit: Distill before proceeding

Before moving on to Stage 4, produce a **≤10-line stage summary** of the Stage 3 deep-dive and carry ONLY this summary forward in the orchestration context. Drop the verbose per-agent outputs (archaeologist, architect, data-modeler, integration-analyst, aws-architect, security-requirements, archivist, product-expert) from working memory — they remain on disk at `$WORK_DIR/{identifier}/context/`.

The summary should cover:
- **Key findings per agent** (3–5 lines): one line per agent that ran, capturing the single most important decision/constraint/risk each surfaced
- **Contradictions or open questions** (1–2 lines): anything the agents disagreed on or explicitly flagged for business-analyst to resolve
- **Context file paths** (1 line): `context/archaeologist.md`, `context/architect.md`, ... — the business-analyst prompt below already tells the agent to Read() these directly, so the orchestrator does NOT need to carry their full contents

The business-analyst agent (Stage 4.1) reads the full files from disk via its prompt. The orchestrator does not need the full outputs in context to run Stage 4; the summary is enough to monitor progress and answer follow-ups. If Stage 4 deadlocks or produces re-synthesis questions, Re-`Read()` specific context files **only for the question at hand** — do not re-include all of them.

#### Distill Stage 3 Outputs to Disk

Alongside the ≤10-line orchestrator summary above (which lives only in working memory), write per-agent **disk summaries** so `/resume-work` and `/load-context` don't reload full deep-dive outputs on restart.

For each Stage 3 file that exists under `$WORK_DIR/{identifier}/context/` (`archaeologist.md`, `architect.md`, `data-modeler.md`, `integration-analyst.md`, `aws-architect.md`, `security-requirements.md`, `archivist.md`, `product-expert.md`):

1. `Read()` the full file
2. Distill to **≤10 lines**, concrete only:
   - One-line verdict (e.g., `PATTERNS: 3 stable / 2 risky`, `SCHEMA: compatible with proposed FK`, `SEC: 1 control gap`)
   - Top 3–5 findings with `file:line` or table/column references
   - Open questions or conflicts flagged for business-analyst (if any)
3. `Write()` to `$WORK_DIR/{identifier}/context/{agent}-summary.md`

The full `.md` files remain the authoritative source. Stage 4.1 (business-analyst) still reads the full files via its prompt because synthesis needs the complete reasoning. Summaries are strictly for **cheaper downstream resume** — consumers (`/resume-work`, `/load-context`) fall back to the full file when the summary is absent.

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
2. **Mechanism verification (mandatory pre-check before writing MUST requirements):**
   For each implementation mechanism you intend to state as a MUST requirement, verify it appears in `discovery.json` (or another agent's findings) with a compatible API signature. If a mechanism is asserted without supporting evidence — or if the discovered signature is incompatible with the intended use (e.g., per-record accessor used as a batch query) — flag it as `BLOCKER: unverified mechanism` instead of writing it as a MUST. This prevents downstream rework from QA-gate-detected structural flaws.
3. Resolve any conflicts between agent findings
4. Prioritize requirements (MoSCoW)
5. Identify risks (Technical, Business, Timeline)
6. **Business decisions table:** For each open business decision (defaults, opt-in/out, scope, rollout), produce a table with columns `Decision | Options | Stakeholder Implications | Recommended Default`. Include this table even if `product-expert` did not run.
7. Validate against user's acceptance criteria from refinement phase
8. Note any performance considerations (queries, caching, scalability)

Produce FOUR documents, separated by the exact markers shown below. This follows **Spec-Driven Development**: spec describes WHAT/WHY, plan describes HOW, tasks describe EXECUTION, jira is a derived summary.

**Layer boundary — enforce strictly:**
- `SPEC` contains NO file paths, class names, library choices, or code. Only user stories and observable behavior.
- `PLAN` contains the HOW — file paths, patterns, data schemas, integration contracts, risks.
- `TASKS` is a numbered, dependency-ordered list. Every task MUST cite one or more AC IDs from SPEC (format: `Covers: AC-1.2, AC-3.1`).
- `JIRA_TICKET` is a light paste-ready summary derived from SPEC — no HOW details.

Token budgets: SPEC ≤1500, PLAN ≤2500, TASKS ≤1200, JIRA_TICKET ≤800.

Use this EXACT format:

---BEGIN SPEC---
# {Feature Title}

## Summary
(One paragraph: WHAT the feature is and WHY it matters. No HOW.)

## User Stories
- **US-1**: As a {role}, I want {capability}, so that {outcome}.
- **US-2**: ...

## Acceptance Criteria
Each AC is a Given/When/Then scenario, grouped under its user story. Assign stable IDs (AC-{story}.{n}).

### AC for US-1
- **AC-1.1**
  - Given {precondition}
  - When {action}
  - Then {observable outcome}
- **AC-1.2** ...

### AC for US-2
...

## Security & Compliance Criteria
(From `security-requirements` if present — expressed as Given/When/Then, e.g. authn/authz, data handling, audit.)
- **AC-SEC-1** ...

## Out of Scope
- {explicit exclusions}

## Open Questions
- {surfaced by synthesis or skeptic — or "None" }
---END SPEC---

---BEGIN PLAN---
# Technical Plan — {Feature Title}

## Approach
(2–3 paragraphs: narrative of the chosen approach and WHY it fits the existing architecture.)

## Files to Touch
(From archaeologist; `path — purpose`.)
- `src/...` — ...

## Architecture Constraints
(From architect: layer rules, DI patterns, SOLID concerns, dependency direction.)

## Data Model
(From data-modeler if present: entity changes, migrations, indices, query patterns. Omit section if N/A.)

## External Integrations
(From integration-analyst if present: API contracts, webhook patterns, resilience. Omit if N/A.)

## Security & Infrastructure Notes
(Implementation-level notes from security-requirements / aws-architect. Do NOT restate AC — cross-ref `AC-SEC-*`.)

## Risks & Mitigations (MoSCoW)
| Priority | Risk | Mitigation |
|----------|------|------------|
| Must | ... | ... |

## Decision Log
(Conflict resolutions from synthesis — format: `Decision | Options | Chosen | Rationale`.)
---END PLAN---

---BEGIN TASKS---
# Implementation Tasks — {Feature Title}

Ordered by dependency. Every task cites one or more AC IDs from SPEC.

## Wave 1 (no dependencies)
- [ ] **T-1** — {Short title}
  - Scope: {1–2 lines — what this task produces}
  - Covers: AC-1.1, AC-1.2
- [ ] **T-2** — ...
  - Covers: AC-2.1

## Wave 2 (depends on Wave 1)
- [ ] **T-3** — ...
  - Depends on: T-1
  - Covers: AC-1.3

## Parallelization
Tasks safe to run concurrently: {T-1, T-2}; {T-4, T-5}.

## Coverage Check
Every AC in SPEC maps to at least one task:
- AC-1.1 → T-1
- AC-1.2 → T-1
- ...
---END TASKS---

---BEGIN JIRA_TICKET---
# {Feature Title}

**Summary** (1 paragraph — paste-ready for ticket body)

**Background**
- Problem:
- Impact:
- Solution (at a glance):

**Acceptance Criteria**
- AC-1.1: {one-line collapsed form of the Given/When/Then}
- AC-1.2: ...

**Out of Scope**
- ...

**Links**
- Full spec: `spec.md`
- Technical plan: `plan.md`
- Task breakdown: `tasks.md`
---END JIRA_TICKET---

IMPORTANT: Use the exact ---BEGIN/END--- markers. They are used to extract each document into separate files. Do NOT include HOW details in SPEC or JIRA_TICKET. Do NOT restate AC content in PLAN — reference by ID.
```

**Team mode extra**: Add to prompt: `"Mark your task as completed when done."`

**Note**: Performance review is deferred to implementation phase where code-reviewer can analyze actual code changes.

#### 4.2 Save Outputs

Save all synthesis outputs to the work directory:

```bash
# Save business-analyst raw output
# Write to: $WORK_DIR/{identifier}/context/business-analyst.md

# Save the four triad documents
# Write to: $WORK_DIR/{identifier}/spec.md
# Write to: $WORK_DIR/{identifier}/plan.md
# Write to: $WORK_DIR/{identifier}/tasks.md
# Write to: $WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md
```

Extract the four documents using the `---BEGIN/END---` markers:

1. Content between `---BEGIN SPEC---` and `---END SPEC---` → save as `$WORK_DIR/{identifier}/spec.md`
2. Content between `---BEGIN PLAN---` and `---END PLAN---` → save as `$WORK_DIR/{identifier}/plan.md`
3. Content between `---BEGIN TASKS---` and `---END TASKS---` → save as `$WORK_DIR/{identifier}/tasks.md`
4. Content between `---BEGIN JIRA_TICKET---` and `---END JIRA_TICKET---` → save as `$WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md`
5. Save the complete raw business-analyst response → `$WORK_DIR/{identifier}/context/business-analyst.md`

**If markers are missing**: The business-analyst did not follow the output contract. Save the entire response as `$WORK_DIR/{identifier}/context/business-analyst.md`, log an ERROR naming which marker(s) were missing, and re-invoke the business-analyst with the prompt appended: "Your previous output was missing block(s): {LIST}. Re-emit using the exact four-block format." Do not proceed past Stage 4.2 without all four files present.

**VERIFICATION** (required):
```bash
missing=0
for f in spec.md plan.md tasks.md "{identifier}-JIRA_TICKET.md"; do
  if [[ ! -f "$WORK_DIR/{identifier}/$f" ]]; then
    echo "ERROR: $f not saved"
    missing=1
  fi
done
[[ $missing -eq 1 ]] && exit 1

# Verify business-analyst raw output was saved
if [[ ! -f "$WORK_DIR/{identifier}/context/business-analyst.md" ]]; then
  echo "WARNING: Business analyst raw output not saved to context/"
fi

# Lightweight triad coherence checks
if ! grep -qE '^##? *Acceptance Criteria' "$WORK_DIR/{identifier}/spec.md"; then
  echo "WARNING: spec.md has no Acceptance Criteria section"
fi
if ! grep -qE 'AC-[0-9A-Z]' "$WORK_DIR/{identifier}/tasks.md"; then
  echo "WARNING: tasks.md does not cite any AC IDs — tasks must link back to spec"
fi

echo "✓ Triad (spec/plan/tasks) + JIRA view saved"
```

#### 4.5 Resolve Flagged Issues (Conditional)

**Goal**: If the business-analyst flagged contradictions, coverage gaps, or unresolved assumptions in its output, resolve them by spawning targeted re-analysis agents.

Read `references/resolve-flagged-issues.md` for the complete conditional re-analysis protocol — flag detection, sub-agent and team mode variants, example prompts, verification, and state updates.

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

# Overwrite the four triad documents
# Write to: $WORK_DIR/{identifier}/spec.md
# Write to: $WORK_DIR/{identifier}/plan.md
# Write to: $WORK_DIR/{identifier}/tasks.md
# Write to: $WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md
```

Extract using the same four-block `---BEGIN/END---` marker logic as Stage 4.2 (SPEC, PLAN, TASKS, JIRA_TICKET).

**If markers are missing**: Use the same recovery as Stage 4.2 — re-invoke business-analyst with an explicit list of missing blocks.

**VERIFICATION** (required):
```bash
missing=0
for f in spec.md plan.md tasks.md "{identifier}-JIRA_TICKET.md"; do
  if [[ ! -f "$WORK_DIR/{identifier}/$f" ]]; then
    echo "ERROR: Re-synthesized $f not saved"
    missing=1
  fi
done
[[ $missing -eq 1 ]] && exit 1

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

**When to run**: Check `plan.md`. If any of these conditions are true, run this step:
- Plan modifies shared/core services used by multiple features
- Plan introduces new dependency injection or service wiring patterns
- Plan changes global configuration scope or environment variables

**If none of the conditions are met**: Skip this stage.

**Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Validate the architectural decisions in this technical plan.

Plan: $WORK_DIR/{identifier}/plan.md
(Reference only — do NOT propose changes to) Spec: $WORK_DIR/{identifier}/spec.md

Focus on:
1. Are conflict resolutions between agents architecturally sound?
2. Do proposed patterns align with existing codebase architecture?
3. Are there hidden coupling or scaling concerns?
4. Does the plan respect the architecture constraints it claims to follow?

Do NOT challenge WHAT/WHY — that belongs to spec.md and is out of scope here.
If you find HOW-level issues, recommend specific corrections to plan.md.
Return: Validation result (APPROVED / CONCERNS) with details.
```

**If CONCERNS raised**: Present to user via AskUserQuestion with the architect's feedback. Allow the user to accept, modify, or override.

Save architect output to `$WORK_DIR/{identifier}/context/architect-validation.md`.

#### 4.8 Skeptic Validation

**Goal**: Challenge the synthesized requirements through an independent adversarial review before declaring them complete.

**Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Review the Spec-Driven triad as a skeptic challenger.

Spec (WHAT/WHY):      $WORK_DIR/{identifier}/spec.md
Plan (HOW):           $WORK_DIR/{identifier}/plan.md
Tasks (EXECUTE):      $WORK_DIR/{identifier}/tasks.md
JIRA view:            $WORK_DIR/{identifier}/{identifier}-JIRA_TICKET.md
Agent context files:  $WORK_DIR/{identifier}/context/

Report findings per layer — do NOT conflate layers:

1. **Spec gates** — unstated assumptions, vague/unfalsifiable acceptance criteria, missing edge cases, scope gaps, HOW-leakage (any file path, class name, or library choice in spec.md is a violation).
2. **Plan gates** — unverified mechanisms, file paths that don't exist, patterns that conflict with the codebase, hidden coupling, missing risk mitigations, claims not backed by an agent context file.
3. **Tasks gates** — every AC in spec.md must be covered by at least one task; every task must cite AC IDs; dependency ordering sound; no task silently introduces scope not in spec.
4. **Cross-layer gates** — JIRA view accurately reflects spec; plan covers every AC; decision log justifies HOW choices against spec intent.

Cross-reference claims against the actual codebase — verify file paths, patterns, and assumptions.

Focus on Level 1 (Requirements Validation). Do NOT review implementation code — there is none yet.
Return a Quality Review Gates report grouped by the four categories above.
```

**Process the skeptic's verdict:**

- **APPROVED**: Continue to completion. Log: `"skeptic_verdict": "approved"`
- **CONDITIONAL**: Present the blocking gates to the user via AskUserQuestion. The user decides whether to:
  - **Address gates**: Re-run targeted agents (like Stage 4.5) to resolve, then re-run skeptic
  - **Override**: Accept requirements as-is, note overridden gates in state
  - **Abort**: Stop and revisit requirements
- **REJECTED**: Present fundamental issues to the user. Requirements need rework — return to appropriate stage.

**Max iterations**: 2. If skeptic raises gates, agents address them, and skeptic still has concerns after a second pass, document remaining concerns in the `## Open Questions` section of `spec.md` (for WHAT/WHY gaps) or the `## Risks & Mitigations` section of `plan.md` (for HOW concerns), then proceed.

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

Read `references/team-mode-protocol.md` § "Stage 4.8.5" for the SendMessage shutdown sequence, TeamDelete call, and state update.

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
    "spec": "spec.md",
    "plan": "plan.md",
    "tasks": "tasks.md",
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

Output Files (Spec-Driven triad):
  - spec.md                          ← WHAT / WHY (user stories + Given/When/Then AC)
  - plan.md                          ← HOW (technical approach, files, data, risks)
  - tasks.md                         ← EXECUTE (dependency-ordered, AC-linked)
  - {identifier}-JIRA_TICKET.md      ← derived view for ticket paste

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

Read `references/error-handling.md` for error recovery procedures (branch creation fails, agent fails, team creation fails, remote push fails). All error recovery uses AskUserQuestion.

---

## Quality Checklist

Read `references/quality-checklist.md` for the full stage-by-stage verification checklist.
