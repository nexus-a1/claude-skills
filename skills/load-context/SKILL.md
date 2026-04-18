---
name: load-context
category: implementation
model: claude-sonnet-4-6
userInvocable: true
description: Load all available context for a ticket or topic — work state, brainstorms, proposals, requirements KB, product knowledge, and git history — into a single unified summary.
argument-hint: "<identifier-or-query>"
allowed-tools: "Read, Write, Glob, Grep, Bash(git:*), Task, AskUserQuestion"
---

# Context Aggregator

Arguments: $ARGUMENTS

Aggregate everything the system knows about a topic from all storage sources into a single unified summary.

## Usage

```bash
/load-context <slug-or-query>    # Aggregate context for a specific topic
/load-context                    # List available context across all sources
```

## When to Use

- Starting a conversation and want to load everything known about a topic
- Before resuming work — understand what exists before deciding next steps
- Exploring what past work is available across all sources
- Building understanding of a topic without modifying anything

**This is primarily a read-only skill.** Phase 3 (Create Context) can optionally write notes and update manifests when the user opts in.

---

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults.

### Resolve All 6 Artifact Paths

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
IFS='|' read -r WORK_DIR WORK_TYPE         <<< "$(resolve_artifact_typed work work)"
IFS='|' read -r BRAINSTORM_DIR BRAIN_TYPE  <<< "$(resolve_artifact_typed brainstorms brainstorm)"
IFS='|' read -r PROPOSALS_DIR PROP_TYPE    <<< "$(resolve_artifact_typed proposals proposals)"
IFS='|' read -r REFACTOR_DIR REFAC_TYPE    <<< "$(resolve_artifact_typed refactoring work/refactoring-sessions)"
IFS='|' read -r REQUIREMENTS_DIR REQ_TYPE  <<< "$(resolve_artifact_typed requirements requirements)"
IFS='|' read -r PRODUCT_DIR PROD_TYPE      <<< "$(resolve_artifact_typed product-knowledge .)"
```

For any location with `type: git`, sync before reading:

```bash
for _var_pair in "WORK_DIR:WORK_TYPE" "BRAINSTORM_DIR:BRAIN_TYPE" "PROPOSALS_DIR:PROP_TYPE" \
                 "REFACTOR_DIR:REFAC_TYPE" "REQUIREMENTS_DIR:REQ_TYPE" "PRODUCT_DIR:PROD_TYPE"; do
  _dir_var="${_var_pair%%:*}"; _type_var="${_var_pair##*:}"
  if [[ "${!_type_var}" == "git" ]]; then
    _base="$(dirname "${!_dir_var}")"
    cd "$_base" && git pull --quiet 2>/dev/null
  fi
done
```

---

## Workflow: `/load-context <slug>`

When a slug/query argument is provided, search all sources for matches.

### Phase 1: Exact Match (Fast, Manifest-First)

**Prefer manifests over directory scans.** For each artifact type, check if `manifest.json` exists and search it first. Fall back to directory existence check only if manifest is missing.

```bash
# For each artifact type, try manifest first, then directory:
# Work:
if [[ -f "${WORK_DIR}/manifest.json" ]]; then
  # Search items array for matching identifier
  jq -e ".items[] | select(.identifier == \"${slug}\")" "${WORK_DIR}/manifest.json"
else
  [[ -d "${WORK_DIR}/${slug}" ]]
fi

# Brainstorms (stored in WORK_DIR since brainstorm writes to work dir):
# Brainstorm sessions have type="brainstorm" in the work manifest.
# Also check legacy BRAINSTORM_DIR for sessions created before this change.
if [[ -f "${WORK_DIR}/manifest.json" ]]; then
  jq -e ".items[] | select(.identifier == \"${slug}\" and .type == \"brainstorm\")" "${WORK_DIR}/manifest.json"
elif [[ -d "${WORK_DIR}/${slug}" ]] && [[ -f "${WORK_DIR}/${slug}/state.json" ]]; then
  echo "found"
elif [[ -f "${BRAINSTORM_DIR}/manifest.json" ]]; then
  jq -e ".items[] | select(.slug == \"${slug}\")" "${BRAINSTORM_DIR}/manifest.json"
else
  [[ -d "${BRAINSTORM_DIR}/${slug}" ]]
fi

# Proposals:
if [[ -f "${PROPOSALS_DIR}/manifest.json" ]]; then
  jq -e ".items[] | select(.name == \"${slug}\")" "${PROPOSALS_DIR}/manifest.json"
else
  [[ -d "${PROPOSALS_DIR}/${slug}" ]]
fi

# Refactoring:
if [[ -f "${REFACTOR_DIR}/manifest.json" ]]; then
  jq -e ".items[] | select(.session_name == \"${slug}\")" "${REFACTOR_DIR}/manifest.json"
else
  [[ -d "${REFACTOR_DIR}/${slug}" ]]
fi

# Git: check for branches matching slug
git branch -a --list "*${slug}*"
```

**Manifest advantage:** When a manifest match is found, you already have the item's metadata (status, title, progress, etc.) without reading individual state files.

For each match found, read and summarize the contents:

#### Work State
If `${WORK_DIR}/${slug}/` exists:
- Read `state.json` (check `type` field to understand session kind)
- Read agent outputs from `context/` subdirectory. **Prefer distilled `-summary.md` variants over their full counterparts** (e.g., `qa-code-reviewer-summary.md` over `qa-code-reviewer.md`, `archaeologist-summary.md` over `archaeologist.md`). Fall back to the full file only if the summary is absent. Summaries are ≤10 lines each; the full file is available via explicit `Read()` when deeper context is needed.
- Summarize: identifier, current phase, status, last updated, key files
- **If `state.json` has a non-empty `updates` array:** surface all entries as a **Session Updates** section (timestamp + note, newest last). Entries with `"auto": true` are from the `auto-context.sh` hook — prefix their display with `[auto]` to distinguish from manually recorded `/update-context` annotations.
- **If `state.json` has `brainstorm.promoted_from`:** also load the linked brainstorm as prior art:
  - Read `$WORK_DIR/{promoted_from}/state.json`
  - Read `$WORK_DIR/{promoted_from}/context/approaches.md`, `context/exploration.md`, `implementation-picture.md` (if exist)
  - Surface as "Prior art: Brainstorm '{promoted_from}'" section in context output

#### Brainstorms
If `${WORK_DIR}/${slug}/` exists and contains `state.json`:
- Read `state.json` for status, selected approach, phase completion
- Read `context/approaches.md`, `context/exploration.md`, `context/architecture-validation.md` (if exist)
- Read `implementation-picture.md`, `work-breakdown.md` (if exist)
- Summarize: selected approach, alternatives considered, key decisions, completion status

Legacy: If `${BRAINSTORM_DIR}/${slug}/` exists (pre-migration sessions):
- Read all `.md` files in the directory
- Summarize: selected approach, alternatives considered, key decisions

#### Proposals
If `${PROPOSALS_DIR}/${slug}/` exists:
- Read proposal files (`.md`)
- Summarize: proposal status, key points, iterations

If `${PROPOSALS_DIR}/${slug}` is a file (not directory):
- Read the file directly
- Summarize: proposal content

#### Refactoring Sessions
If `${REFACTOR_DIR}/${slug}/` exists:
- Read session state files
- Summarize: refactoring scope, progress, files affected

#### Git History
For any branches matching `*${slug}*`:
- List matching branch names
- Show recent commits on those branches (last 5 per branch):
  ```bash
  git log --oneline -5 "${branch}"
  ```

### Phase 2: Fuzzy Fallback

If Phase 1 found **no exact matches**, run a broader search:

#### 2.1 Local Sources (Direct)

Search all local artifact directories in parallel:

```bash
# Glob for partial directory name matches
# In WORK_DIR, BRAINSTORM_DIR, PROPOSALS_DIR, REFACTOR_DIR:
# Look for directories containing the slug as substring

# Grep for slug in file contents across all sources
# Search .json and .md files for the query string
```

Use Glob and Grep tools to search each resolved path for:
- Directory names containing the slug
- File contents mentioning the slug

#### 2.2 Requirements KB (Agent)

**Only if requirements artifact is configured** (i.e., the resolved path exists and is not just the default empty local path):

```
Task(archivist, "Search requirements repository for: ${slug}

Configuration:
  Path: ${REQUIREMENTS_DIR}
  Type: ${REQ_TYPE}

Search for keyword matches. Return top 3 results with:
- ID, title, relevance score
- Brief summary
- Tags and components
")
```

#### 2.3 Product Knowledge (Agent)

**Only if product-knowledge artifact is configured** (i.e., the resolved path exists and is not just the default empty local path):

```
Task(product-expert, "Search product knowledge base for: ${slug}

Configuration:
  Path: ${PRODUCT_DIR}
  Type: ${PROD_TYPE}

Find related product documentation. Return:
- Document titles and paths
- Relevant excerpts
- How they relate to the query
")
```

**Run 2.2 and 2.3 in parallel** (single message with multiple Task calls).

#### 2.4 Git Log Search

```bash
git log --all --oneline --grep="${slug}" -10
```

### Phase 3: Create Context (when nothing found)

If all phases return no matches for the slug AND the user's phrasing implies creation intent (e.g., "create context for X", "build context for X"):

1. Inform: "No existing context found for `{slug}`."
2. Ask via AskUserQuestion: "Would you like me to research the codebase and create a new context artifact?"
   - Options: "Yes, research and create" / "No, just searching"
3. If yes:
   - Launch Explore agent for comprehensive codebase research on `{slug}`
   - Launch archivist (if configured) and product-expert (if configured) in parallel
   - Aggregate findings into `${WORK_DIR}/{slug}/notes.md`
   - Update manifest
   - **Do NOT `git add` or `git commit` the created files.** In multi-repo workspaces (`WORKSPACE_MODE="multi"`), the `_storage/` directory is at the workspace root which has no `.git`. Even in single-repo mode, leave committing to the user or a subsequent skill.
   - Report: "Context created and saved to `${WORK_DIR}/{slug}/notes.md`"

### Compile Results

After phases complete, compile all findings into the output format.

### Phase 4: Handoff

After compiling results, if a `state.json` was found for the slug, offer to continue working.

**Determine handoff options:**

```bash
STATE_FILE="${WORK_DIR}/${slug}/state.json"
if [[ -f "$STATE_FILE" ]]; then
  WORK_TYPE=$(jq -r '.type // "unknown"' "$STATE_FILE")
  WORK_STATUS=$(jq -r '.status // "unknown"' "$STATE_FILE")
fi
```

If no `state.json` exists for this slug, skip Phase 4 — no handoff offered.

Build the option list based on `type` and `status`. Always append "No, just reviewing" as the last option.

| `type` | `status` | Options to offer |
|--------|----------|-----------------|
| `implementation` | `in_progress` | "Resume implementation" → `/resume-work {slug}` |
| `implementation` | `completed` | "Extend implementation" → `/resume-work {slug}` |
| `requirements` | `in_progress` | "Resume requirements" → `/resume-work {slug}` |
| `requirements` | `completed` | "Start implementing" → `/implement {slug}`, "Extend requirements" → `/resume-work {slug}` |
| `brainstorm` | `in_progress` | "Resume brainstorm" → `/resume-work {slug}` |
| `brainstorm` | `completed` | "Create requirements from brainstorm" → `/resume-work {slug}` |
| `proposal` | any | "Resume proposal" → `/resume-work {slug}` |
| `epic` | any | "Resume epic" → `/resume-work {slug}` |

**Ask via AskUserQuestion:**

```
header: "Start working"
question: "Ready to start working on {slug}?"
options: [{options from table above}, "No, just reviewing"]
```

If user selects a work option, invoke the target skill with the slug as the argument:
- `/resume-work {slug}` → execute the resume-work skill passing `{slug}` as `$ARGUMENTS`
- `/implement {slug}` → execute the implement skill passing `{slug}` as `$ARGUMENTS`

---

## Workflow: `/load-context` (No Argument)

When invoked without arguments, list what context is available across all sources.

### Step 1: Scan All Sources (Manifest-First)

**Prefer manifests over directory scans.** For each artifact type, check if `manifest.json` exists using the Read tool. If it exists, parse it for structured data. If no manifest is found, fall back to the Glob tool to list directory contents.

**If manifest exists** — use Read to load it, then extract items:

| Artifact | Manifest Path | Fields |
|----------|--------------|--------|
| Work | `${WORK_DIR}/manifest.json` | `.items[] \| .identifier, .title, .status, .type` |
| Brainstorms | `${BRAINSTORM_DIR}/manifest.json` | `.items[] \| .slug, .title, .selected_approach` |
| Proposals | `${PROPOSALS_DIR}/manifest.json` | `.items[] \| .name, .title, .status` |
| Refactoring | `${REFACTOR_DIR}/manifest.json` | `.items[] \| .session_name, .title, .status` |

**If no manifest** — use Glob to list directory contents:

| Artifact | Glob call |
|----------|-----------|
| Work | `Glob("*", path="${WORK_DIR}/")` |
| Brainstorms | `Glob("*", path="${BRAINSTORM_DIR}/")` |
| Proposals | `Glob("*", path="${PROPOSALS_DIR}/")` |
| Refactoring | `Glob("*", path="${REFACTOR_DIR}/")` |

Run all four artifact scans in parallel where possible.

**Manifest advantage:** When manifests are available, the inventory table can include titles and statuses without reading individual state files.

### Step 2: Build Inventory

For each unique slug found across any source, note which sources contain it:

```
Available Context
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Slug               Title                   Work  Brainstorm  Proposal  Refactoring  Status
────────────────────────────────────────────────────────────────────────────────────────────
JIRA-123           User Export Feature       ✓                 ✓                    in_progress
user-auth          User Authentication       ✓       ✓                             completed
sso-integration    SSO with Azure AD                           ✓                    draft
api-refactor       API Controller Cleanup                                 ✓         paused

4 topics found across local sources.

Load details: /load-context <slug>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 3: Offer Selection

Use AskUserQuestion to let the user pick a slug to load:

```
Select a topic to load context for, or enter a search query:
```

Options: list the slugs found, plus an "Other" option for free-text search.

If user selects a slug, proceed with the `/load-context <slug>` workflow above.

---

## Output Format

Present results with sections only for sources that returned content. Omit empty sections entirely.

```
Context: {slug}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Work State
Status: {phase} ({status})
Last updated: {timestamp}
Branch: {feature_branch} → {base_branch}

Key files:
- state.json
- context/discovery.json
- context/archaeologist.md

Summary: {brief description of current state}

## Brainstorm
Selected approach: {approach name}
Alternatives considered: {count}

Key decisions:
- {decision 1}
- {decision 2}

Key files:
- {file list}

## Proposal
Status: {draft|final|implemented}
Iterations: {count}

Key points:
- {point 1}
- {point 2}

Key files:
- {file list}

## Refactoring Session
Scope: {description}
Progress: {status}

Files affected:
- {file list}

## Requirements KB
{Matched requirements from archivist, if any}

## Product Knowledge
{Related product docs from product-expert, if any}

## Git History
Branches:
- feature/{slug} (last commit: {date})

Recent commits:
- {hash} {message} ({date})
- {hash} {message} ({date})

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Handling

### No argument, no local context found

```
No context found across any source.

Available actions:
- /load-context <query>               Search by keyword
- /create-requirements                Start new work
- /brainstorm                         Start brainstorming
```

### Slug not found anywhere

```
No context found for: "{slug}"

Searched:
  Work state:     {WORK_DIR} — not found
  Brainstorms:    {BRAINSTORM_DIR} — not found
  Proposals:      {PROPOSALS_DIR} — not found
  Refactoring:    {REFACTOR_DIR} — not found
  Requirements:   {status: searched/not configured}
  Product KB:     {status: searched/not configured}
  Git history:    No matching branches or commits

Suggestions:
- Try a broader query: /load-context auth (instead of user-authentication)
- Check spelling
- List available context: /load-context
```

### Configuration missing

Not an error — skill works without configuration by falling back to defaults:
- `WORK_DIR` → `.claude/work`
- `BRAINSTORM_DIR` → `.claude/brainstorm`
- `PROPOSALS_DIR` → `.claude/proposals` (note: no default external path)
- `REFACTOR_DIR` → `.claude/work/refactoring-sessions`
- Requirements KB and Product Knowledge → skipped (not configured)

---

## Agent Delegation Summary

| Source | Agent | When |
|--------|-------|------|
| Work state | Direct (Read, Glob) | Always — local file reads |
| Brainstorms | Direct (Read, Glob) | Always — local file reads |
| Proposals | Direct (Read, Glob) | Always — local file reads |
| Refactoring | Direct (Read, Glob) | Always — local file reads |
| Requirements KB | `archivist` | Only during fuzzy search, only if configured |
| Product Knowledge | `product-expert` | Only during fuzzy search, only if configured |
| Git history | Direct (Bash git) | Always — git branch/log commands |

Both agent searches run **in parallel** when triggered.

---

## Examples

### Example 1: Full context for a ticket

```bash
/load-context JIRA-123
```

```
Context: JIRA-123
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Work State
Status: implement (in_progress)
Last updated: 2026-02-09T14:30:00Z
Branch: feature/JIRA-123 → origin/master
Chunks: 2/3 completed

Key files:
- state.json  (type: implementation)
- context/discovery.json
- context/archaeologist.md

Summary: User export feature. Requirements complete,
implementation 2/3 done. Next chunk: Add admin UI button.

## Brainstorm
Selected approach: Queue-based async export
Alternatives considered: 3

Key decisions:
- Use PhpSpreadsheet for Excel generation
- Async processing via queue jobs
- S3 storage with 7-day retention

Key files:
- approach-comparison.md
- selected-approach.md

## Git History
Branches:
- feature/JIRA-123 (last commit: 2h ago)

Recent commits:
- def456 [JIRA-123] feat(export): add export endpoint
- abc123 [JIRA-123] feat(export): create UserExporter service

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Example 2: Search across sources

```bash
/load-context authentication
```

Finds partial matches in work directories, brainstorms, proposals,
and searches requirements KB and product docs for "authentication".

### Example 3: List all available context

```bash
/load-context
```

Lists all slugs found across local sources with which sources
contain data for each one.
