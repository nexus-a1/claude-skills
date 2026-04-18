---
name: release
category: release-management
model: claude-haiku-4-5
userInvocable: true
description: Create a GitHub release with a version tag and auto-generated changelog. Supports pre-releases. Final step of the release workflow.
argument-hint: "[version] [branch] [--pre-release]"
allowed-tools: "Bash(git tag:*), Bash(git fetch:*), Bash(git log:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(git status:*), Bash(gh release create:*), Bash(gh pr list:*), AskUserQuestion, Skill"
---

# Release Command

## Context

Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repository)"`

Git status: !`git status -sb 2>/dev/null || echo "(not in a git repository)"`

Arguments provided: $ARGUMENTS

Available tags: !`git tag --sort=-version:refname 2>/dev/null || echo "(no tags)"`

Available branches: !`git branch -a --list 'master' 'main' 'release/*' 'origin/master' 'origin/main' 'origin/release/*' 2>/dev/null || echo "(no branches listed)"`

## Your Task

**IMPORTANT**: This command creates GitHub releases using an interactive wizard. You MUST use the AskUserQuestion tool to gather all required information. **The user makes all final decisions** - you suggest, they decide.

### Workflow Overview

There are two release workflows:

1. **Regular Release** (from `origin/master`):
   - Only allowed from `origin/master` branch
   - Look for "merged release/vX.Y.Z" in recent commit messages
   - Extract version from the merged branch name
   - Create a regular GitHub release

2. **Pre-Release (RC)** (from `release/*` branches):
   - Usually from a `release/vX.Y.Z` branch
   - Extract version from branch name
   - Append `-rc.N` suffix (increment N if previous RCs exist)
   - Create a GitHub pre-release

### Step 0: Pre-flight: Verify Git Repository

Before doing anything else, verify the current directory is inside a git working tree:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```

**If this returns non-zero or empty** (CWD is not a git repository — e.g., a monorepo root that only contains service repos as subdirectories), stop immediately with:

```
✗ Not in a git repository

/release must be run from inside a git repository.

If you're in a monorepo root with service repos as subdirectories,
cd into a specific service repo first:

    cd <service-name>
    /release v1.2.0

To create releases across multiple services, run the skill
individually in each service directory.
```

Do NOT proceed to any other step.

### Step 1: Parse Arguments and Understand Intent

Arguments in $ARGUMENTS are OPTIONAL hints that guide version suggestion:

**Argument patterns:**
- Exact version: `v1.2.3` or `1.2.3` → Use this exact version
- Version line: `v1.8` or `v1.8.x` or `1.8` → Find latest v1.8.* tag and suggest next patch
- Branch: `release/v1.0.2` → Extract version from branch
- Flag: `--pre-release` → Mark as pre-release

**Version line interpretation:**
When user provides a partial version like `v1.8`, `v1.8.x`, `1.8`, or says "patch for v1.8":
1. Search for all tags matching `v1.8.*`: `git tag -l "v1.8.*" --sort=-version:refname`
2. Find the latest one (e.g., `v1.8.5`)
3. Suggest next patch: `v1.8.6`
4. **Always confirm with user** before proceeding

**Examples:**
- User says "v1.8" → Find latest v1.8.* (e.g., v1.8.5) → Suggest v1.8.6
- User says "v1.8.x" → Same as above
- User says "patch for 1.8" → Same as above
- User says "v2.0.0" → Use exact version v2.0.0

### Step 2: Determine Default Branch

**Default branch logic:**
- If no branch argument provided, default to `origin/master`
- Normalize the branch name (same as /pr command):
  - Check if exact branch exists: `git rev-parse --verify <branch> 2>/dev/null`
  - If doesn't exist, try alternatives:
    - "main" → try "origin/main"
    - "origin/main" → try "main"
    - "master" → try "origin/master"
    - "origin/master" → try "master"
    - "release/vX.Y.Z" → try "origin/release/vX.Y.Z"
  - Use first valid branch reference found
  - If no valid branch, show error with available branches

### Step 3: Determine Default Pre-Release Flag

**Default pre-release logic:**
- If branch is `origin/master` or `origin/main` → default is NO (regular release)
- If branch matches `release/*` or `origin/release/*` → default is YES (pre-release)
- If `--pre-release` flag in arguments → default is YES

### Step 4: Analyze Tags and Determine Version Suggestions

**IMPORTANT**: Always analyze existing tags and commits to provide informed suggestions, but **let the user decide**.

#### 4.1 Fetch and Analyze Existing Tags

```bash
# Fetch all tags
git fetch --tags origin 2>/dev/null

# Get latest stable release (no -rc suffix)
git tag --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1

# Get all recent tags
git tag --sort=-version:refname | head -10
```

#### 4.2 Handle Version Line Arguments

If user provided a version line (e.g., `v1.8`, `v1.8.x`, `1.8`):

```bash
# Find all tags in this version line
git tag -l "v1.8.*" --sort=-version:refname | head -5

# Example output:
# v1.8.5
# v1.8.4
# v1.8.3
```

Then suggest: `v1.8.6` (increment patch of latest)

**Show user what was found:**
```
Found existing v1.8.x releases:
  - v1.8.5 (latest)
  - v1.8.4
  - v1.8.3

Suggested next version: v1.8.6
```

#### 4.3 Analyze Commit Scope (for new releases)

When suggesting a new version, analyze commits since last release to suggest appropriate bump:

```bash
# Get commits since last tag
git log $(git tag --sort=-version:refname | head -1)..HEAD --oneline --no-merges
```

**Suggest version bump based on commit types:**

| Commit Pattern | Suggested Bump | Example |
|----------------|----------------|---------|
| `BREAKING CHANGE:` or `!:` | Major (X.0.0) | v1.2.3 → v2.0.0 |
| `feat:` or `feat(` | Minor (X.Y.0) | v1.2.3 → v1.3.0 |
| `fix:`, `docs:`, `chore:`, etc. | Patch (X.Y.Z) | v1.2.3 → v1.2.4 |

**Show analysis to user:**
```
Commits since v1.2.3:
  - feat: add new export feature
  - fix: resolve login issue
  - chore: update dependencies

Suggested bump: Minor (new features detected)
  - v1.3.0 (Recommended - new features)
  - v1.2.4 (Patch only)
  - v2.0.0 (Major - breaking changes)
```

#### 4.4 For Pre-Release (from release/* branch)

1. Extract version from branch name:
   - Branch `release/v1.0.2` → version `v1.0.2`
   - Branch `origin/release/v1.0.2` → version `v1.0.2`
2. Check for existing RC tags for this version:
   ```bash
   git tag --list "v1.0.2-rc.*" --sort=-version:refname
   ```
3. If RCs exist, suggest next RC number:
   - Found: `v1.0.2-rc.2` → suggest `v1.0.2-rc.3`
   - Found: `v1.0.2-rc.1` → suggest `v1.0.2-rc.2`
4. If no RCs exist, suggest: `v1.0.2-rc.1`

**Version format:**
- Always use `v` prefix (e.g., `v1.0.2`, not `1.0.2`)
- Pre-release format: `vX.Y.Z-rc.N` (e.g., `v1.0.2-rc.1`)

### Step 5: Interactive Wizard

**CRITICAL**: Use AskUserQuestion to gather input. **Always present analysis and let user decide** - do not make version decisions automatically.

#### Question 1: Show Analysis and Select Version

First, show the analysis summary, then ask:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Release Version Analysis
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Latest stable release: v1.2.3
{If version line requested: "Found v1.8.x releases: v1.8.5 (latest), v1.8.4, v1.8.3"}

Commits since v1.2.3: 12
  - 3 feat: (new features)
  - 7 fix: (bug fixes)
  - 2 chore: (maintenance)

Suggested version based on changes: Minor bump → v1.3.0
```

- header: "Version"
- question: "What version should be released?"
- options (based on analysis):
  1. Suggested version with reason - mark as "(Recommended)" with description
  2. Alternative versions with explanations
  3. User can always select "Other" for custom version
- multiSelect: false

**Example options for new release:**
```
options:
  - label: "v1.3.0 (Recommended)"
    description: "Minor bump - includes new features (3 feat commits)"
  - label: "v1.2.4"
    description: "Patch only - bug fixes without new features"
  - label: "v2.0.0"
    description: "Major bump - if there are breaking changes"
```

**Example options for version line (v1.8.x):**
```
options:
  - label: "v1.8.6 (Recommended)"
    description: "Next patch for v1.8.x line (latest: v1.8.5)"
  - label: "v1.8.5"
    description: "Re-release v1.8.5 (already exists - will fail if tag exists)"
```

#### Question 2: Select Branch

- header: "Branch"
- question: "Which branch should this release be created from?"
- options:
  1. Default branch (determined in step 2) - mark as "(Recommended)"
  2. Other common branches if applicable
- multiSelect: false

#### Question 3: Is this a pre-release?

- header: "Pre-release"
- question: "Is this a pre-release (RC) or a regular release?"
- options:
  1. Based on default from step 3 - mark as "(Recommended)"
  2. Opposite of default
- multiSelect: false

### Step 6: Check Release Branch PR Status

**IMPORTANT**: This step ensures the proper release workflow is followed when a release branch exists.

After receiving the version from the wizard, check if a corresponding release branch exists and validate its PR status:

1. **Check if release branch exists:**
   ```bash
   # Try both local and remote branches
   git rev-parse --verify release/v<version> 2>/dev/null || \
   git rev-parse --verify origin/release/v<version> 2>/dev/null
   ```

   Example: If version is `v1.4.0`, check for `release/v1.4.0` or `origin/release/v1.4.0`

2. **If release branch exists, check for PR:**
   ```bash
   # Find PRs from release branch to master
   gh pr list --head release/v<version> --base master --json state,title,number,url,mergeable
   ```

   Example output (merged PR):
   ```json
   [
     {
       "number": 123,
       "state": "MERGED",
       "title": "Release v1.4.0",
       "url": "https://github.com/owner/repo/pull/123"
     }
   ]
   ```

3. **Handle PR status:**

   **Case A: No PR found (empty array `[]`)**
   - Show error and suggest creating PR:
   ```
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ⚠️  Release Branch Found, No PR
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   Release branch exists: release/v1.4.0

   However, there is no Pull Request from this branch to master.

   To follow the proper release workflow, you should:
   1. Create a PR: /create-release
   2. Review and merge the PR
   3. Then create the GitHub release

   Would you like to:
     • Create PR now (run /create-release)
     • Cancel release creation
   ```

   Use AskUserQuestion:
   - header: "Action"
   - question: "Release branch exists without PR. What would you like to do?"
   - options:
     - "Create PR with /create-release (Recommended)" - description: "Creates PR from release/v1.4.0 to master"
     - "Cancel release" - description: "Stop and handle the PR manually"

   If user selects "Create PR", invoke the `/create-release` skill using the Skill tool:
   ```
   Skill(skill: "create-release")
   ```
   Then show: "Please merge the PR and run /release again after it's merged."

   **Case B: PR is OPEN (not merged)**
   - Show information and offer to merge:
   ```
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ⚠️  Release PR Not Merged Yet
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   Release branch: release/v1.4.0
   PR: #123 - "Release v1.4.0"
   Status: OPEN (not merged)
   URL: https://github.com/owner/repo/pull/123

   The release PR must be merged to master before creating the GitHub release.

   What would you like to do?
   ```

   Use AskUserQuestion:
   - header: "Action"
   - question: "Release PR is not merged yet. What would you like to do?"
   - options:
     - "Merge PR with /merge-release (Recommended)" - description: "Check approvals, CI status, and merge the PR automatically"
     - "Review PR manually" - description: "Review the PR on GitHub before merging"
     - "Cancel release" - description: "Stop and handle the merge later"

   **Handle responses:**
   - **"Merge PR with /merge-release"**: Invoke the skill using `Skill(skill: "merge-release", args: "release/v1.4.0")`
     - The merge-release skill will handle approval checks, CI status, and merge
     - After successful merge, show: "✓ PR merged! You can now run /release again to create the GitHub release."
     - Exit the skill
   - **"Review PR manually"**: Show: "Please review and merge the PR at: <url>, then run /release again."
     - Exit the skill
   - **"Cancel release"**: Show: "Release creation cancelled."
     - Exit the skill

   **Case C: PR is MERGED or CLOSED**
   - Check if the state is "MERGED":
   ```
   ✓ Release branch PR is merged: #123
   ```
   - Proceed with release creation (continue to Step 8)
   - If state is "CLOSED" (but not merged), show warning:
   ```
   ⚠️  Warning: Release PR was closed without merging

   PR: #123 - "Release v1.4.0"
   Status: CLOSED (not merged)

   This may indicate the release was cancelled or the changes
   were incorporated differently.
   ```
   - Ask for confirmation to proceed anyway

4. **If release branch does NOT exist:**
   - This is normal for direct releases from master
   - Proceed to Step 8 (no additional checks needed)
   - Show info message:
   ```
   ℹ️  No release branch found - creating direct release from master
   ```

**Key Points:**
- Release branch name format: `release/v<version>` (e.g., `release/v1.4.0`)
- Only check for PR if release branch exists
- Enforce proper workflow: branch → PR → merge → release
- Use `/create-release` skill to create the PR if needed
- Allow direct releases from master if no release branch exists

### Step 7: Validate User Input

After receiving answers from the wizard and checking release branch PR status:

1. **Validate branch exists:**
   ```bash
   git rev-parse --verify <selected-branch> 2>/dev/null
   ```
   - If not found, error: "Branch not found: <branch>"

2. **Validate version format:**
   - Must match: `vX.Y.Z` or `vX.Y.Z-rc.N`
   - If user provided version without `v` prefix, add it automatically
   - If pre-release is YES, ensure version has `-rc.N` suffix
   - If pre-release is NO, ensure version does NOT have `-rc` suffix

3. **Check if tag already exists:**
   ```bash
   git tag --list "<version>"
   ```
   - If tag exists, error: "Tag <version> already exists. Please choose a different version."

4. **Validate release workflow:**
   - If pre-release is NO and branch is NOT `origin/master` or `origin/main`:
     - Show warning: "⚠️  Regular releases are typically created from origin/master. Current branch: <branch>"
     - Ask for confirmation to proceed

### Step 8: Show Confirmation Summary

Before creating the release, show a summary and ask for final confirmation:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Release Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Version: <version>
Branch: <branch>
Type: <Regular Release | Pre-Release (RC)>

This will:
  • Create tag: <version>
  • Create GitHub release from: <branch>
  • Generate release notes automatically

Proceed with release creation? (yes/no)
```

Use AskUserQuestion with:
- header: "Confirm"
- question: "Proceed with release creation?"
- options: ["Yes, create release", "No, cancel"]

If user selects "No, cancel", stop and show: "Release cancelled."

### Step 9: Generate Release Notes

Auto-generate release notes from commits:

1. **Find previous release tag:**
   ```bash
   git tag --sort=-version:refname | grep -v "rc" | head -1
   ```
   - For pre-releases, include RC tags: `git tag --sort=-version:refname | head -1`

2. **Get commits since last release:**
   ```bash
   git log <previous-tag>..<branch> --oneline --no-merges
   ```
   - If no previous tag, use: `git log <branch> --oneline --no-merges -20`

3. **Generate release notes:**
   - Group commits by type (if using conventional commits):
     - feat: → Features
     - fix: → Bug Fixes
     - docs: → Documentation
     - perf: → Performance
     - Other → Other Changes
   - Format as markdown:
     ```markdown
     ## What's Changed

     ### Features
     - Commit message 1
     - Commit message 2

     ### Bug Fixes
     - Fix message 1

     ### Other Changes
     - Other message 1

     **Full Changelog**: https://github.com/OWNER/REPO/compare/<previous-tag>...<version>
     ```

### Step 10: Create GitHub Release

Use `gh release create` to create the release.

**CRITICAL: Branch Name Format**

The `--target` option requires the branch name **without** the `origin/` prefix:
- Use `master` NOT `origin/master`
- Use `main` NOT `origin/main`
- Use `release/v1.0.0` NOT `origin/release/v1.0.0`

Using `origin/` prefix will cause error: `HTTP 422: Validation Failed - Release.target_commitish is invalid`

**For Regular Release:**
```bash
gh release create "<version>" \
  --target "master" \
  --title "<version>" \
  --notes "$(cat <<'EOF'
<generated-release-notes>
EOF
)"
```

**For Pre-Release:**
```bash
gh release create "<version>" \
  --target "master" \
  --title "<version>" \
  --notes "$(cat <<'EOF'
<generated-release-notes>
EOF
)" \
  --prerelease
```

**Important:**
- `--target` requires branch name WITHOUT `origin/` prefix (e.g., `master` not `origin/master`)
- `--title` is the release title (use version)
- `--notes` contains the auto-generated release notes
- `--prerelease` flag marks it as a pre-release in GitHub
- The command will automatically create the git tag
- Use HEREDOC syntax for multi-line notes

### Step 11: Report Results

Show success message with release information:

**For Regular Release:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Release Created Successfully
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Version: <version>
Type: Regular Release
Branch: <branch>
Tag: <version>

Release URL: <github-release-url>

Next steps:
  • Review release notes on GitHub
  • Announce the release to your team
  • Monitor for any issues
```

**For Pre-Release:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Pre-Release Created Successfully
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Version: <version>
Type: Pre-Release (RC)
Branch: <branch>
Tag: <version>

Release URL: <github-release-url>

⚠️  This is a pre-release and will be marked as such on GitHub.

Next steps:
  • Test the release candidate
  • Gather feedback
  • Create regular release when ready
```

## Important Notes

- **User makes all final decisions** — analyze, suggest, explain; user decides. Never auto-select versions.
- **Version lines** (`v1.8`, `v1.8.x`, `1.8`) → Find latest v1.8.* and suggest next patch. Always show existing tags first.
- **Version bumps** — Analyze commits: `BREAKING CHANGE:`/`!:` → Major, `feat:` → Minor, `fix:`/`docs:`/`chore:` → Patch. Explain reasoning.
- **Release branch workflow** — If `release/v<version>` exists, enforce PR to master: no PR → `/create-release`, open PR → `/merge-release`, merged → proceed.
- **Version format** — Always `v` prefix. Pre-releases: `vX.Y.Z-rc.N`. Default branch: `origin/master`.
- **Always use AskUserQuestion** for user input and final confirmation before creating release.
