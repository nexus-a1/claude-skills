---
name: merge-release
category: release-management
model: claude-haiku-4-5
userInvocable: true
description: Merge an approved release PR into its target branch. Validates PR status and checks before merging. Step 3 of the release workflow.
argument-hint: "[release-branch]"
allowed-tools: "Bash(git branch:*), Bash(GIT_AUTHORIZED=1 git checkout:*), Bash(GIT_AUTHORIZED=1 git push:*), Bash(GIT_AUTHORIZED=1 git branch:*), Bash(git fetch:*), Bash(git rev-parse:*), Bash(git log:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr merge:*), Bash(gh pr checks:*), AskUserQuestion"
---

# Merge Release PR Command

## Context

Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repository)"`

Arguments provided: $ARGUMENTS

Available release branches: !`git branch -a --list 'release/*' 'origin/release/*' 2>/dev/null || echo "(no release branches)"`

## Your Task

**IMPORTANT**: You MUST complete all steps in a single message using parallel tool calls where possible. Do not send multiple messages.

This command merges an approved release PR from a release branch (e.g., `release/v1.0.2`) into the target branch (usually master). It verifies the PR is approved and all checks pass before merging.

### 0. Pre-flight: Verify Git Repository

Before doing anything else, verify the current directory is inside a git working tree:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```

**If this returns non-zero or empty** (CWD is not a git repository — e.g., a monorepo root that only contains service repos as subdirectories), stop immediately with:

```
✗ Not in a git repository

/merge-release must be run from inside a git repository.

If you're in a monorepo root with service repos as subdirectories,
cd into a specific service repo first:

    cd <service-name>
    /merge-release release/v1.2.0

To merge release PRs across multiple services, run the skill
individually in each service directory.
```

Do NOT proceed to any other step.

### 1. Parse Arguments

Arguments are provided in $ARGUMENTS with these possible formats:

**Format:** `/merge-release [release-branch]`

**Examples:**
- `/merge-release` - Interactive mode (list available release PRs)
- `/merge-release release/v1.0.2` - Merge specific release branch
- `/merge-release v1.0.2` - Short form (adds 'release/' prefix)

**Parsing logic:**
1. If no argument: Interactive mode (list open release PRs)
2. If argument provided:
   - If starts with `release/`: Use as-is
   - Otherwise: Add `release/` prefix
   - Example: `v1.0.2` → `release/v1.0.2`

### 2. Interactive Mode: List Available Release PRs

If no release branch was provided, list all open PRs with "release" label:

```bash
# List open PRs with release label
gh pr list --label "release" --state open --json number,title,headRefName,baseRefName,url,author
```

**If release PRs found:**

Use AskUserQuestion to present options:
```
Which release PR would you like to merge?

Available release PRs:
[1] PR #42: Release v1.0.2 (release/v1.0.2 → master)
[2] PR #43: Release v1.0.1-hotfix (release/v1.0.1-hotfix → master)

Enter PR number or release branch name:
```

**If no release PRs found:**
```
✗ No open release PRs found

To create a release PR, run:
  /create-release
```

Stop execution

### 3. Find Release PR

Find the PR associated with the release branch:

```bash
# Get PR details for the release branch
gh pr list --head ${release_branch} --json number,state,title,baseRefName,url,mergeable,reviewDecision
```

**Parse the response:**

Extract:
- `number`: PR number
- `state`: PR state (OPEN, CLOSED, MERGED)
- `title`: PR title
- `baseRefName`: Target branch (e.g., master)
- `url`: PR URL
- `mergeable`: Can it be merged? (MERGEABLE, CONFLICTING, UNKNOWN)
- `reviewDecision`: Approval status (APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED)

**If no PR found:**
```
✗ No PR found for branch '${release_branch}'

To create a release PR, run:
  /create-release ${target_branch} ${version}

Example:
  /create-release master v1.0.2
```

Stop execution

**If PR is CLOSED:**
```
✗ PR #${number} for ${release_branch} is closed

PR: ${title}
URL: ${url}

This PR was closed without merging. To create a new one:
  /create-release
```

Stop execution

**If PR is already MERGED:**
```
✓ PR #${number} is already merged

PR: ${title}
URL: ${url}

The release has been successfully merged to ${base_branch}.
```

Stop execution (success)

### 4. Check PR Status

Verify the PR can be merged safely.

**Check 1: Review Status**

```bash
# Get review decision
gh pr view ${pr_number} --json reviewDecision,reviews
```

**Review decisions:**
- `APPROVED`: PR has required approvals ✓
- `CHANGES_REQUESTED`: Changes requested, cannot merge ✗
- `REVIEW_REQUIRED`: No approvals yet ✗
- `null` or empty: No review requirement configured (proceed with warning)

**If CHANGES_REQUESTED:**
```
✗ Cannot merge: Changes requested

PR #${number}: ${title}
URL: ${url}

Reviewers have requested changes. Address the feedback and get new approvals before merging.
```

Stop execution

**If REVIEW_REQUIRED:**

Use AskUserQuestion to ask:
```
⚠ Warning: PR has not been approved yet

PR #${number}: ${title}
URL: ${url}

No approvals found. Release PRs should be reviewed before merging.

Would you like to:
[w] Wait and check again
[m] Merge anyway (not recommended)
[a] Abort

Choose:
```

**Handle responses:**
- **'w' or 'wait'**: Re-check approval status
- **'m' or 'merge'**: Proceed with warning
- **'a' or 'abort'**: Cancel merge

**Check 2: CI/CD Status**

```bash
# Check status checks
gh pr checks ${pr_number}
```

**Status check results:**
- All passing ✓: Safe to merge
- Some failing ✗: Show failures
- Running ⏳: Tests still in progress

**If checks are failing:**

Use AskUserQuestion to ask:
```
⚠ Warning: Some checks are failing

PR #${number}: ${title}

Failed checks:
${list_of_failed_checks}

Would you like to:
[v] View details
[m] Merge anyway (risky)
[a] Abort

Choose:
```

**Handle responses:**
- **'v' or 'view'**: Show detailed check output, then ask again
- **'m' or 'merge'**: Proceed with warning
- **'a' or 'abort'**: Cancel merge

**If checks are running:**
```
⏳ CI/CD checks are still running

PR #${number}: ${title}

Running checks:
${list_of_running_checks}

Waiting for checks to complete...
```

Wait or ask user to proceed/abort.

**Check 3: Merge Conflicts**

```bash
# Check if branch can be merged
gh pr view ${pr_number} --json mergeable
```

**Mergeable states:**
- `MERGEABLE`: No conflicts ✓
- `CONFLICTING`: Has merge conflicts ✗
- `UNKNOWN`: Status unknown (GitHub still computing)

**If CONFLICTING:**
```
✗ Cannot merge: Merge conflicts detected

PR #${number}: ${title}
URL: ${url}

The release branch has conflicts with ${base_branch}.

To resolve:
1. git checkout ${release_branch}
2. git merge ${base_branch}
3. Resolve conflicts
4. git push
5. Run /merge-release again
```

Stop execution

### 5. Confirm Merge

Before merging, show summary and ask for confirmation:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Ready to Merge Release
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PR #${number}: ${title}
${release_branch} → ${base_branch}

Status:
  ✓ Approved by reviewers
  ✓ All checks passing
  ✓ No merge conflicts

URL: ${url}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Use AskUserQuestion to confirm:
```
Proceed with merge? [y/n]
```

**If user says no:**
```
Merge cancelled
```

Stop execution

### 6. Merge the PR

Execute the merge using GitHub CLI:

```bash
# Merge PR with merge commit (recommended for releases)
gh pr merge ${pr_number} --merge --delete-branch=false
```

**Merge strategy: `--merge`**
- Creates a merge commit
- Preserves full history
- Recommended for release PRs
- Does NOT delete the release branch (keep for reference)

**Alternative strategies (if needed):**
- `--squash`: Squash all commits into one
- `--rebase`: Rebase and merge
- Use `--merge` by default for releases

**On success:**
```
✓ PR merged successfully

PR #${number}: ${title}
${release_branch} → ${base_branch}

Merge commit: ${merge_commit_sha}
```

**On failure:**
```
✗ Merge failed: ${error_message}

This might be due to:
- Network issues
- GitHub API errors
- Branch protection rules
- Insufficient permissions

Try again or merge manually on GitHub:
  ${pr_url}
```

### 7. Post-Merge Actions

After successful merge, provide next steps:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Release Merged Successfully
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ Merged ${release_branch} into ${base_branch}

PR #${number}: ${title}
Merge commit: ${merge_commit_sha}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next Steps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Create GitHub release (if not already done):
   /release

2. Tag the release:
   git tag ${version}
   git push origin ${version}

3. Deploy to production:
   ${deployment_instructions}

4. Monitor production:
   - Check logs for errors
   - Verify core functionality
   - Monitor metrics/alerts

5. Communicate release:
   - Notify team/stakeholders
   - Update release notes
   - Close related tickets
```

**If release branch should be deleted:**

Use AskUserQuestion to ask:
```
The release has been merged. Would you like to delete the release branch?

[y] Yes, delete ${release_branch}
[n] No, keep it for reference

Choose:
```

**If user says yes:**
```bash
# Delete local branch
GIT_AUTHORIZED=1 git branch -d ${release_branch}

# Delete remote branch
GIT_AUTHORIZED=1 git push origin --delete ${release_branch}
```

## Important Notes

- Complete all operations in ONE response using parallel tool calls where possible
- Verify approvals and checks before merging
- Use merge strategy (not squash/rebase) to preserve release history
- Don't auto-delete release branches (useful for reference)
