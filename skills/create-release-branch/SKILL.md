---
name: create-release-branch
category: release-management
model: claude-haiku-4-5
userInvocable: true
description: Create a release/vX.Y.Z branch from origin/master (default), any branch, or a specific tag using tag@vX.Y.Z syntax
argument-hint: <version> [source]
allowed-tools: "Bash(pwd:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(git fetch:*), Bash(bash:*), AskUserQuestion"
---

# Create Release Branch Command

> Workflow: **`/create-release-branch`** → `/create-release` → `/merge-release` → `/release`

## Context

Working directory: !`pwd`

Repository: !`git rev-parse --show-toplevel 2>/dev/null || echo "(not in a git repository)"`

Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repository)"`

Arguments provided: $ARGUMENTS

Latest release (deterministic — `<kind> <ref> <version>`): !`bash "${CLAUDE_PLUGIN_ROOT}/shared/resolve-latest-release.sh" 2>/dev/null || echo "(resolver unavailable)"`

**Release terminology** — use the definitions in `${CLAUDE_PLUGIN_ROOT}/shared/release-concepts.md`. "Latest release" is the value printed above.

## Your Task

This skill is a thin dispatcher over the deterministic shell library at `${CLAUDE_PLUGIN_ROOT}/shared/release/`. Do not re-derive parsing or version logic in prose — call the scripts and surface their structured output.

### Step 0 — Pre-flight: verify git repo

```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```

If this returns non-zero, stop with the standard "not in a git repository" message that tells the user to `cd` into a service repo first (see `Working directory:` in Context above).

### Step 1 — Parse arguments

Run the parser:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/shared/release/parse-args.sh" \
  --skill=branch-create --json -- $ARGUMENTS
```

Possible outcomes:

- **Exit 0** — fully parsed. The output JSON has `version`, `source`, `source_kind` populated.
- **Exit 10** — ambiguous; the `missing` array names the field(s) the user didn't supply (typically `["version"]`).
- **Exit 20** — bad input. Show the `errors` array and stop.

### Step 2 — Resolve missing fields interactively

If the parser returned exit 10 with `missing` containing `version`:

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/shared/release/version-suggest.sh" --json` to get a recommended next version grounded in the **current repo's** tag/branch state.
2. Use AskUserQuestion to present:
   - The `recommended` value with its `reason` as the (Recommended) option.
   - Each entry from `alternatives` as additional options.

   **Critical**: the suggestion must come from `version-suggest.sh` run in the *current working tree* — never carry over a version seen earlier in the conversation from a different repo.

3. Re-run `parse-args.sh` with the chosen version included in `$ARGUMENTS`.

If `source` was not supplied, default to `origin/master` (parse-args already does this). The user may override via the second positional argument or the `tag@vX.Y.Z` syntax.

### Step 3 — Show plan and confirm

Run the action script in plan mode:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/shared/release/branch-create.sh" \
  --version=<v> --source=<s> --source-kind=<k> --plan --json
```

Print the human-readable plan (re-run without `--json` for display, or render the JSON yourself). Use AskUserQuestion to confirm before applying.

### Step 4 — Record audit, then apply

Pushing to `release/*` is gated by `git-mutation-guard.sh` and requires a security-auditor confirmation. Record one immediately before invoking the action script:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
```

Then run apply:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/shared/release/branch-create.sh" \
  --version=<v> --source=<s> --source-kind=<k> --apply --json
```

If `--apply` exits non-zero, surface stderr to the user verbatim and stop.

### Step 5 — Report and suggest next steps

On success, show:

```
✓ Release Branch Created
  branch: release/<v>
  source: <ref>

Next:
  /create-release          # open PR to master
  /merge-release           # merge once approved
  /release                 # tag + GitHub release
```

## Important Notes

- **Single message execution** — run all of the above in one assistant turn using parallel tool calls where independent.
- **No per-step git invocations in prose** — every git/branch/version operation goes through the shell library. The library is the source of truth.
- **Version normalization happens in the parser** — pass `$ARGUMENTS` to it raw; do not strip or add the `v` prefix yourself.
- **Audit gate** — `record-audit.sh` must run *immediately before* the action script; do not run anything between them that could change HEAD or branch.
