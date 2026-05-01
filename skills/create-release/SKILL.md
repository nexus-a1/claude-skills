---
name: create-release
category: release-management
model: claude-haiku-4-5
userInvocable: true
description: Push a release branch and open a PR to the target branch. Step 2 of the release workflow — runs after branching, before merging.
argument-hint: "[target-branch] [version]"
allowed-tools: "Bash(pwd:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(git fetch:*), Bash(git log:*), Bash(git remote:*), Bash(bash:*), Bash(gh pr list:*), Bash(gh pr view:*), AskUserQuestion, Write"
---

# Create Release PR Command

> Workflow: `/create-release-branch` → **`/create-release`** → `/merge-release` → `/release`

## Context

Working directory: !`pwd`

Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repository)"`

Available branches: !`git branch -a --list 'master' 'main' 'develop' 'release/*' 'origin/master' 'origin/main' 'origin/release/*' 2>/dev/null || echo "(no branches)"`

Arguments provided: $ARGUMENTS

**Release terminology** — see `${CLAUDE_PLUGIN_ROOT}/shared/release-concepts.md`.

## Your Task

Thin dispatcher over `${CLAUDE_PLUGIN_ROOT}/shared/release/`. Run all steps in a single message; use parallel tool calls where independent. Do not re-derive parsing, ref resolution, ticket extraction, or gh-CLI mechanics — call the scripts and surface their structured output.

### Step 0 — Pre-flight: verify git repo

```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```

If non-zero, stop with the standard "not in a git repository" message instructing the user to `cd` into a service repo.

### Step 1 — Parse arguments

```bash
bash "${CLAUDE_PLUGIN_ROOT}/shared/release/parse-args.sh" \
  --skill=pr-create --json -- $ARGUMENTS
```

Outcomes:
- **Exit 0** — `target` and `version`/`release_branch` populated; proceed.
- **Exit 10** — `missing` contains `version`. Run `version-suggest.sh --json` and use AskUserQuestion to pick. Re-run parser with the chosen version.
- **Exit 20** — surface errors and stop.

### Step 2 — Sync target branch from origin

Fetch the target branch before computing the commit range so the PR description reflects the real delta, not a stale local ref:

```bash
git fetch origin <target> 2>/dev/null || true
```

### Step 3 — Gather commit data

```bash
bash "${CLAUDE_PLUGIN_ROOT}/shared/release/commits-data.sh" \
  --base=<target> --head=<release_branch> --json
```

If the resolver can't find `<release_branch>` locally, try `origin/<release_branch>` for the head ref. The output JSON has:
- `commit_count`, `file_count`
- `tickets[]` — uppercased, deduped ticket IDs (e.g. `JIRA-123`)
- `breakdown` — counts by conventional-commit type (`feat`, `fix`, `chore`, …)
- `has_breaking_change`
- `commits[]` — per-commit `{sha, short, subject, type, scope, tickets, breaking}`

If `commit_count == 0`, stop with: "No commits to release — release branch matches the target."

### Step 4 — Author PR title and body

The shell library does **not** generate the PR body. That is your job.

**Title**: defaults to `Release <version>` (the script will use this if you pass `--title=""` or omit it). Override only if the user asked for something custom.

**Body**: write a concise, well-organized markdown PR body using the JSON from Step 3. A good shape:

```markdown
## Release v1.2.0

<one-paragraph summary derived from breakdown — e.g. "12 commits: 4 feat, 6 fix, 1 chore. No breaking changes.">

## Tickets

- JIRA-123, JIRA-456 …

## Highlights

- **feat(api)**: <subject from a feat commit>
- **fix(ui)**: <subject from a fix commit>
- (group by type, surface the most user-visible items)

## Commits

- abcd123 feat(api): subject — JIRA-123
- (full list, oldest-first or newest-first; pick whichever reads better)

## Testing checklist

- [ ] Manual smoke test
- [ ] Release notes reviewed
- [ ] Breaking changes documented (if any)
```

If `has_breaking_change` is true, surface it prominently at the top.

Write the body to a tempfile under `.claude/session-state/` (or `/tmp/` if the workspace path isn't available):

```bash
# Use the Write tool to create the file at e.g.
#   .claude/session-state/release-pr-body-<version>.md
```

### Step 5 — Plan: validate via pr-create.sh

```bash
bash "${CLAUDE_PLUGIN_ROOT}/shared/release/pr-create.sh" \
  --target=<target> --release-branch=<release_branch> \
  --plan --json
```

The output reports:
- `actions` — what apply will do (push branch, run gh pr create, etc.)
- `existing_pr` — non-null if an open PR exists for this head branch

Show the plan summary to the user. If `existing_pr.state == "OPEN"`, surface the URL and use AskUserQuestion to ask whether to **update** that PR (re-run apply with `--update-existing`) or abort.

### Step 6 — Confirm and apply

Use AskUserQuestion to confirm: **Open release PR now?**.

If the user confirms, record the audit gate (this script issues `git push`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
```

Immediately followed by apply:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/shared/release/pr-create.sh" \
  --target=<target> --release-branch=<release_branch> \
  --body-file=<tempfile> [--title="<custom>"] \
  --apply [--update-existing] --json
```

If apply exits non-zero, surface stderr verbatim and stop.

### Step 7 — Report

On success:

```
✓ Release PR <created|updated>
  PR:     #<n>
  url:    <url>
  branch: <release_branch> → <target>

Next:
  /merge-release   # merge once approved
```

## Important Notes

- **Single message execution** — all steps in one assistant turn.
- **No re-derived gh/git logic in prose** — every gh/git operation goes through the shared scripts.
- **Audit gate** — `record-audit.sh` must run *immediately before* `pr-create.sh --apply`, since the script issues `git push`. Do not run anything between them that could change HEAD or branch.
- **Body authoring is your job** — the shell scripts deliberately don't template prose; the JSON from `commits-data.sh` is what you have to work with. Keep it factual and grouped, no marketing voice.
