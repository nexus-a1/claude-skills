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
# shellcheck source=../shared/session-map-path.sh
. "${BASH_SOURCE[0]%/*}/../shared/session-map-path.sh"
if nexus_state_has_link "$repo_root/.claude" "$state_dir" "$state_dir/.gitignore" "$state_dir/git-audit.json"; then
  echo "ERROR: $state_dir, its parent or a file in it is a symlink — refusing to write the audit record through it." >&2
  exit 1
fi
mkdir -p "$state_dir"
# Self-ignore, as redact-output.sh does: a project has no reason to ignore
# .claude/session-state/, so `git add -A` would commit this file and dirty
# the tree on every push (breaks /pr-review --auto-fix pre-flight).
[ -e "$state_dir/.gitignore" ] || printf '*\n' > "$state_dir/.gitignore"
cat > "$state_dir/git-audit.json" <<EOF
{
  "head_sha": "$head_sha",
  "branch": "$branch_esc",
  "timestamp": "$timestamp"
}
EOF
echo "security-auditor confirmation recorded: $branch @ $head_sha"
