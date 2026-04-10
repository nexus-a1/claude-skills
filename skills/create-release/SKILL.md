---
name: create-release
category: release-management
model: haiku
userInvocable: true
description: Push a release branch and open a PR to the target branch. Step 2 of the release workflow — runs after branching, before merging.
argument-hint: "[target-branch] [version]"
allowed-tools: "Bash(GIT_AUTHORIZED=1 git push:*), Bash(GIT_AUTHORIZED=1 git checkout:*), Bash(git ls-remote:*), Bash(git branch:*), Bash(git log:*), Bash(git diff:*), Bash(git rev-parse:*), Bash(git fetch:*), Bash(git remote:*), Bash(gh pr create:*), Bash(gh pr list:*), Bash(gh pr edit:*), Bash(gh pr comment:*), AskUserQuestion"
---

# Create Release PR Command

## Context

Current branch: !`git branch --show-current`

Arguments provided: $ARGUMENTS

Remote status: !`git remote -v`

Available branches: !`git branch -a | grep -E "(release/|master|main|develop)"`

Recent commits: !`git log --oneline -10`

## Your Task

**IMPORTANT**: You MUST complete all steps in a single message using parallel tool calls where possible. Do not send multiple messages.

This command creates a Pull Request from a release branch (e.g., `release/v1.0.2`) to a target branch (default: master). It's designed for the release workflow where you create a PR, get it approved, then merge using `/merge-release`.

### 1. Parse Arguments

Arguments are provided in $ARGUMENTS with these possible formats:

**Format:** `/create-release [target-branch] [version]`

**Examples:**
- `/create-release` - Interactive mode (prompts for everything)
- `/create-release master` - Target master, prompt for version
- `/create-release master v1.0.2` - Target master, release v1.0.2
- `/create-release v1.0.2` - If first arg looks like version, target master
- `/create-release master 1.0.2` - Version without 'v' prefix works too

**Parsing logic:**
1. If no arguments: Interactive mode
2. If one argument:
   - If starts with 'v' or matches X.Y.Z pattern: It's a version (target = master)
   - Otherwise: It's a target branch (prompt for version)
3. If two arguments: First is target, second is version

**Version normalization:**
- `v1.0.2` → `v1.0.2`
- `1.0.2` → `v1.0.2`
- Always ensure 'v' prefix

### 2. Interactive Mode: Detect Available Release Branches

If no version was provided, list available release branches:

```bash
# Find all release branches (local and remote)
git branch -a | grep 'release/' | sed 's|remotes/origin/||' | sed 's|^[* ]*||' | sort -u -V -r
```

**If release branches found:**

Use AskUserQuestion to present options:
```
Which release branch would you like to create a PR for?

Available release branches:
- release/v1.0.2
- release/v1.0.1
- release/v0.9.5

[Or specify a new version]
```

**If no release branches found:**

Ask user to provide version:
```
No existing release branches found.

What version would you like to release?
(Format: v1.0.2 or 1.0.2)
```

### 3. Validate Target Branch

- Default target: `master`
- If user provided different target, validate it exists
- **Normalize the branch name:**
  - Check if exact branch exists: `git rev-parse --verify <target> 2>/dev/null`
  - If not, try alternative forms:
    - If target is "main", try "origin/main"
    - If target is "origin/main", try "main"
    - If target is "master", try "origin/master"
    - If target is "origin/master", try "master"
  - Use the first valid branch reference found

**If target branch doesn't exist:**
```
✗ Target branch '<target>' not found

Available branches:
<list branches>
```

Stop execution

### 4. Determine Release Branch Name

Construct release branch name from version:

```
release_branch = "release/${version}"
```

Examples:
- `v1.0.2` → `release/v1.0.2`
- `1.0.2` → `release/v1.0.2`

### 5. Checkout Release Branch

Check if release branch exists:

```bash
# Check if local branch exists
git rev-parse --verify ${release_branch} 2>/dev/null

# If not, check remote
git rev-parse --verify origin/${release_branch} 2>/dev/null
```

**If branch exists locally:**
```bash
GIT_AUTHORIZED=1 git checkout ${release_branch}
```

**If branch exists on remote only:**
```bash
GIT_AUTHORIZED=1 git checkout -b ${release_branch} origin/${release_branch}
```

**If branch doesn't exist anywhere:**

Use AskUserQuestion to ask:
```
Release branch '${release_branch}' doesn't exist.

Would you like to:
[c] Create it from ${target_branch}
[a] Abort
```

**Handle responses:**

- **'c' or 'create'**:
  ```bash
  GIT_AUTHORIZED=1 git checkout -b ${release_branch} ${target_branch}
  ```
  Show:
  ```
  ✓ Created release branch: ${release_branch}
  ```
  Continue

- **'a' or 'abort'**:
  ```
  Release PR creation cancelled
  ```
  Stop execution

### 6. Ensure Branch is Pushed

Push release branch to remote if needed:

```bash
# Check if remote branch exists
git ls-remote --heads origin ${release_branch}
```

**If remote branch doesn't exist:**
```bash
GIT_AUTHORIZED=1 git push -u origin ${release_branch}
```

**If remote branch exists but is behind:**
```bash
GIT_AUTHORIZED=1 git push origin ${release_branch}
```

### 7. Analyze Changes

Get commits and changes between target and release branch:

```bash
# Get commit history
git log ${normalized_target}..${release_branch} --oneline

# Get changed files
git diff --name-status ${normalized_target}..${release_branch}

# Get statistics
git diff --stat ${normalized_target}..${release_branch}
```

### 8. Extract Ticket Numbers from Commits

Parse commit messages to extract ticket numbers:

```bash
# Get all commit messages
git log ${normalized_target}..${release_branch} --format="%s"
```

**Extraction logic:**
- Look for patterns: `[JIRA-123]`, `[jira-123]`, `JIRA-123`, `jira-123:`
- Common formats:
  - `[JIRA-123] commit message`
  - `jira-123: commit message`
  - Ticket numbers in commit body
- Extract all unique ticket numbers
- Convert to uppercase for consistency
- Sort and deduplicate

**Example output:**
```
Tickets in this release:
- JIRA-456
- JIRA-789
- JIRA-890
```

### 9. Generate PR Title

Create title for the release PR:

**Format:** `Release ${version}`

**Examples:**
- `Release v1.0.2`
- `Release v2.1.0-rc.1`

Keep it simple and clear.

### 10. Generate PR Description

Create a detailed description for the release PR:

**Structure:**
```markdown
## Release ${version}

This PR prepares release ${version} for deployment to production.

## Changes

${summary_of_changes}

## Tickets

${list_of_tickets}

## Commits

${commit_list}

## Testing Checklist

- [ ] All tests passing
- [ ] Manual testing completed
- [ ] Release notes reviewed
- [ ] Breaking changes documented (if any)
- [ ] Migration steps documented (if any)

## Deployment Notes

${any_special_deployment_instructions}
```

**Guidelines:**
- Summarize major changes from commits
- List all ticket numbers extracted from commits
- Include commit history for reference
- Add testing checklist
- Note any special deployment considerations
- Keep it professional and clear

### 11. Check for Existing PR

Before creating a new PR, check if one already exists:

```bash
gh pr list --head ${release_branch} --json number,state,title,url
```

**If PR exists and is OPEN:**
```
ℹ️  Existing PR found for ${release_branch}

PR #${number}: ${title}
Status: Open
URL: ${url}

Would you like to update it? [y/n]
```

Use AskUserQuestion to ask.

**If user says yes:**
- Update PR title and description
- Add comment with update notification

**If user says no:**
- Show existing PR info and exit

**If PR exists but is CLOSED or MERGED:**
```
ℹ️  Previous PR for ${release_branch} was ${state}

PR #${number}: ${title}
URL: ${url}

Creating new PR...
```

### 12. Create Pull Request

Use GitHub CLI to create the PR:

```bash
gh pr create \
  --base ${normalized_target} \
  --head ${release_branch} \
  --title "Release ${version}" \
  --label "release" \
  --body "$(cat <<'EOF'
${pr_description}
EOF
)"
```

**Important:**
- Use `--base` with normalized target branch
- Use `--head` with release branch name
- Add `--label "release"` to tag it as a release PR
- Use HEREDOC for multi-line description

**On success:**

Show PR URL and next steps

### 13. Report Results

After successful PR creation:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Release PR Created
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PR: Release ${version}
URL: ${pr_url}

${release_branch} → ${target_branch}

Changes:
  ${commit_count} commits
  ${file_count} files changed

Tickets:
  ${ticket_list}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next Steps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Review the PR on GitHub
2. Request approvals from required reviewers
3. Address any feedback or required changes
4. Once approved, merge using: /merge-release
```

### 14. Error Handling

Handle these cases gracefully:

**Release branch doesn't exist and user declines to create:**
```
Release PR creation cancelled. Create the release branch first:
  git checkout -b ${release_branch} ${target_branch}
```

**Target branch doesn't exist:**
```
✗ Target branch '${target_branch}' not found

Available branches:
${list branches}
```

**No commits between branches:**
```
✗ No changes to release

${release_branch} is up-to-date with ${target_branch}
No commits to include in release PR.
```

**GitHub CLI error:**
```
✗ Failed to create PR: ${error_message}

Check:
  - GitHub authentication: gh auth status
  - Repository access: gh repo view
  - Network connection
```

**Not a git repository:**
```
✗ Not a git repository

Initialize: git init
```

## Important Notes

- **Single message execution**: Complete all operations in ONE response
- **Interactive wizard**: Guide user through the process
- **Release label**: Always add "release" label to PR
- **Ticket extraction**: Parse all commits for ticket numbers
- **Approval required**: This creates the PR; use `/merge-release` to merge after approval
- **Branch management**: Handles both existing and new release branches
- **Clear communication**: Show what will happen before doing it
- **Error recovery**: Provide helpful suggestions when things go wrong

## Examples

**Example 1: Simple release**
```
User: /create-release master v1.0.2

✓ Found release branch: release/v1.0.2
✓ Checked out release/v1.0.2
✓ Pushed to remote

Analyzing changes...

Found 15 commits
Changed 47 files

Tickets in this release:
  JIRA-123, JIRA-456, JIRA-789

Creating PR...
✓ Created PR #42: Release v1.0.2

Next steps:
1. Review PR
2. Get approvals
3. Merge with /merge-release
```

**Example 2: Interactive mode**
```
User: /create-release

Available release branches:
- release/v1.0.2
- release/v1.0.1
- release/v0.9.5

User: release/v1.0.2

Target branch (default: master): master

✓ Creating PR from release/v1.0.2 to master...
```

**Example 3: New release branch**
```
User: /create-release master v2.0.0

✗ Release branch 'release/v2.0.0' doesn't exist

Would you like to:
[c] Create it from master
[a] Abort

User: c

✓ Created release/v2.0.0 from master
✓ Pushed to remote

Note: New release branch has no changes yet.
Add commits to release/v2.0.0, then run /create-release again.
```
