---
name: create-release-branch
category: release-management
model: claude-haiku-4-5
userInvocable: true
description: Create a release/vX.Y.Z branch from origin/master (default), any branch, or a specific tag using tag@vX.Y.Z syntax
argument-hint: <version> [source]
allowed-tools: "Bash(pwd:*), Bash(git fetch:*), Bash(git branch:*), Bash(git rev-parse:*), Bash(git tag:*), Bash(git log:*), Bash(git checkout:*), Bash(git push:*), Bash(bash:*), Task, AskUserQuestion"
---

# Create Release Branch Command

> Workflow: **`/create-release-branch`** → `/create-release` → `/merge-release` → `/release`

## Context

Working directory: !`pwd`

Repository: !`git rev-parse --show-toplevel 2>/dev/null || echo "(not in a git repository)"`

Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repository)"`

Arguments provided: $ARGUMENTS

Available tags: !`git tag --sort=-version:refname 2>/dev/null || echo "(no tags)"`

Available branches: !`git branch -a --list 'master' 'main' 'develop' 'release/*' 'origin/master' 'origin/main' 'origin/develop' 'origin/release/*' 2>/dev/null || echo "(no branches listed)"`

Latest release (deterministic — `<kind> <ref> <version>`): !`bash "${CLAUDE_PLUGIN_ROOT}/shared/resolve-latest-release.sh" 2>/dev/null || echo "(resolver unavailable)"`

**Release terminology** — use the definitions in `${CLAUDE_PLUGIN_ROOT}/shared/release-concepts.md`. In particular: "latest release" is the value printed above, not your own interpretation of the tag/branch lists.

## Your Task

**IMPORTANT**: You MUST complete all steps in a single message using parallel tool calls where possible. Do not send multiple messages.

This command creates a release branch (`release/vX.Y.Z`) from a given source. The source defaults to `origin/master` but can be any branch or a specific tag.

### 0. Pre-flight: Verify Git Repository

Before doing anything else, verify the current directory is inside a git working tree. Use the same CWD shown in the Context block above:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```

**If this returns non-zero or empty** (CWD is not a git repository — e.g., a monorepo root that only contains service repos as subdirectories), stop immediately with a message that includes the actual CWD so the user can see what directory the skill is inspecting:

```
✗ Not in a git repository

Working directory: $(pwd)

/create-release-branch must be run from inside a git repository.
The directory above is what the skill inspected, and it is not a git
working tree.

If that directory is a monorepo root containing service repos as
subdirectories, Claude Code must be launched from inside the specific
service directory — the skill's context is evaluated against the
session's working directory, and `cd` within an active session may not
update it for subsequent skill invocations.

To fix:
  1. Exit this Claude Code session
  2. cd into the specific service repository you want to release
  3. Launch Claude Code from there
  4. Re-run: /create-release-branch <version>

To create release branches across multiple services, launch Claude Code
individually from within each service directory.
```

Do NOT proceed to any other step.

### 1. Parse Arguments

Arguments are provided in $ARGUMENTS with this format:

**Format:** `/create-release-branch <version> [source]`

**Examples:**
- `/create-release-branch` — Interactive mode
- `/create-release-branch v1.2.0` — Create from origin/master
- `/create-release-branch v1.2.0 master` — Create from origin/master (shorthand)
- `/create-release-branch v1.2.0 origin/master` — Explicit remote branch
- `/create-release-branch v1.2.0 tag@v1.1.1` — Create from tag v1.1.1

**Parsing logic:**
1. If no arguments: Interactive mode — ask for version and source
2. If one argument:
   - If it looks like a version (`v1.2.0`, `1.2.0`): Use it, default source to `origin/master`
   - Otherwise: Treat as source, ask for version interactively
3. If two arguments: First is version, second is source

**Version normalization:**
- `v1.2.0` → `v1.2.0`
- `1.2.0` → `v1.2.0`
- Always ensure `v` prefix

**Source normalization:**
- `origin/master` → use as-is
- `master` → resolve to `origin/master`
- `main` → resolve to `origin/main`
- `tag@v1.1.1` → extract `v1.1.1`, resolve to the tag ref

### 2. Interactive Mode

**CRITICAL — grounding the next-version suggestion:** When you offer a `(next)` or `(recommended)` version in the AskUserQuestion options, it **MUST** be derived from the `Latest release` line in the Context block above (the output of `resolve-latest-release.sh` for the **current repository** — see the `Repository:` line). Do NOT carry over a version from earlier in this conversation, from another repository you recently worked in, or from the `Available branches` list. Each repo has independent version history — a version used in one repo tells you nothing about the next version in another.

To compute the suggested next version:

- Parse `<version>` from `Latest release` (e.g. `3.5.0`). If it is `0.0.0` (none), suggest `v0.1.0` as a starting point and mark it accordingly.
- Offer a minor bump as the primary suggestion: `v{major}.{minor+1}.0` (e.g. `3.5.0` → `v3.6.0`).
- Optionally offer a patch bump (`v{major}.{minor}.{patch+1}`) and major bump (`v{major+1}.0.0`) as alternatives.
- Label the suggestion with the source it came from, e.g. `v3.6.0 (next minor after v3.5.0 in <repo-name>)`, so the user can verify at a glance that it matches the current repository.

If version was not provided, ask:

```
What version are you releasing?
(Format: v1.2.0 or 1.2.0)
```

Then ask for source:

```
Create branch from: (default: origin/master)

Options:
  • origin/master (default)
  • tag@<version>  — branch from a specific release tag
  • <branch>       — any other branch

Press enter to use origin/master, or type a source:
```

Use AskUserQuestion for both.

### 3. Resolve Source Reference

Resolve the source to a concrete git ref:

**Case: `origin/master` or `master`**
```bash
git rev-parse --verify origin/master 2>/dev/null || git rev-parse --verify master 2>/dev/null
```
Use the first that resolves.

**Case: any branch name (no `tag@` prefix)**
```bash
# Try with origin/ prefix first
git rev-parse --verify origin/<branch> 2>/dev/null || git rev-parse --verify <branch> 2>/dev/null
```

**Case: `tag@<tag-name>`**

Extract the tag name (everything after `tag@`):
```bash
git rev-parse --verify <tag-name> 2>/dev/null
```

If tag doesn't exist locally, fetch first:
```bash
git fetch --tags origin 2>/dev/null
git rev-parse --verify <tag-name> 2>/dev/null
```

**If source cannot be resolved:**
```
✗ Source '<source>' not found

Available tags (recent):
<git tag --sort=-version:refname | head -10>

Available branches:
<git branch -a | grep -E '(master|main|develop)'>
```
Stop execution.

### 4. Check Release Branch Doesn't Already Exist

```bash
git rev-parse --verify release/${version} 2>/dev/null
git rev-parse --verify origin/release/${version} 2>/dev/null
```

**If branch already exists locally or remotely:**
```
✗ Release branch 'release/${version}' already exists

To use it, check it out:
  git checkout release/${version}

To create a PR from it:
  /create-release
```
Stop execution.

### 5. Show Plan and Confirm

Before creating, show what will happen:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Create Release Branch
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Branch:  release/${version}
Source:  ${resolved_source}
         ${source_description}

This will:
  • Create local branch release/${version}
  • Push to origin/release/${version}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Where `${source_description}` clarifies the source:
- For `origin/master`: `(latest commit on master)`
- For a tag: `(tag ${tag_name} — $(git log -1 --format="%h %s" ${tag_name}))`
- For a branch: `(latest commit on ${branch})`

Use AskUserQuestion to confirm:
```
Proceed? [y/n]
```

### 6. Create the Release Branch and Push

Run inline. The `git-mutation-guard.sh` hook allows the initial push to a protected branch name when the remote doesn't exist yet; subsequent pushes are blocked (changes to an existing release branch must go through a PR).

The push still requires a security-auditor confirmation for the current HEAD. For a release branch created from `origin/master` with no new commits, the confirmation for the source's HEAD applies. Record one if needed before pushing:

```bash
git checkout -b release/${version} ${resolved_ref}
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
git push -u origin release/${version}
```

**On failure**, surface the hook's error and stop.

### 7. Report Results

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Release Branch Created
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Branch:  release/${version}
Source:  ${resolved_source}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next Steps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Add any release-specific commits to release/${version}
2. When ready, create the release PR:
     /create-release
3. Get it reviewed and approved
4. Merge the PR:
     /merge-release
5. Create the GitHub release:
     /release
```

## Important Notes

- **Single message execution**: Complete all operations in ONE response
- **Git operations**: Branch creation and push run inline. The PreToolUse hook enforces branch protection (allows initial creating push, blocks subsequent pushes to `release/*`), credential scan on commits, and security-auditor confirmation on push.
- **Branch naming**: Always `release/vX.Y.Z` — enforce the `v` prefix
- **Source `master`** is treated as `origin/master` — always branch from the remote, not a potentially stale local copy
- **Tags**: `tag@v1.1.1` syntax is the explicit form; resolve the tag ref before branching
- **No force-push**: If the branch already exists, stop and inform the user rather than overwriting
- **Push immediately**: Always push the branch to remote after creating it so it's visible to the team
