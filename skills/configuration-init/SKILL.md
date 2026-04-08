---
name: configuration-init
model: sonnet
category: project-setup
description: Initialize project configuration file with interactive wizard
userInvocable: true
allowed-tools: Read, Write, Bash, AskUserQuestion
---

# Configuration Init

Initialize `.claude/configuration.yml` for the current project using an interactive wizard.

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

### Step 1: Check Existing Configuration

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
  - "Local PR Review" / "local_pr_review — code-reviewer, security-auditor, quality-guard in /local-pr-review"
  - "PR Review" / "pr_review — code-reviewer, security-auditor, quality-guard in /pr-review"
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
     Known phases: requirements_deep_dive, qa_review, documentation_update, refactor, troubleshoot, local_pr_review, pr_review
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

### Example 5: Reconfigure Existing

```bash
/configuration-init

# → Shows current config
# → Select: Reconfigure
# → Walks through wizard again
# → Overwrites with new configuration
```
