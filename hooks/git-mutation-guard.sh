#!/bin/bash
# PreToolUse Hook: Enforce git-operator agent for all git mutations.
#
# Blocks git mutation commands (commit, push, pull, add, rm, mv, restore,
# clean, checkout, switch, merge, rebase, cherry-pick, stash, tag, reset,
# revert, branch -d/-D, remote add/remove/set-url) run directly via Bash
# without authorization.
#
# All git mutations must flow through the git-operator agent:
#   Agent tool → subagent_type: "git-operator"
#
# BYPASS: git-operator prefixes mutation commands with GIT_AUTHORIZED=1
# to indicate they are authorized to run directly:
#   GIT_AUTHORIZED=1 git commit -m "..."
#   GIT_AUTHORIZED=1 git push -u origin feature/xyz

# Allow bypass: the command must START with GIT_AUTHORIZED=1 git.
# Each mutation must be issued as a standalone Bash call, not chained.
# Known limitation: "GIT_AUTHORIZED=1 git fetch && git commit" would match (starts
# with the bypass prefix) and exit 0 — compound-command mixing is not fully guarded.
# Risk is low: LLM-generated commands don't mix authorized reads with unauthorized
# mutations, and CLAUDE.md instructs git-operator to use standalone mutation calls.
if [[ "$CLAUDE_TOOL_INPUT" =~ ^GIT_AUTHORIZED=1[[:space:]]+git[[:space:]] ]]; then
    exit 0
fi

# Core git mutations: operations that write to refs, history, index, or the working tree.
# NOTE: "tag" is handled separately below to allow read-only listing (git tag --sort, -l).
GIT_MUTATIONS_RE='^[[:space:]]*git[[:space:]]+(commit|push|pull|add|rm|mv|restore|clean|checkout|switch|merge|rebase|cherry-pick|stash|reset|revert)\b'

# Tag mutations only: creation (-a annotated, -f force, -d delete, or a bare tag name).
# Read-only forms (--sort, --list, -l, --format, --contains, etc.) are NOT blocked.
GIT_TAG_MUTATE_RE='^[[:space:]]*git[[:space:]]+tag[[:space:]]+(-[afd]\b|--delete\b|--force\b|--annotate\b|[^-[:space:]])'

# Branch deletion (git branch -d / -D)
GIT_BRANCH_DELETE_RE='^[[:space:]]*git[[:space:]]+branch[[:space:]]+-[dD]\b'

# Remote mutations (git remote add/remove/rename/set-url)
GIT_REMOTE_MUTATE_RE='^[[:space:]]*git[[:space:]]+remote[[:space:]]+(add|remove|rename|set-url)\b'

if [[ "$CLAUDE_TOOL_INPUT" =~ $GIT_MUTATIONS_RE ]] || \
   [[ "$CLAUDE_TOOL_INPUT" =~ $GIT_TAG_MUTATE_RE ]] || \
   [[ "$CLAUDE_TOOL_INPUT" =~ $GIT_BRANCH_DELETE_RE ]] || \
   [[ "$CLAUDE_TOOL_INPUT" =~ $GIT_REMOTE_MUTATE_RE ]]; then

    echo "BLOCKED: Git mutations must go through the git-operator agent." >&2
    echo "" >&2
    echo "Use the Agent tool:" >&2
    echo "  subagent_type: \"git-operator\"" >&2
    echo "  prompt: \"Commit and push: <description of changes>\"" >&2
    echo "" >&2
    echo "git-operator enforces commit message format, security scans," >&2
    echo "branch protection rules, and efficient output flags." >&2
    exit 2
fi

exit 0
