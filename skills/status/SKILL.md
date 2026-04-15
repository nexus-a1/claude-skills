---
name: status
category: project-setup
model: haiku
userInvocable: true
description: Show all active work sessions across brainstorms, requirements, proposals, and epics. Fast overview of where you left off.
argument-hint: "[slug]"
allowed-tools: "Read, Glob, Bash(jq:*), Bash(git:*), Bash(ls:*), Bash(yq:*)"
---

# Status

Show all active work sessions so you know where you left off.

## Usage

```bash
/status              # Show all active sessions
/status {slug}       # Show detailed status for one session
```

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work sessions |

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

---

## Workflow

### List all active sessions (`/status`)

```bash
MANIFEST="${WORK_DIR}/manifest.json"

if [[ ! -f "$MANIFEST" ]]; then
  # No manifest — scan directories for state.json files
  for dir in "${WORK_DIR}"/*/; do
    [[ -f "${dir}state.json" ]] && echo "${dir}state.json"
  done
fi
```

Read the manifest and display all sessions grouped by status. **Omit entries where `status == "completed"`** from active sessions.

**Promoted brainstorms** (status == "promoted") are shown dimmed under Brainstorm with a "→ {ticket}" link:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Active Work Sessions
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔵 Brainstorm
  user-export       User Data Export                   deep_dive    2h ago
  sso-integration   SSO with Azure AD                  Promoted → PROJ-456

🟡 Requirements
  PROJ-123          Payment Refund Flow                deep_dive    3h ago
  PROJ-456          SSO Integration        (from sso-integration)   1h ago

🟠 Proposal
  AUTH-001          User Authentication System         drafts (2)   1d ago

🟢 Epic
  checkout-v2       Checkout Redesign                  3/8 tickets  4h ago

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
To resume: /resume-work {identifier}
To load context: /load-context {identifier}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Formatting rules:**
- Brainstorm with `status == "promoted"`: show `Promoted → {promoted_to}` instead of phase/timestamp
- Requirements with `brainstorm.promoted_from`: show `(from {promoted_from})` next to last-updated
- Completed items: excluded from active list entirely

If no active sessions:
```
No active work sessions.

Start one:
  /brainstorm      — explore approaches for a feature
  /create-requirements — deep requirements for a ticket
  /epic            — break down a large initiative
```

### Show single session (`/status {slug}`)

Read `$WORK_DIR/{slug}/state.json` and display a detailed phase view:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PROJ-123 — Payment Refund Flow
Type: Requirements | Status: in_progress
Branch: feature/PROJ-123
Last updated: 3 hours ago
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✓ Stage 1  Setup          — feature branch created
  ✓ Stage 2  Discovery      — context-builder complete
  → Stage 3  Deep dive      — archaeologist ✓  data-modeler ✓  integration-analyst ⏳
  ○ Stage 4  Synthesis      — pending
  ○ Stage 4.8 Quality guard — pending

Context files: 2/4 agents complete
  ✓ context/archaeologist.md
  ✓ context/data-modeler.md
  ⏳ context/integration-analyst.md
  ○ context/architect.md

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next: /resume-work PROJ-123
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

For `type: "brainstorm"`, display the phases table. For `type: "epic"`, display the wave/ticket summary.

## Notes

- This skill is **read-only** — it never modifies state
- Uses `manifest.json` when available (fast); falls back to directory scan + state file reads
- `/resume-work {slug}` actually resumes; `/status` only reports
