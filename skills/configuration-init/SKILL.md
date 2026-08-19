---
name: configuration-init
model: claude-sonnet-5
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
- After installing the nexus plugin (`/plugin install nexus@claude-skills`), to configure the current project

## Process

### Library Preamble

**Every `bash` block below that calls `resolve_artifact` or an `artifact_*` function must start with these six lines.** Each block runs as a separate shell invocation — functions and variables do not carry over from an earlier block, so sourcing once at the top of the skill would leave every later block calling undefined functions:

```bash
NEXUS_SHARED="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || NEXUS_SHARED="$HOME/.claude/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || { echo "ERROR: nexus plugin not found or out of date — reinstall: /plugin install nexus@claude-skills" >&2; exit 1; }
source "$NEXUS_SHARED/resolve-config.sh"
source "$NEXUS_SHARED/config/artifacts.sh"
TEMPLATE=$(artifact_template_path) || TEMPLATE=""   # empty = degrade, never fail
```

`$TEMPLATE` is empty whenever no template is readable. Every use of it must degrade with an explanatory message rather than failing the run.

### Step 0: Check Arguments

If `$ARGUMENTS` contains "validate":
1. Find existing config (same directory walk as Step 1)
2. If config found → jump directly to **Step 9: Validate Configuration**
3. If no config found → error: "No configuration file found to validate. Run `/configuration-init` to create one."

If `$ARGUMENTS` contains "migrate":
1. Jump directly to **Step 10: Migrate Legacy Formats**. No interactive wizard is run.

### Step 1: Check Existing Configuration

```bash
NEXUS_SHARED="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || NEXUS_SHARED="$HOME/.claude/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || { echo "ERROR: nexus plugin not found or out of date — reinstall: /plugin install nexus@claude-skills" >&2; exit 1; }
source "$NEXUS_SHARED/resolve-config.sh"
source "$NEXUS_SHARED/config/artifacts.sh"
TEMPLATE=$(artifact_template_path) || TEMPLATE=""

EXISTING_CONFIG="$CONFIG"
# New configurations are always written to CWD
WRITE_CONFIG=".claude/configuration.yml"
```

If `$EXISTING_CONFIG` is found (in current or parent directory), read it and show current state. Read the location and artifact names out of the file rather than listing them from memory — a fixed list here would misreport any config that differs from it:

```bash
yq -r '.storage.locations // {} | keys | join(", ")' "$EXISTING_CONFIG"
yq -r '.storage.artifacts // {} | keys | join(", ")' "$EXISTING_CONFIG"
```

```
Configuration already exists: .claude/configuration.yml

Current configuration:
  execution_mode: subagent
  storage.locations: ${locations}
  storage.artifacts: ${artifacts}
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

Read the template, trying in order: `${CLAUDE_PLUGIN_ROOT}/templates/configuration.yml`, then `~/.claude/templates/configuration.yml` (local/dev copies).

**If neither is found:** the template is optional — Step 6 builds the YAML from scratch regardless. Warn and continue:

```
Template not found (searched ${CLAUDE_PLUGIN_ROOT}/templates/configuration.yml and ~/.claude/templates/configuration.yml).
Continuing without a template — the configuration will be built from your answers below.
```

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

There are seven overridable phases but `AskUserQuestion` caps `options` at **4**
(see [Question Sizing](../../shared/principles.md#question-sizing)), so ask in two
passes and take the **union** of both answers. Do not drop any phase.

Then use AskUserQuestion (pass 1 of 2):

- header: "Phase Overrides 1/2"
- question: "Which phases should use team mode? (1 of 2 — team mode enables agents to read each other's findings)"
- options:
  - "Requirements Deep Dive" / "requirements_deep_dive — parallel research agents in /create-requirements"
  - "QA Review" / "qa_review — test-writer, code-reviewer, security-auditor in /implement"
  - "Documentation Update" / "documentation_update — context-builder, business-analyst, doc-writer in /update-documentation"
  - "Refactor" / "refactor — code-reviewer, test-writer, quality-guard in /refactor"
- multiSelect: true

Then use AskUserQuestion (pass 2 of 2):

- header: "Phase Overrides 2/2"
- question: "And which of these remaining phases should use team mode? (2 of 2 — select none if you are done)"
- options:
  - "Troubleshoot" / "troubleshoot — security-auditor, quality-guard in /troubleshoot"
  - "PR Review" / "pr_review — code-reviewer, security-auditor, quality-guard in /pr-review (covers remote and `--local` modes)"
  - "Review Plan" / "review_plan — architect, quality-guard, optionally security-auditor in /review-plan"
- multiSelect: true

The set of phases to override is every phase selected in **either** pass. An empty
selection in pass 2 is a valid answer, not a reason to re-ask.

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
  cp -r ${CLAUDE_PLUGIN_ROOT}/templates/requirements-repo/* requirements/  # or ~/.claude/templates/requirements-repo/ for local/dev copies; skip if templates not present
  git add . && git commit -m "Initial setup"

Then re-run /configuration-init to connect it.

See: ${CLAUDE_PLUGIN_ROOT}/templates/requirements-repo/README.md (or ~/.claude/templates/requirements-repo/README.md for local/dev copies)
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

Set `TEAM_LOCATION=team-knowledge` — this is the key name Step 6 will write, and the name the template and `plugin/CLAUDE.md` already use. Leave `TEAM_LOCATION` unset for a solo setup.

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

### Step 5b: Ask About Jira Integration

Runs regardless of whether a team repo was configured in Step 4/5.

Use AskUserQuestion:
- header: "Jira"
- question: "Does this project use Jira (via the `acli` CLI) for ticket tracking? Enabling this lets /jira and jira-aware features (like /create-requirements auto-seeding from a loaded ticket) run without asking each time."
- options:
  - "No" / "Skip Jira config — /jira remains available but untracked by this wizard"
  - "Yes" / "Enable Jira integration and run a quick acli check"
- multiSelect: false

**If "No"** — set `JIRA_ENABLED=""` (omit the `jira:` block entirely in Step 6; `jira.enabled` already defaults to `true` when absent, so this only means the wizard skips asking about write access — it does not disable `/jira`). Skip to Step 6.

**If "Yes"** — run the check and report results before asking about write access:

```bash
ACLI_INSTALLED=false
ACLI_AUTHENTICATED=false
ACLI_AUTH_SITE=""

if command -v acli >/dev/null 2>&1; then
  ACLI_INSTALLED=true
  if AUTH_OUT=$(timeout 10 acli jira auth status 2>&1); then
    ACLI_AUTHENTICATED=true
    # Surface the site only, never the account/email line — matches the
    # precedent in plugin/shared/jira/lib.sh's jira_resolve_site (site
    # only, no account identity), and bounded to one match so a single
    # unexpectedly long line can't dump unbounded into the transcript.
    ACLI_AUTH_SITE=$(printf '%s\n' "$AUTH_OUT" | grep -oE '[A-Za-z0-9.-]+\.atlassian\.net' | head -1)
  fi
fi

echo "Jira integration check:"
if [[ "$ACLI_INSTALLED" == "true" ]]; then echo "  ✓ acli installed"; else echo "  ✗ acli not found on PATH"; fi
if [[ "$ACLI_AUTHENTICATED" == "true" ]]; then
  if [[ -n "$ACLI_AUTH_SITE" ]]; then
    echo "  ✓ authenticated (site: $ACLI_AUTH_SITE)"
  else
    echo "  ✓ authenticated"
  fi
elif [[ "$ACLI_INSTALLED" == "true" ]]; then
  echo "  ✗ not authenticated"
fi
```

If either check failed, show a one-line remediation hint but do **not** block on it — the flag records project *intent*, and acli may be installed/authenticated later by whoever runs this project next:
- Not installed: "Install from https://developer.atlassian.com/cloud/acli/guides/introduction/"
- Not authenticated: "Run: acli jira auth login"

Set `JIRA_ENABLED="true"`.

Then ask about write access:

Use AskUserQuestion:
- header: "Jira Writes"
- question: "Also enable /jira write operations (comment, transition, assign/unassign)? Each write still requires an explicit per-write confirmation."
- options:
  - "No — read-only (Recommended)" / "jira.write.enabled stays false; /jira can view tickets and comments only"
  - "Yes — enable writes" / "jira.write.enabled: true"
- multiSelect: false

Set `JIRA_WRITE_ENABLED` to `"true"` or `"false"` accordingly.

### Step 6: Build Configuration

If `LOCAL_PATH` was not set (e.g., user selected "Create new" in Step 5 and execution stopped), default it:

```bash
LOCAL_PATH="${LOCAL_PATH:-.claude}"
```

Build the YAML configuration using the `LOCAL_PATH` value. The `storage` section always includes a `local` location. If the user configured a team repo, add a `team-knowledge` location as well.

**Generate the artifact mappings from the template, never from a list written here.** A hardcoded list drifts the moment the template gains an artifact, and a config missing an artifact resolves it to a fallback path that is silently wrong whenever `LOCAL_PATH` is not the conventional `.claude` — which is the defect this step exists to stop producing:

```bash
NEXUS_SHARED="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || NEXUS_SHARED="$HOME/.claude/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || { echo "ERROR: nexus plugin not found or out of date — reinstall: /plugin install nexus@claude-skills" >&2; exit 1; }
source "$NEXUS_SHARED/resolve-config.sh"
source "$NEXUS_SHARED/config/artifacts.sh"
TEMPLATE=$(artifact_template_path) || TEMPLATE=""

# Bind TEAM_LOCATION HERE. Step 5 decided it, but that was a different shell,
# so nothing carries it into this block. Set it to team-knowledge if Step 4
# answered Yes, and to the empty string otherwise — an accidental empty value
# would silently remap every shared artifact to local, which is the
# higher-impact half of the defect this ticket fixes.
TEAM_LOCATION=""          # or: TEAM_LOCATION="team-knowledge"
LOCAL_PATH="${LOCAL_PATH:-.claude}"   # likewise: whatever Step 4/5 selected

ARTIFACTS_YAML=""
if [[ -n "$TEMPLATE" ]]; then
  ARTIFACTS_YAML=$(artifact_wizard_yaml "$TEMPLATE" "$TEAM_LOCATION")
fi

# Gate on the OUTPUT, not on whether a template was found: a readable template
# with no storage.artifacts section yields an empty render, and writing that
# would emit `artifacts:` with nothing under it — the incomplete config this
# step exists to prevent.
if [[ -z "$ARTIFACTS_YAML" ]]; then
  echo "Template artifact list unavailable — use the built-in set below."
else
  # Print it: this block's stdout is what gets pasted under `artifacts:`.
  # A variable assignment alone would die with the block.
  printf '%s\n' "$ARTIFACTS_YAML"
fi
```

The block's stdout **is** the `artifacts:` mapping. Paste it verbatim where `${ARTIFACTS_YAML}` appears below; if the block printed the "unavailable" message instead, use the built-in set further down.

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
      path: "${LOCAL_PATH}"  # quoted: a custom path may contain a space or start with a dash
  artifacts:
${ARTIFACTS_YAML}
```

**If team repo configured** — set `TEAM_LOCATION=team-knowledge` before rendering, and add the location. `team-knowledge` is the name the template, `plugin/CLAUDE.md`, and Step 5's own prompt all use; generating a different name here would mean the template's shared artifacts could never be matched against a config this wizard wrote:

```yaml
storage:
  locations:
    local:
      type: directory
      path: "${LOCAL_PATH}"  # quoted: a custom path may contain a space or start with a dash
    team-knowledge:
      type: git       # or directory
      path: /absolute/path/to/team-knowledge
  artifacts:
${ARTIFACTS_YAML}          # shared artifacts now carry location: team-knowledge
```

**If `$ARTIFACTS_YAML` came back empty** — no readable template, or a template with no artifact section — the wizard still produces a usable config; Step 2 states the template is optional and that contract holds. Fall back to this built-in set, which must stay in step with `plugin/templates/configuration.yml`:

```yaml
  artifacts:
    work:              { location: local, subdir: work }
    brainstorms:       { location: local, subdir: brainstorm }
    meetings:          { location: local, subdir: meetings }
    proposals:         { location: local, subdir: proposals }
    refactoring:       { location: local, subdir: work/refactoring-sessions }
    requirements:      { location: local, subdir: requirements }
    product-knowledge: { location: local, subdir: . }
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

**If `$JIRA_ENABLED == "true"` (Step 5b answered "Yes"), add:**

```yaml
jira:
  enabled: true
  write:
    enabled: ${JIRA_WRITE_ENABLED}   # true or false, from Step 5b
```

If Step 5b answered "No", omit the `jira:` block entirely — `jira.enabled` already defaults to `true` when absent, so omitting it changes nothing about whether `/jira` works, only that this wizard run didn't ask about write access.

### Step 7: Write Configuration and Create Directories

```bash
mkdir -p .claude
```

Write the built YAML to `.claude/configuration.yml` using the Write tool.

Then create a directory for every locally-stored artifact so skills don't encounter missing paths. Drive this from the config just written, not from the template: an artifact the user pointed at the team repo must not also get a stray local directory, and one the user relocated must get the directory they actually chose.

```bash
NEXUS_SHARED="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || NEXUS_SHARED="$HOME/.claude/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || { echo "ERROR: nexus plugin not found or out of date — reinstall: /plugin install nexus@claude-skills" >&2; exit 1; }
source "$NEXUS_SHARED/resolve-config.sh"
source "$NEXUS_SHARED/config/artifacts.sh"

# Read LOCAL_PATH back out of the file just written rather than relying on the
# wizard's variable: this is a new shell, so an unbound LOCAL_PATH would make
# every mkdir absolute — `mkdir -p -- /work`, `/meetings` — creating
# directories outside the project, or failing with EPERM and silently creating
# none.
LOCAL_PATH=$(yq -r 'select(document_index == 0) | .storage.locations.local.path // ".claude"' \
             ".claude/configuration.yml")
[[ -n "$LOCAL_PATH" && "$LOCAL_PATH" != "null" ]] || LOCAL_PATH=".claude"

# LOCAL_PATH is the one value here the user typed freely, and it prefixes every
# mkdir below. A config arriving with a cloned repo could carry an absolute or
# traversing path; fall back rather than create directories outside the project.
if [[ "$LOCAL_PATH" == /* || "$LOCAL_PATH" == *".."* ]]; then
  echo "Refusing storage path '${LOCAL_PATH}' — must be relative and must not traverse. Using .claude." >&2
  LOCAL_PATH=".claude"
fi

while IFS= read -r subdir; do
  [[ -n "$subdir" ]] || continue
  mkdir -p -- "${LOCAL_PATH}/${subdir}"
done < <(artifact_local_dirs ".claude/configuration.yml")

# The configuration file itself always lives here, even when LOCAL_PATH differs.
mkdir -p .claude
```

`artifact_local_dirs` already skips artifacts pointing at any non-local location, and skips a `subdir` of `.` (the location root, which exists by definition).

### Step 8: Show Summary

Build the artifact rows from the config just written, so the summary reports what was actually generated rather than what this document expects:

```bash
yq -r '
  .storage.artifacts // {} | to_entries | .[]
  | "  \(.key): \(.value.location) → \(.value.subdir)"
' ".claude/configuration.yml"
```

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
  team-knowledge:       ${path} (${type})   # if configured

ARTIFACTS
────────────────────────────────────────────────
  ${one row per artifact in the written config}

REQUIREMENTS BEHAVIOR
────────────────────────────────────────────────
  auto_search:          ${value}
  auto_archive:         ${value}
  auto_load_threshold:  ${value}
  max_suggestions:      ${value}
  archive_on_pr:        ${value}

JIRA                                                          # only if jira: was written (Step 5b)
────────────────────────────────────────────────
  enabled:               ${value}
  write.enabled:          ${value}
  acli:                   ${installed/authenticated summary from Step 5b's check, or "not re-checked"}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Skills and agents will now use this configuration.

To modify later, edit .claude/configuration.yml directly
or re-run /configuration-init.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 9: Validate Configuration

**Triggered by:** "Validate" option in Step 1, or `$ARGUMENTS` containing "validate".

Step 0 routes `validate` straight here, skipping Step 1 — so neither the shared
libraries nor `$EXISTING_CONFIG` exist on that path, and check 4b below would
have nothing to compare. Set both up first. This block asks nothing, so Step 0's
"no interactive wizard" contract holds; routing through Step 1 instead would
not, because Step 1 ends in an `AskUserQuestion` whenever an existing config is
found, which is exactly the case `validate` runs in.

```bash
NEXUS_SHARED="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || NEXUS_SHARED="$HOME/.claude/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || { echo "ERROR: nexus plugin not found or out of date — reinstall: /plugin install nexus@claude-skills" >&2; exit 1; }
source "$NEXUS_SHARED/resolve-config.sh"
source "$NEXUS_SHARED/config/artifacts.sh"
TEMPLATE=$(artifact_template_path) || TEMPLATE=""

# resolve-config.sh sets CONFIG by walking up from CWD. Step 1 normally copies
# it into EXISTING_CONFIG, and validate skips Step 1 — without this line every
# check below would read an empty path and silently report nothing.
EXISTING_CONFIG="$CONFIG"
if [[ -z "$EXISTING_CONFIG" || ! -f "$EXISTING_CONFIG" ]]; then
  echo "No configuration file found to validate. Run /configuration-init to create one." >&2
  exit 1
fi
```

Read `$EXISTING_CONFIG` and run validation checks. Report results using pass/warn/fail format.

**Validation checks:**

```
1. YAML Syntax
   → Parse the file. If invalid YAML → FAIL with parse error location.

2. execution_mode
   → If string: must be "subagent" or "team" → else FAIL
   → If object: must have "default" key with value "subagent" or "team"
   → If object with "overrides": each key must be a known phase name
     Known phases: requirements_deep_dive, qa_review, documentation_update, refactor, troubleshoot, pr_review, review_plan
     Unknown phase name → WARN ("unknown phase: {name}, will be ignored by skills")

3. storage.locations
   → Each location must have "type" and "path"
   → "type" must be "git" or "directory" → else FAIL
   → "path": check if directory exists → if not, WARN ("path does not exist: {path}")
   → If type is "git": check if path contains .git/ → if not, WARN ("not a git repository: {path}")

3b. storage.locations legacy names
   → For each `location-rename:{config}:{old}:{new}` entry from:
       artifact_plan_location_rename "$EXISTING_CONFIG"
     WARN ("legacy location name '{old}' — the current template calls this
     '{new}'; run /configuration-init migrate to rename it")
   → Print any warning the planner wrote to stderr as-is: a config defining
     BOTH names cannot be renamed automatically and the user has to reconcile
     it by hand.
   → Nothing else reports this. A legacy name is internally consistent, so
     every other check passes — the config only breaks later, when the template
     gains an artifact in the canonical location and that artifact can never be
     backfilled.

4. storage.artifacts
   → Each artifact must have "location" and "subdir"
   → "location" must reference a key defined in storage.locations → else FAIL ("artifact '{name}' references undefined location '{loc}'")
   → Known artifact names: read at runtime with
       artifact_template_keys "$TEMPLATE"
     Never list them here — a list in this document is what drifted from the
     template in the first place.
   → Unknown artifact name → WARN ("unknown artifact: {name}")
   → If $TEMPLATE is empty, skip the known-name comparison and say so; every
     other check in this section still runs.

4b. storage.artifacts completeness
   → For each name from:
       artifact_missing_names "$EXISTING_CONFIG" "$TEMPLATE"
     WARN ("missing artifact: {name} — defined in the current template but
     absent from this config; run /configuration-init migrate to add it")
   → A missing artifact is not a syntax error, which is why nothing caught it
     before: resolution silently falls back to a guessed path, and that guess
     is wrong whenever the local base is not the conventional one, or the
     artifact belongs in a shared location.
   → If $TEMPLATE is empty, skip this check with an explanatory line.

5. requirements section (if present)
   → auto_archive: must be boolean → else WARN
   → auto_search: must be boolean → else WARN
   → auto_load_threshold: must be number between 0 and 1 → else WARN
   → max_suggestions: must be positive integer → else WARN
   → archive_on_pr: must be boolean → else WARN

6. jira section (if present)
   → enabled: must be boolean → else WARN
   → write.enabled: must be boolean → else WARN
   → If enabled == false AND write.enabled == true → WARN ("jira.enabled is
     false, so jira.write.enabled: true has no effect — both jira.sh and
     jira-write.sh refuse the master switch before checking write access")
```

**Output format:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Configuration Validation: {config_path}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  [PASS] YAML syntax valid
  [PASS] execution_mode: "subagent"
  [PASS] storage.locations.local: type=directory, path=.claude (exists)
  [WARN] storage.locations.team-knowledge: path /home/user/code/team-knowledge does not exist
  [WARN] storage.locations: legacy location name "team-repo" — the current
         template calls this "team-knowledge"; run /configuration-init migrate
         to rename it
  [PASS] storage.artifacts: all ${count} artifacts reference valid locations
  [FAIL] storage.artifacts.proposals: references undefined location "shared"
  [WARN] storage.artifacts: missing artifact "meetings" — defined in the current
         template but absent from this config; run /configuration-init migrate to add it
  [PASS] requirements: all values valid

  Result: 5 passed, 2 warnings, 1 failure

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If any FAIL results exist, suggest fixes. If only WARN or PASS, report "Configuration is valid."

---

### Step 10: Migrate Legacy Formats

**Triggered by:** `$ARGUMENTS` containing "migrate".

Scan the project for legacy configuration and state file formats left over from past breaking changes and rewrite them in place. All rewrites create a `.bak-YYYYMMDD-HHMMSS` copy beside the original so nothing is destroyed.

**Five migrations are checked:**

1. `configuration.json` → `configuration.yml` (JSON to YAML)
2. `*-state.json` (per-skill state files) → unified `state.json` with `type` field
3. `domain_knowledge` configuration key → `product_knowledge`
4. superseded `storage.locations` names → the names the current template uses
5. artifacts the current template defines but the config is missing

**4 must be planned and applied before 5.** An artifact is only backfillable
when its location exists in the target config, so a config still on a legacy
location name has every artifact in that location skipped. Renaming first is
what lets both land in one run; the alternative is telling the user a migration
succeeded and then having `validate` immediately name the same remedy again.

#### 10.1 Plan phase (dry run — no writes)

Step 0 routes `migrate` straight here, skipping Step 1, so nothing has sourced
the shared libraries on this path. `resolve_artifact` below is called with
stderr silenced and a hardcoded fallback, which means an undefined function
looks like a successful default — every project with a customized work location
has been migrating against the wrong directory. Load the libraries first. As in
Step 9, this block asks nothing, so the "no interactive wizard" contract holds.

The preamble and the plan build must be **one** block: `TIMESTAMP` and `PLAN` are shell state, and a separate block would start a fresh shell without them.

```bash
NEXUS_SHARED="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || NEXUS_SHARED="$HOME/.claude/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || { echo "ERROR: nexus plugin not found or out of date — reinstall: /plugin install nexus@claude-skills" >&2; exit 1; }
source "$NEXUS_SHARED/resolve-config.sh"
source "$NEXUS_SHARED/config/artifacts.sh"
TEMPLATE=$(artifact_template_path) || TEMPLATE=""

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

# Now that the preamble above defines resolve_artifact, call it the way every
# other skill does. The old `2>/dev/null || echo ".claude/work"` form silenced
# the undefined-function error and substituted a hardcoded default, so the
# breakage was invisible; resolve_artifact already falls back on its own.
WORK_DIR=$(resolve_artifact work work)
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

# 4. Superseded storage.locations names.
# Planned before the backfill below, and PENDING_LOCS carries the canonical
# names forward so step 5 can see the locations this rename is about to create.
PENDING_LOCS=()
if [[ -f ".claude/configuration.yml" ]]; then
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    PLAN+=("$entry")
    PENDING_LOCS+=("${entry##*:}")
  done < <(artifact_plan_location_rename ".claude/configuration.yml")
fi

# 5. Artifacts the template defines but this config is missing.
# artifact_plan_backfill skips anything already present (whatever it maps to)
# and skips anything whose location is undefined here, warning on stderr rather
# than writing a reference that would then fail validation. PENDING_LOCS is the
# exception: those locations do not exist yet but will, because the renames
# above are applied first.
if [[ -f ".claude/configuration.yml" && -n "$TEMPLATE" ]]; then
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && PLAN+=("$entry")
  done < <(artifact_plan_backfill ".claude/configuration.yml" "$TEMPLATE" \
             ${PENDING_LOCS[@]+"${PENDING_LOCS[@]}"})
elif [[ -f ".claude/configuration.yml" ]]; then
  echo "ℹ Template not readable — skipping the missing-artifact check. Other migrations still run."
fi
```

`${PENDING_LOCS[@]+"${PENDING_LOCS[@]}"}` rather than a bare `"${PENDING_LOCS[@]}"`: an empty array expands to an unbound-variable error under `set -u`, which most configs — the ones needing no rename — would hit.

**Report the plan to the user:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Migration Plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Legacy config file  .claude/configuration.json → .claude/configuration.yml
  Legacy state file   .claude/work/JIRA-123/requirements-state.json → state.json (type: requirements)
  Legacy config key   .claude/configuration.yml: domain_knowledge → product_knowledge
  Legacy location     .claude/configuration.yml: team-repo → team-knowledge
                      (and every artifact that referenced it)
  Missing artifact    .claude/configuration.yml: + meetings (local → meetings)

  Backups will be written as *.bak-${TIMESTAMP}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

List the entries in `PLAN` order. That order is the apply order, and a rename shown after the backfill it enables would misdescribe what is about to happen.

Print any warnings `artifact_plan_location_rename` or `artifact_plan_backfill` wrote to stderr above this box — an artifact skipped because its location is undefined, or a rename skipped because both names are already defined, is something the user may want to act on.

When the plan includes a `.yml` rewrite, add:

```
  Note: yq normalizes inline mappings and blank lines on untouched lines.
  Comments are preserved; the reformatting is cosmetic.
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

For each planned action, create the backup, then rewrite.

This phase runs in a fresh shell, and the `AskUserQuestion` gate sits between it and Step 10.1 — so it cannot share a block with the plan, and nothing survives from it. Start every apply block with the **Library Preamble**, then re-establish the two pieces of state it needs:

- **`TIMESTAMP`** — set it to the *literal string already printed in the plan*, e.g. `TIMESTAMP=20260423-160500`. Do **not** re-run `date`: a fresh value would put backups at a suffix other than the one the user was shown, and the confirmation lines would name files that do not exist.
- **`PLAN`** — re-derive it by re-running the Step 10.1 detection, or carry the confirmed entries forward literally. It must match what the user approved; if re-derivation produces a different set, stop and re-plan rather than applying a plan nobody confirmed.

**Always back up through `artifact_backup_once`, never a bare `cp`, and always check its return value.** The run computes one `TIMESTAMP` and every verb writes `<file>.bak-${TIMESTAMP}`. Until backfill existed, each verb targeted a distinct file so a plain `cp` was safe; now two verbs can target `configuration.yml` in the same run, and the second `cp` would overwrite the first verb's backup with the already-rewritten intermediate, leaving no copy of the original. `artifact_backup_once` keeps the earliest copy. This applies to every verb, not just the new one — a guard on backfill alone still loses the original when backfill runs first. It returns non-zero when it could not produce a real backup (the path is a symlink, a directory, or `cp` failed); proceeding past that would rewrite a file whose only "backup" does not exist.

**Check the YAML tooling once, before any verb runs.** `rename-key`, `location-rename`, and `artifact-backfill` all rewrite `configuration.yml` with `yq -i`. Gating only one of them would still let the others strip every comment in the same run.

Run this whenever the confirmed plan contains **any** verb that writes a `.yml` file — that is `config-json-to-yml`, `rename-key`, `location-rename`, or `artifact-backfill`. Decide that from the plan you showed the user; do not branch on a `PLAN` array, which does not exist in this shell:

```bash
NEXUS_SHARED="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || NEXUS_SHARED="$HOME/.claude/shared"
[ -f "$NEXUS_SHARED/config/artifacts.sh" ] || { echo "ERROR: nexus plugin not found or out of date — reinstall: /plugin install nexus@claude-skills" >&2; exit 1; }
source "$NEXUS_SHARED/resolve-config.sh"
source "$NEXUS_SHARED/config/artifacts.sh"
TEMPLATE=$(artifact_template_path) || TEMPLATE=""
TIMESTAMP=<the literal timestamp printed in the plan>

if ! artifact_yq_preserves_comments; then
  artifact_yq_refusal_message ".claude/configuration.yml" >&2
  exit 1
fi
```

**config-json-to-yml** (uses `yq` to convert JSON to YAML):
```bash
artifact_backup_once ".claude/configuration.json" "${TIMESTAMP}" || exit 1
yq -P '.' ".claude/configuration.json" > ".claude/configuration.yml"
# Only remove original after successful YAML write
if [[ -s ".claude/configuration.yml" ]]; then
  rm ".claude/configuration.json"
fi
```

**state-rename** (add `type` field, rename file). Plan entries are `state-rename:<path-to-old-file>:<type>`, so bind all three variables first — with the backup now checked, leaving `old_path` unset aborts the migration rather than silently doing nothing:
```bash
entry="${plan_entry}"                 # e.g. state-rename:.claude/work/X/requirements-state.json:requirements
type_field="${entry##*:}"
old_path="${entry#state-rename:}"; old_path="${old_path%:*}"
dir="$(dirname "$old_path")/"

if [[ -s "${dir}state.json" ]]; then
  echo "⚠ Skipping ${old_path} — ${dir}state.json already written by an earlier migration in this directory."
  continue
fi
artifact_backup_once "${old_path}" "${TIMESTAMP}" || exit 1
jq --arg t "${type_field}" '. + {type: $t}' "${old_path}" > "${dir}state.json"
if [[ -s "${dir}state.json" ]]; then
  rm "${old_path}"
fi
```

**rename-key** (update a top-level YAML key, preserve structure):
```bash
artifact_backup_once "${file}" "${TIMESTAMP}" || exit 1
yq -i '.product_knowledge = .domain_knowledge | del(.domain_knowledge)' "${file}"
```

**location-rename** (rename a storage location and repoint every artifact that used it). Plan entries have the form `location-rename:<config-path>:<old>:<new>`. **Apply every one of these before any `artifact-backfill` entry** — a backfill whose location has not been renamed yet is skipped, and the run would report success while leaving the config exactly as drifted as it found it:
```bash
entry="${plan_entry}"                  # e.g. location-rename:.claude/configuration.yml:team-repo:team-knowledge
new="${entry##*:}"
rest="${entry%:*}"; old="${rest##*:}"
file="${rest%:*}"; file="${file#location-rename:}"

artifact_backup_once "${file}" "${TIMESTAMP}" || exit 1
if ! artifact_apply_location_rename "${file}" "${old}" "${new}"; then
  echo "✗ Renaming location ${old} → ${new} failed. The original is at ${file}.bak-${TIMESTAMP}" >&2
  exit 1
fi
```

The rename and the artifact repointing are one write inside the library, so there is no state in which the config references a location that no longer exists. It refuses rather than guessing when the config already defines both names.

**artifact-backfill** (add one missing artifact using the template's mapping). Plan entries have the form `artifact-backfill:<config-path>:<artifact-name>`, so split on the last colon — an artifact name never contains one:
```bash
entry="${plan_entry}"                  # e.g. artifact-backfill:.claude/configuration.yml:meetings
name="${entry##*:}"
file="${entry#artifact-backfill:}"; file="${file%:*}"

artifact_backup_once "${file}" "${TIMESTAMP}" || exit 1
if ! artifact_apply_backfill "${file}" "${TEMPLATE}" "${name}"; then
  echo "✗ Backfill of ${name} failed. The original is at ${file}.bak-${TIMESTAMP}" >&2
  exit 1
fi
```

After each action, print a single line confirmation:

```
✓ .claude/configuration.json → .claude/configuration.yml  (backup: .bak-20260423-160500)
✓ .claude/work/JIRA-123/requirements-state.json → state.json  (backup: .bak-20260423-160500)
✓ .claude/configuration.yml: domain_knowledge → product_knowledge  (backup: .bak-20260423-160500)
✓ .claude/configuration.yml: storage.locations.team-repo → team-knowledge, 3 artifacts repointed  (backup: .bak-20260423-160500)
✓ .claude/configuration.yml: + storage.artifacts.meetings  (backup: .bak-20260423-160500)
```

If any step fails, stop and report which action failed. The user can retry after resolving the issue.

#### 10.3 Summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Migration Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Actions applied: {count}
  Locations renamed: {count}
  Artifacts backfilled: {count}
  Backups created: {count}   # at most one per file, holding its pre-run state

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
# → Writes configuration.yml with team-knowledge location and shared artifacts
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

# → Scans for legacy configuration.json, *-state.json, domain_knowledge key,
#   and artifacts the current template defines but this config is missing
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
