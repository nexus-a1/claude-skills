---
name: update-documentation
model: claude-sonnet-5
category: documentation
userInvocable: true
description: Review and update project documentation using an agent team. Inventories docs, identifies gaps and drift, updates technical and API docs in parallel.
argument-hint: "[scope|path]"
allowed-tools: "Read, Write, Edit, Glob, Grep, Bash(source:*), Bash(echo:*), Bash(git log:*), Bash(git diff:*), Bash(git rev-list:*), Bash(git rev-parse:*), Bash(mkdir:*), Bash(date:*), Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage"
---

# Update Documentation

## Goal

Systematically review and update project documentation using an agent team. Discovers documentation gaps, identifies drift from current code, and updates technical and API docs in parallel.

## Outputs

- Updated documentation files (in-place edits)
- New documentation files (if gaps identified)
- Summary of all changes made

---

## Configuration

Read `.claude/configuration.yml` for execution mode. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `execution_mode` | `"team"` | Documentation phase execution mode (reads `documentation_update` phase override) |

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
DOC_EXEC_MODE=$(resolve_exec_mode documentation_update team)
```

Use `$DOC_EXEC_MODE` to determine team vs sub-agent behavior in Phases 2-4.

---

## Process

### Phase 1: Setup & Scope

**Goal**: Determine what documentation to review and what triggered the update. Beyond file changes, this phase is **session-aware** — it also folds in what was discussed and agreed during the session, gated by whether the code actually implements it (1.5).

#### 1.1 Parse Scope

Check $ARGUMENTS for a scope hint (e.g., a specific path, "api", "readme").

#### 1.2 Get Documentation Scope

**If $ARGUMENTS specified a path, use that path as the scope and skip the question below.**

Otherwise, use AskUserQuestion:
```
question: "What documentation should we review and update?"
options:
  - label: "All documentation"
    description: "Full audit of all docs in the project"
  - label: "README + architecture"
    description: "Top-level README and architecture docs"
  - label: "API documentation only"
    description: "API endpoints, OpenAPI specs, API guides"
  - label: "Recently changed areas"
    description: "Docs related to recently modified code"
```

#### 1.3 Get Update Trigger

Use AskUserQuestion:
```
question: "What triggered this documentation update?"
options:
  - label: "New feature added"
    description: "Code was added that needs documentation"
  - label: "Documentation audit"
    description: "Periodic review for accuracy and completeness"
  - label: "API changes"
    description: "API endpoints were added, changed, or removed"
  - label: "Architecture changes"
    description: "System architecture or patterns changed"
```

#### 1.4 Gather Git Context

Determine recent changes to inform the update. Either command may fail — outside a git repo, or `HEAD~10` on a repo with fewer than 10 commits. A failure here is never fatal: use whatever output succeeded.

```bash
# Recent commits (fails harmlessly outside a git repo)
git log --oneline -20

# Files changed recently — if HEAD~10 does not exist (young repo), retry
# against the root commit: git diff --stat $(git rev-list --max-parents=0 HEAD)
git diff --stat HEAD~10
```

Store the combined output as `{git_context}`. If both commands failed, set `{git_context}` to empty and continue — the skill works without git history.

#### 1.5 Gather Session Context (code-confirmed)

Git history tells you *what* changed; it does not tell you *why*, or which discussed solution a change represents. This step adds that missing signal — but **only for solutions the code actually implements**. A solution that was merely discussed, rejected, or deferred is not documentation-worthy and must be excluded.

**Source A — this conversation (primary).** Reason over the current context window and extract candidate items: solutions discussed and agreed for implementation, design decisions with their rationale, renamed or newly-introduced concepts, and behavior changes. This is inline reasoning — do **not** delegate to a subagent and do **not** read raw transcript files; only the in-context conversation is available.

**Source B — persisted session notes (enrichment, optional).** If this work has an active ticket, its `state.json` `updates[]` already holds the decisions and scope notes `/update-context` recorded (entries tagged `source:"synthesis"` plus plain manual notes). Resolve the ticket from the branch and locate its state file. Shell state does not persist between Bash tool calls, so this block re-sources `resolve-config.sh` and resolves `WORK_BASE` itself — it does not depend on 1.6 having run — and must run as a single invocation:

```bash
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
  exit 1
fi
WORK_BASE=$(resolve_artifact work work)

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
case "$BRANCH" in
  feature/*) TICKET_ID="${BRANCH#feature/}" ;;
  *)         TICKET_ID="" ;;
esac

# A branch name is untrusted input flowing into a filesystem path. Reject
# anything that is not a safe path segment before using it (mirrors
# update-context/SKILL.md and auto-context.sh:84).
if [ -n "$TICKET_ID" ] && ! [[ "$TICKET_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  TICKET_ID=""
fi

if [ -n "$TICKET_ID" ] && [ -f "${WORK_BASE}/${TICKET_ID}/state.json" ]; then
  echo "SESSION_STATE=${WORK_BASE}/${TICKET_ID}/state.json"
else
  echo "SESSION_STATE=none"   # no active ticket / no state file — Source A only
fi
```

If the block echoes a `SESSION_STATE=` path, Read that file and fold its `updates[].note` values into the candidate list. `SESSION_STATE=none` (missing ticket or file) is not an error — fall back to Source A alone.

**The code-confirmation gate (mandatory).** For every candidate from A or B, verify it is reflected in the actual changes before treating it as a documentation driver:

- Cross-check against `{git_context}` (the diff/log from 1.4); when a candidate names a symbol or file, confirm with `git diff HEAD~10 -- <path>` or a `Grep` of the working tree.
- **Include** a candidate only when the code implements the discussed solution — discussed **and** agreed **and** present in the diff/tree.
- **Exclude** anything discussed-but-not-implemented (rejected alternatives, deferred ideas, hypotheticals). Keep these in a short `{excluded_context}` list so the exclusion stays transparent in the final summary (5.3) — never silently drop them, and never document them.

Store the surviving, code-confirmed items as `{session_context}` — concise bullets, each paired with the file or commit that confirms it. If nothing is both discussed and confirmed, set `{session_context}` empty and continue; the skill still works from git history alone.

#### 1.6 Create Work Directory

Anchor the work directory to the configured artifact location (`resolve_artifact` falls back to `.claude/work` when no configuration exists) so state resolves to the workspace root even under worktrees or custom storage.

Shell state does not persist between Bash tool calls, so this block re-sources `resolve-config.sh` and must run as a single invocation:

```bash
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
  exit 1
fi
WORK_BASE=$(resolve_artifact work work)
WORK_DIR="${WORK_BASE}/doc-update-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${WORK_DIR}/context"
echo "$WORK_DIR"
```

Store the echoed path as `{work_dir}` and use it verbatim in all later phases (the shell variable will not survive into subsequent Bash calls).

---

### Phase 2: Discovery

**Goal**: Inventory all documentation and map it to source code.

#### 2.1 Setup Execution

**If `$DOC_EXEC_MODE` = `"team"` (default):**

```
TeamCreate(team_name="doc-update-{timestamp}")
```

Create Task Graph:
```
T1: "Discover and inventory documentation" (no deps)
T2: "Analyze documentation gaps and priorities" (blocked by T1)
T3: "Update all documentation (technical + API)" (blocked by T2)
T4: "Review consistency" (blocked by T3) — handled by lead
```

Use TaskCreate and TaskUpdate to set dependencies.

**If `$DOC_EXEC_MODE` = `"subagent"`:**

Skip TeamCreate. Agents run as independent sub-agent tasks. No task graph needed — orchestrator manages execution order directly.

#### 2.2 Run Context Builder

**Team mode** — Spawn as teammate with `team_name` and `name` parameters.
**Sub-agent mode** — Run as independent Task (no `team_name`/`name`).

```
Task(
  subagent_type="context-builder",
  # Team mode only:
  # team_name="doc-update-{timestamp}",
  # name="context-builder",
  prompt="Inventory all documentation in the project.

Scope: {scope}
Recent git changes: {git_context}
Code-confirmed session decisions: {session_context}

Discover and catalog:
1. All .md files with their purpose and last-modified date
2. OpenAPI/Swagger specs (if any)
3. Inline code documentation (JSDoc, PHPDoc, etc.)
4. Map each doc to the source code it describes
5. Identify recently changed code without corresponding doc updates
6. Detect documentation drift (docs describing behavior code no longer implements)
7. For each code-confirmed session decision above, locate the doc that should explain it (the decision supplies the *why*/intent the diff alone cannot); flag it as a gap if no doc covers it

Save output to {work_dir}/context/discovery.json as structured JSON with:
{
  \"docs\": [
    {
      \"path\": \"docs/api.md\",
      \"type\": \"api\",
      \"describes\": [\"src/Controller/UserController.php\"],
      \"last_modified\": \"2025-12-01\",
      \"status\": \"outdated|current|missing|drift\"
    }
  ],
  \"gaps\": [
    {
      \"source_file\": \"src/Service/ExportService.php\",
      \"description\": \"No documentation for export functionality\"
    }
  ],
  \"drift\": [
    {
      \"doc_path\": \"README.md\",
      \"section\": \"API Endpoints\",
      \"issue\": \"Lists /api/users/list but code uses /api/users\"
    }
  ]
}

Mark your task as completed when done. If task tools are unavailable to you, the saved discovery.json file signals completion."
)
```

**Team mode**: Monitor T1 completion via TaskList. If the teammate has finished but T1 never shows completed (context-builder may not have task tools available), check for `{work_dir}/context/discovery.json` — if it exists, treat the work as done and mark T1 completed via TaskUpdate yourself.
**Sub-agent mode**: Wait for Task result.

---

### Phase 3: Analysis

**Goal**: Categorize and prioritize documentation updates, then get user approval.

#### 3.1 Run Business Analyst

Once discovery is complete, run business-analyst to analyze findings.

**Team mode** — Spawn as teammate with `team_name` and `name` parameters.
**Sub-agent mode** — Run as independent Task (no `team_name`/`name`).

```
Task(
  subagent_type="business-analyst",
  # Team mode only:
  # team_name="doc-update-{timestamp}",
  # name="business-analyst",
  prompt="Analyze documentation inventory and create an update plan.

Read the discovery inventory: {work_dir}/context/discovery.json
Update trigger: {trigger}
Scope: {scope}
Code-confirmed session decisions: {session_context}

Tasks:
1. Categorize each finding: Outdated / Missing / Inaccurate / Drift / Style-only
2. Prioritize: Critical (misleading users) > Important (outdated) > Minor (formatting/style)
3. For each item, specify:
   - File path to update/create
   - What specifically needs changing
   - Source code files to reference
   - Estimated effort (small/medium/large)

Save analysis to {work_dir}/context/analysis.md in this format:

## HIGH PRIORITY (Critical/Misleading)
1. **{file}** - {description}
   Source: {source_files}
   Action: {what to do}

## MEDIUM PRIORITY (Outdated)
1. **{file}** - {description}

## LOW PRIORITY (Style/Minor)
1. **{file}** - {description}

Mark your task as completed when done. If task tools are unavailable to you, the saved analysis.md file signals completion."
)
```

**Team mode**: Monitor T2 completion via TaskList. If the teammate has finished but T2 never shows completed (business-analyst may not have task tools available), check for `{work_dir}/context/analysis.md` — if it exists, treat the work as done and mark T2 completed via TaskUpdate yourself.
**Sub-agent mode**: Wait for Task result.

#### 3.2 Present Plan to User

Read the analysis from `{work_dir}/context/analysis.md` and present to user:

Use AskUserQuestion:
```
question: "Documentation Update Plan:

{formatted_analysis_summary}

Which updates should we apply?"
options:
  - label: "All updates"
    description: "Apply all identified updates (high + medium + low priority)"
  - label: "High + Medium only"
    description: "Skip low-priority style/formatting changes"
  - label: "High priority only"
    description: "Only fix critical/misleading documentation"
  - label: "Cancel"
    description: "Don't make any changes"
```

If user selects "Cancel", clean up team and exit.

Store selected scope as `{update_scope}`.

---

### Phase 4: Documentation Updates

**Goal**: Update all documentation (technical and API) using the doc-writer agent.

#### 4.1 Run Doc Writer

Run doc-writer for all documentation updates (technical, API, architecture).

**Team mode** — Spawn as teammate with `team_name` and `name` parameters.
**Sub-agent mode** — Run as independent Task (no `team_name`/`name`).

```
Task(
  subagent_type="doc-writer",
  # Team mode only:
  # team_name="doc-update-{timestamp}",
  # name="doc-writer",
  prompt="Update all documentation based on the approved plan.

Read the analysis: {work_dir}/context/analysis.md
Update scope: {update_scope} (high/medium/low priorities to apply)

For each approved update:
1. Read the current documentation file
2. Read the corresponding source code
3. Make targeted, minimal updates (not full rewrites)
4. Preserve existing structure and tone
5. Update code examples if they reference changed APIs

For API documentation updates:
1. Read the corresponding controllers/routes/handlers
2. Update endpoint documentation (methods, parameters, responses)
3. Update OpenAPI/Swagger specs if they exist
4. Add documentation for new endpoints
5. Ensure error response catalogs are current

Save a summary of changes to {work_dir}/context/doc-writer-changes.md listing:
- Files updated with brief description of changes
- Files created (if any)

Do not run git or attempt to commit — the lead commits changes after review.

Mark your task as completed when done. If task tools are unavailable to you, the saved summary file signals completion."
)
```

#### 4.2 Monitor Progress

**Team mode**: Monitor doc-writer progress via TaskList until T3 completes. If the teammate has finished but T3 never shows completed (doc-writer may not have task tools available), check for `{work_dir}/context/doc-writer-changes.md` — if it exists, treat the work as done and mark T3 completed via TaskUpdate yourself.
**Sub-agent mode**: Wait for Task result.

---

### Phase 5: Review & Cleanup

**Goal**: Verify consistency across all updated docs, clean up team.

#### 5.1 Review Consistency

Once doc-writer completes (T3 done):

1. Read the change summary:
   - `{work_dir}/context/doc-writer-changes.md`

2. For each updated file, verify:
   - No contradictions between technical docs and API docs
   - Cross-references are correct (links, file paths)
   - Terminology is consistent

3. If inconsistencies are found, fix only trivial mechanical issues directly (broken links, wrong file paths, typos). Route anything substantive — content rewrites, new sections, changed behavior descriptions — back to doc-writer via a follow-up Task: the lead does not author documentation content.

#### 5.2 Cleanup

**If `$DOC_EXEC_MODE` = `"team"`:**

Send shutdown requests to all teammates:

```
SendMessage(type="shutdown_request", recipient="context-builder", content="Work complete")
SendMessage(type="shutdown_request", recipient="business-analyst", content="Work complete")
SendMessage(type="shutdown_request", recipient="doc-writer", content="Work complete")
```

After all teammates shut down:

```
TeamDelete()
```

**If `$DOC_EXEC_MODE` = `"subagent"`:**

No team cleanup needed — sub-agents terminate automatically after returning results.

#### 5.3 Present Summary

```
Documentation Update Complete

Trigger: {trigger}
Scope: {scope}
Team: doc-update-{timestamp} (created and cleaned up)

Updated Files:
  - {file1} — {brief change description}
  - {file2} — {brief change description}
  ...

Created Files:
  - {new_file1} — {purpose}
  ...

Skipped (out of scope):
  - {skipped items if any}

Excluded (discussed this session but not implemented — not documented):
  - {excluded_context items if any}

Review changes: git diff
Commit changes: /commit
```

---

## Error Handling

### Team Creation Fails (team mode only)

Set `DOC_EXEC_MODE = "subagent"` and continue. Agents will run as independent sub-agent tasks instead.

### Teammate Fails

Use AskUserQuestion:
```
question: "Teammate {agent_name} failed: {error_message}. How would you like to proceed?"
options:
  - label: "Retry"
    description: "Respawn this teammate"
  - label: "Skip"
    description: "Continue without this agent's updates"
  - label: "Abort"
    description: "Stop and clean up"
```

**If "Abort"**: Shutdown all teammates, TeamDelete(), exit.

### No Documentation Found

If discovery finds no documentation files:
```
No documentation found in the project.

Would you like to create initial documentation?
- README.md
- Architecture overview
- API documentation
```

### No Updates Needed

If analysis finds all docs are current:
```
Documentation Review Complete

All documentation is up to date. No changes needed.

Reviewed: {count} documentation files
Last updated: {most_recent_date}
```

---

## Quality Checklist

### Phase 1: Setup
- [ ] Scope determined (all, readme, api, path, recent)
- [ ] Trigger identified
- [ ] Git context gathered
- [ ] Work directory created

### Phase 2: Discovery
- [ ] Team created
- [ ] Task graph with correct dependencies
- [ ] Documentation inventory complete
- [ ] Gaps and drift identified

### Phase 3: Analysis
- [ ] Updates categorized and prioritized
- [ ] Plan presented to user
- [ ] User approved scope of updates

### Phase 4: Updates
- [ ] Doc-writer updated all documentation (technical + API)

### Phase 5: Cleanup
- [ ] Consistency verified across updated files
- [ ] All teammates shut down
- [ ] Team deleted
- [ ] Summary presented with file list
