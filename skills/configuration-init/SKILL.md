---
name: configuration-init
model: claude-sonnet-4-6
category: project-setup
description: Initialize project configuration file with interactive wizard. Also supports `validate` and `migrate` modes for existing installs.
argument-hint: "[validate | migrate]"
userInvocable: true
allowed-tools: Read, Write, Bash, AskUserQuestion
---

# Configuration Init

Initialize `.claude/configuration.yml` for the current project using an interactive wizard. Also supports:
- `/configuration-init validate` — check an existing config for errors and warnings.
- `/configuration-init migrate` — detect and rewrite legacy configuration and state file formats in place (with backups).

## Purpose

Set up project-specific configuration that skills and agents use for storage locations, artifact paths, and behavior flags.

## When to Use

- Setting up a new project for use with Claude Code skills
- Adding a shared team-knowledge repository for requirements, proposals, and product docs
- After running `install.sh` to install skills globally

## Process

### Step 0: Check Arguments

If `$ARGUMENTS` contains "validate":
1. Find existing config (same directory walk as Step 1)
2. If config found → jump directly to **Step 9: Validate Configuration**
3. If no config found → error: "No configuration file found to validate. Run `/configuration-init` to create one."

If `$ARGUMENTS` contains "migrate":
1. Jump directly to **Step 10: Migrate Legacy Formats**. No interactive wizard is run.

### Step 1: Check Existing Configuration

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
EXISTING_CONFIG="$CONFIG"
# New configurations are always written to CWD
WRITE_CONFIG=".claude/configuration.yml"
```

If `$EXISTING_CONFIG` is found (in current or parent directory), read it and show current state:

```
Configuration already exists: .claude/configuration.yml

Current configuration:
  execution_mode: subagent
  storage.locations: local, team-repo (if configured)
  storage.artifacts: work, brainstorms, proposals, requirements, product-knowledge, refactoring
```

Use AskUserQuestion:
- header: "Action"
- question: "Configuration already exists. What would you like to do?"
- options:
  - "Validate" / "Check the current configuration for errors and warnings"
  - "Reconfigure" / "Start fresh and overwrite the current configuration"
  - "Cancel" / "Keep the current configuration"
- multiSelect: false

If user selects "Cancel", stop with: "Configuration unchanged."

If user selects "Validate", jump to **Step 9: Validate Configuration**.

### Step 2: Load Template

Read the template from `~/.claude/templates/configuration.yml`.

**If template not found:**

```
Template not found at ~/.claude/templates/configuration.yml

Run install.sh first to install templates:
  cd /path/to/claude-skills && ./install.sh

Or install templates only:
  cd /path/to/claude-skills && ./install.sh
  Select option: 8) Templates only
```

Stop execution.

### Step 3: Ask About Execution Mode

Use AskUserQuestion:

- header: "Execution"
- question: "How should multi-agent skills execute? (e.g., /create-requirements deep-dive phase)"
- options:
  - "Sub-agent (Recommended)" / "Agents run as independent parallel tasks. Lower token cost, good for most work."
  - "Team" / "Agents run as teammates that can read each other's findings. Higher token cost, better for complex multi-system features."
  - "Per-phase" / "Choose team vs sub-agent for each workflow phase independently. Best cost-quality balance."
- multiSelect: false

**If "Sub-agent" or "Team" selected:**

Store the selected mode as a simple string: `"subagent"` or `"team"`.

**If "Per-phase" selected:**

Use AskUserQuestion:

- header: "Default Mode"
- question: "What should the default execution mode be? (used for phases without a specific override)"
- options:
  - "Sub-agent (Recommended)" / "Default to independent parallel tasks"
  - "Team" / "Default to teammate mode with cross-pollination"
- multiSelect: false

Then use AskUserQuestion:

- header: "Phase Overrides"
- question: "Which phases should use team mode? (team mode enables agents to read each other's findings)"
- options:
  - "Requirements Deep Dive" / "requirements_deep_dive — parallel research agents in /create-requirements"
  - "QA Review" / "qa_review — test-writer, code-reviewer, security-auditor in /implement"
  - "Documentation Update" / "documentation_update — context-builder, business-analyst, doc-writer in /update-documentation"
  - "Refactor" / "refactor — code-reviewer, test-writer, quality-guard in /refactor"
  - "Troubleshoot" / "troubleshoot — security-auditor, quality-guard in /troubleshoot"
  - "PR Review" / "pr_review — code-reviewer, security-auditor, quality-guard in /pr-review (covers remote and `--local` modes)"
- multiSelect: true

Store the result as an object:
```yaml
execution_mode:
  default: subagent   # or team
  overrides:
    requirements_deep_dive: team   # only if selected
    qa_review: team                # only if selected
```

Only include overrides that differ from the default. If no overrides differ, simplify back to the string format.

### Step 4: Ask About Shared Team Repository

Use AskUserQuestion to ask about a shared git repository for team artifacts.

- header: "Team Repository"
- question: "Do you want to configure a shared git repository for team artifacts (requirements, proposals, product docs)?"
- options:
  - "Yes" / "I have a shared git repo for team-wide knowledge and artifacts"
  - "No" / "Keep everything local to this project (can add later)"
- multiSelect: false

#### If "No" selected — ask about local storage path:

Use AskUserQuestion:

- header: "Local Path"
- question: "What path should be used for local artifact storage?"
- options:
  - ".claude (Recommended)" / "Default location — artifacts stored in .claude/ within your project"
  - ".claude-data" / "Alternative location — keeps .claude/ for config only"
- multiSelect: false

The user can type a custom path via the built-in "Other" option. Store the selected value as `LOCAL_PATH` (e.g., `.claude`, `.claude-data`, or a custom value). Then skip to Step 6.

### Step 5: Collect Repository Details

#### If "Yes" selected:

First, resolve the parent directory of the current working directory at runtime:

```bash
PARENT_DIR=$(dirname "$PWD")
```

For example, if cwd is `/home/user/code/my-project`, then `PARENT_DIR=/home/user/code`.

Use AskUserQuestion:
- header: "Repository Path"
- question: "What is the absolute path to your shared team-knowledge git repository?"
- options:
  - "${PARENT_DIR}/team-knowledge" / "Sibling directory to current project (default convention)"
  - "Create new" / "I don't have one yet — show me how to create it"
- multiSelect: false

The user can type a custom path via the built-in "Other" option.

**If "Create new" selected:**

Show setup instructions and stop the repository section:

```
To create a team-knowledge repository:

  mkdir team-knowledge
  cd team-knowledge
  git init
  mkdir requirements proposals
  cp -r ~/.claude/templates/requirements-repo/* requirements/  # If templates installed
  git add . && git commit -m "Initial setup"

Then re-run /configuration-init to connect it.

See: docs/workflows/requirements-knowledge-base.md
```

**If user selects the default path or enters a custom path via "Other"**, validate it exists:

```bash
if [[ -d "$USER_PATH" ]]; then
  echo "Found: $USER_PATH"
  if [[ -d "$USER_PATH/.git" ]]; then
    echo "Git repository detected."
  else
    echo "Warning: Not a git repository. Sync will not be available."
  fi
else
  echo "Warning: Directory not found: $USER_PATH"
  echo "The path will be saved but the integration won't work until the directory exists."
fi
```

Determine the location type: `git` if `.git/` exists, otherwise `directory`.

#### Ask about local storage path (if team repo configured):

Use AskUserQuestion:

- header: "Local Path"
- question: "What path should be used for local artifact storage?"
- options:
  - ".claude (Recommended)" / "Default location — artifacts stored in .claude/ within your project"
  - ".claude-data" / "Alternative location — keeps .claude/ for config only"
- multiSelect: false

The user can type a custom path via the built-in "Other" option. Store the selected value as `LOCAL_PATH`.

#### Ask about requirements behavior flags (if team repo configured):

Use AskUserQuestion:
- header: "Requirements Behavior"
- question: "Configure requirements behavior? (defaults are recommended for most projects)"
- options:
  - "Use defaults" / "auto_search: true, auto_archive: true, auto_load_threshold: 0.9, max_suggestions: 3, archive_on_pr: true"
  - "Customize" / "I want to change the default values"
- multiSelect: false

If "Customize", ask about each flag individually. If "Use defaults", use:
- `auto_archive`: true
- `auto_search`: true
- `auto_load_threshold`: 0.9
- `max_suggestions`: 3
- `archive_on_pr`: true

### Step 6: Build Configuration

If `LOCAL_PATH` was not set (e.g., user selected "Create new" in Step 5 and execution stopped), default it:

```bash
LOCAL_PATH="${LOCAL_PATH:-.claude}"
```

Build the YAML configuration using the `LOCAL_PATH` value. The `storage` section always includes a `local` location and default artifact mappings. If the user configured a team repo, add a `team-repo` location and map shared artifacts to it.

**Base config (always included):**

```yaml
# Simple format (string):
execution_mode: subagent  # or team

# Per-phase format (if selected in Step 3):
# execution_mode:
#   default: subagent
#   overrides:
#     requirements_deep_dive: team
#     qa_review: team

storage:
  locations:
    local:
      type: directory
      path: ${LOCAL_PATH}    # e.g., .claude, .claude-data, or custom
  artifacts:
    work:
      location: local
      subdir: work
    brainstorms:
      location: local
      subdir: brainstorm
    proposals:
      location: local
      subdir: proposals
    refactoring:
      location: local
      subdir: work/refactoring-sessions
    requirements:
      location: local
      subdir: requirements
    product-knowledge:
      location: local
      subdir: .
```

**If team repo configured** — override shared artifacts to point to the team repo:

```yaml
storage:
  locations:
    local:
      type: directory
      path: ${LOCAL_PATH}    # e.g., .claude, .claude-data, or custom
    team-repo:
      type: git       # or directory
      path: /absolute/path/to/team-knowledge
  artifacts:
    # ... local artifacts as above, except override shared ones ...
    requirements:
      location: team-repo
      subdir: requirements
    proposals:
      location: team-repo
      subdir: proposals
    product-knowledge:
      location: team-repo
      subdir: .
```

**Add requirements behavior flags:**

```yaml
requirements:
  auto_archive: true
  auto_search: true
  auto_load_threshold: 0.9
  max_suggestions: 3
  archive_on_pr: true
```

### Step 7: Write Configuration and Create Directories

```bash
mkdir -p .claude
```

Write the built YAML to `.claude/configuration.yml` using the Write tool.

Then create all artifact directories using `LOCAL_PATH` so skills don't encounter missing paths:

```bash
mkdir -p ${LOCAL_PATH}/work
mkdir -p ${LOCAL_PATH}/brainstorm
mkdir -p ${LOCAL_PATH}/proposals
mkdir -p ${LOCAL_PATH}/work/refactoring-sessions
mkdir -p ${LOCAL_PATH}/requirements
```

If `LOCAL_PATH` differs from `.claude`, also ensure `.claude/` exists (the configuration file itself always lives at `.claude/configuration.yml`).

If team repo is configured, skip creating directories for artifacts that point to the team repo (those directories should already exist in the repo).

### Step 8: Show Summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Configuration Created
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

File: .claude/configuration.yml

EXECUTION MODE
────────────────────────────────────────────────
  default:              ${default_mode} (subagent|team)
  requirements_deep_dive: ${override_or_default}
  qa_review:            ${override_or_default}

STORAGE LOCATIONS
────────────────────────────────────────────────
  local:                ${LOCAL_PATH} (directory)
  team-repo:            ${path} (${type})   # if configured

ARTIFACTS
────────────────────────────────────────────────
  work:                 local → ${LOCAL_PATH}/work
  brainstorms:          local → ${LOCAL_PATH}/brainstorm
  proposals:            ${location} → ${resolved_path}
  refactoring:          local → ${LOCAL_PATH}/work/refactoring-sessions
  requirements:         ${location} → ${resolved_path}
  product-knowledge:    ${location} → ${resolved_path}

REQUIREMENTS BEHAVIOR
────────────────────────────────────────────────
  auto_search:          ${value}
  auto_archive:         ${value}
  auto_load_threshold:  ${value}
  max_suggestions:      ${value}
  archive_on_pr:        ${value}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Skills and agents will now use this configuration.

To modify later, edit .claude/configuration.yml directly
or re-run /configuration-init.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 9: Validate Configuration

**Triggered by:** "Validate" option in Step 1, or `$ARGUMENTS` containing "validate".

Read `$EXISTING_CONFIG` and run validation checks. Report results using pass/warn/fail format.

**Validation checks:**

```
1. YAML Syntax
   → Parse the file. If invalid YAML → FAIL with parse error location.

2. execution_mode
   → If string: must be "subagent" or "team" → else FAIL
   → If object: must have "default" key with value "subagent" or "team"
   → If object with "overrides": each key must be a known phase name
     Known phases: requirements_deep_dive, qa_review, documentation_update, refactor, troubleshoot, pr_review
     Unknown phase name → WARN ("unknown phase: {name}, will be ignored by skills")

3. storage.locations
   → Each location must have "type" and "path"
   → "type" must be "git" or "directory" → else FAIL
   → "path": check if directory exists → if not, WARN ("path does not exist: {path}")
   → If type is "git": check if path contains .git/ → if not, WARN ("not a git repository: {path}")

4. storage.artifacts
   → Each artifact must have "location" and "subdir"
   → "location" must reference a key defined in storage.locations → else FAIL ("artifact '{name}' references undefined location '{loc}'")
   → Known artifact names: work, brainstorms, proposals, refactoring, requirements, product-knowledge
   → Unknown artifact name → WARN ("unknown artifact: {name}")

5. requirements section (if present)
   → auto_archive: must be boolean → else WARN
   → auto_search: must be boolean → else WARN
   → auto_load_threshold: must be number between 0 and 1 → else WARN
   → max_suggestions: must be positive integer → else WARN
   → archive_on_pr: must be boolean → else WARN
```

**Output format:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Configuration Validation: {config_path}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  [PASS] YAML syntax valid
  [PASS] execution_mode: "subagent"
  [PASS] storage.locations.local: type=directory, path=.claude (exists)
  [WARN] storage.locations.team-repo: path /home/user/code/team-knowledge does not exist
  [PASS] storage.artifacts: all 6 artifacts reference valid locations
  [FAIL] storage.artifacts.proposals: references undefined location "shared"
  [PASS] requirements: all values valid

  Result: 5 passed, 1 warning, 1 failure

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If any FAIL results exist, suggest fixes. If only WARN or PASS, report "Configuration is valid."

---

### Step 10: Migrate Legacy Formats

**Triggered by:** `$ARGUMENTS` containing "migrate".

Scan the project for legacy configuration and state file formats left over from past breaking changes and rewrite them in place. All rewrites create a `.bak-YYYYMMDD-HHMMSS` copy beside the original so nothing is destroyed.

**Three migrations are checked:**

1. `configuration.json` → `configuration.yml` (JSON to YAML)
2. `*-state.json` (per-skill state files) → unified `state.json` with `type` field
3. `domain_knowledge` configuration key → `product_knowledge`

#### 10.1 Plan phase (dry run — no writes)

```bash
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
PROJECT_ROOT=$(pwd)
PLAN=()

# 1. configuration.json → configuration.yml
if [[ -f ".claude/configuration.json" && ! -f ".claude/configuration.yml" ]]; then
  PLAN+=("config-json-to-yml:.claude/configuration.json")
fi

# 2. Per-skill state files → state.json
LEGACY_STATE_NAMES=(
  "brainstorm-state.json:brainstorm"
  "requirements-state.json:requirements"
  "proposal-state.json:proposal"
  "implementation-state.json:implementation"
  "epic-state.json:epic"
)

WORK_DIR=$(resolve_artifact work work 2>/dev/null || echo ".claude/work")
for dir in "$WORK_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  for pair in "${LEGACY_STATE_NAMES[@]}"; do
    old_name="${pair%:*}"
    type_field="${pair#*:}"
    if [[ -f "${dir}${old_name}" && ! -f "${dir}state.json" ]]; then
      PLAN+=("state-rename:${dir}${old_name}:${type_field}")
    fi
  done
done

# 3. domain_knowledge key in configuration.yml
if [[ -f ".claude/configuration.yml" ]] && grep -q '^[[:space:]]*domain_knowledge:' ".claude/configuration.yml"; then
  PLAN+=("rename-key:.claude/configuration.yml:domain_knowledge:product_knowledge")
fi
```

**Report the plan to the user:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Migration Plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Legacy config file  .claude/configuration.json → .claude/configuration.yml
  Legacy state file   .claude/work/JIRA-123/requirements-state.json → state.json (type: requirements)
  Legacy config key   .claude/configuration.yml: domain_knowledge → product_knowledge

  Backups will be written as *.bak-${TIMESTAMP}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If `PLAN` is empty, report:

```
✓ No legacy formats detected. Nothing to migrate.
```

…and exit.

Use `AskUserQuestion`:
- header: "Apply migration?"
- question: "Apply the planned migrations? Each original file is backed up before rewrite."
- options:
  - "Apply" / "Run the migrations"
  - "Cancel" / "Exit without changes"

If "Cancel" → stop with: "Migration cancelled. No files were modified."

#### 10.2 Apply phase

For each planned action, create the backup, then rewrite:

**config-json-to-yml** (uses `yq` to convert JSON to YAML):
```bash
cp ".claude/configuration.json" ".claude/configuration.json.bak-${TIMESTAMP}"
yq -P '.' ".claude/configuration.json" > ".claude/configuration.yml"
# Only remove original after successful YAML write
if [[ -s ".claude/configuration.yml" ]]; then
  rm ".claude/configuration.json"
fi
```

**state-rename** (add `type` field, rename file):
```bash
if [[ -s "${dir}state.json" ]]; then
  echo "⚠ Skipping ${old_path} — ${dir}state.json already written by an earlier migration in this directory."
  continue
fi
cp "${old_path}" "${old_path}.bak-${TIMESTAMP}"
jq --arg t "${type_field}" '. + {type: $t}' "${old_path}" > "${dir}state.json"
if [[ -s "${dir}state.json" ]]; then
  rm "${old_path}"
fi
```

**rename-key** (update a top-level YAML key, preserve structure):
```bash
cp "${file}" "${file}.bak-${TIMESTAMP}"
yq -i '.product_knowledge = .domain_knowledge | del(.domain_knowledge)' "${file}"
```

After each action, print a single line confirmation:

```
✓ .claude/configuration.json → .claude/configuration.yml  (backup: .bak-20260423-160500)
✓ .claude/work/JIRA-123/requirements-state.json → state.json  (backup: .bak-20260423-160500)
✓ .claude/configuration.yml: domain_knowledge → product_knowledge  (backup: .bak-20260423-160500)
```

If any step fails, stop and report which action failed. The user can retry after resolving the issue.

#### 10.3 Summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Migration Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Actions applied: {count}
  Backups created: {count}

  Next step: run /configuration-init validate to confirm the
  rewritten configuration passes validation.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Scope note:** This migration only handles known-historical format changes. Unknown legacy formats are left untouched — the user can file an issue if they encounter a case this skill misses.

---

## Examples

### Example 1: Minimal Setup (No Team Repo)

```bash
/configuration-init

# → Select execution mode: Sub-agent
# → Select: No team repository
# → Select local path: .claude (Recommended)
# → Writes local-only configuration.yml with path: .claude
```

### Example 2: Full Setup with Team Repo

```bash
/configuration-init

# → Select execution mode: Sub-agent
# → Select: Yes, configure team repository
# → Select repo path: /home/user/code/team-knowledge (default)
# → Select local path: .claude (Recommended)
# → Use default requirements behavior
# → Writes configuration.yml with team-repo location and shared artifacts
```

### Example 3: Custom Local Path

```bash
/configuration-init

# → Select execution mode: Sub-agent
# → Select: No team repository
# → Select local path: Other → type ".data"
# → Writes configuration.yml with path: .data
```

### Example 4: Validate Existing

```bash
/configuration-init

# → Shows current config
# → Select: Validate
# → Runs all checks, reports pass/warn/fail
# → Shows "Configuration is valid" or suggests fixes
```

### Example 5: Migrate Legacy Formats

```bash
/configuration-init migrate

# → Scans for legacy configuration.json, *-state.json, domain_knowledge key
# → Prints plan; no writes yet
# → Asks for confirmation (Apply / Cancel)
# → On Apply: creates .bak-TIMESTAMP copies, rewrites in place
# → Reports which migrations landed; suggests running validate next
```

### Example 6: Reconfigure Existing

```bash
/configuration-init

# → Shows current config
# → Select: Reconfigure
# → Walks through wizard again
# → Overwrites with new configuration
```
