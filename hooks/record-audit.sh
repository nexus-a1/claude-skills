#!/bin/bash
# record-audit.sh — record a successful security-auditor run so the push hook
# will allow the current HEAD to be pushed.
#
# Usage (callers invoke after security-auditor returns a clean report):
#   bash plugin/hooks/record-audit.sh
#
# Writes: .claude/session-state/git-audit.json with current branch + HEAD sha.
# State is per-worktree and invalidated whenever HEAD or branch changes
# (see git-mutation-guard.sh).

set -eu

repo_root=$(git rev-parse --show-toplevel)
head_sha=$(git rev-parse HEAD)
branch=$(git branch --show-current)
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Escape branch for JSON (backslashes and double-quotes).
branch_esc=$(printf '%s' "$branch" | sed 's/\\/\\\\/g; s/"/\\"/g')

state_dir="$repo_root/.claude/session-state"
mkdir -p "$state_dir"
cat > "$state_dir/git-audit.json" <<EOF
{
  "head_sha": "$head_sha",
  "branch": "$branch_esc",
  "timestamp": "$timestamp"
}
EOF
echo "security-auditor confirmation recorded: $branch @ $head_sha"
