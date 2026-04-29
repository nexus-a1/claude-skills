#!/usr/bin/env bash
# plugin/shared/release/pr-merge.sh
#
# Action script for /merge-release.
#
# Resolves the PR for a given release branch, validates merge gates
# (review approval, status checks, mergeable state), then merges via
# `gh pr merge --merge`.
#
# Modes:
#   --list                    — emit JSON list of open release-labeled PRs
#   --plan                    — fetch PR state and emit a gate report
#   --apply                   — same gates + actually merge
#
# Selecting the PR:
#   --release-branch=<name>   — e.g. release/v1.2.0
#   --pr-number=<n>           — alternative to release-branch
#
# Override flags (apply mode only):
#   --allow-unapproved        — ignore reviewDecision != APPROVED
#   --allow-failing-checks    — ignore failing/cancelled status checks
#   --delete-branch           — pass --delete-branch to gh pr merge
#   --merge-strategy=<m>      — merge|squash|rebase (default: merge)
#
# Output:
#   --json   — emit single JSON object on stdout
#   default  — human-readable summary
#
# The merge happens server-side via the GitHub API; no `git push` is issued
# by this script, so git-mutation-guard.sh's audit gate does not apply here.
#
# Exit codes (lib.sh):
#   0  EX_OK         — success / plan computed cleanly
#   10 EX_AMBIGUOUS  — multiple PRs match (caller must disambiguate)
#   20 EX_USER       — PR not found, closed, conflicting, or gates fail
#   30 EX_SYSTEM     — gh / network / unexpected failure
set -euo pipefail

PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PLUGIN_RELEASE_DIR/lib.sh"

mode=""
release_branch=""
pr_number=""
allow_unapproved=0
allow_failing_checks=0
delete_branch=0
merge_strategy="merge"
json=0

while (( $# > 0 )); do
  case "$1" in
    --list)                   mode="list";  shift ;;
    --plan)                   mode="plan";  shift ;;
    --apply)                  mode="apply"; shift ;;
    --release-branch=*)       release_branch="${1#--release-branch=}"; shift ;;
    --release-branch)         release_branch="${2:-}"; shift 2 ;;
    --pr-number=*)            pr_number="${1#--pr-number=}"; shift ;;
    --pr-number)              pr_number="${2:-}"; shift 2 ;;
    --allow-unapproved)       allow_unapproved=1; shift ;;
    --allow-failing-checks)   allow_failing_checks=1; shift ;;
    --delete-branch)          delete_branch=1; shift ;;
    --merge-strategy=*)       merge_strategy="${1#--merge-strategy=}"; shift ;;
    --merge-strategy)         merge_strategy="${2:-}"; shift 2 ;;
    --json)                   json=1; shift ;;
    *) _die "$EX_SYSTEM" "pr-merge.sh: unknown arg '$1'" ;;
  esac
done

[[ -z "$mode" ]] && _die "$EX_USER" "pr-merge.sh: --list, --plan, or --apply is required"

case "$merge_strategy" in
  merge|squash|rebase) ;;
  *) _die "$EX_USER" "pr-merge.sh: --merge-strategy must be merge|squash|rebase (got '$merge_strategy')" ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  _die "$EX_SYSTEM" "pr-merge.sh: gh CLI not found on PATH"
fi
if ! _have_jq; then
  _die "$EX_SYSTEM" "pr-merge.sh: jq is required"
fi

# ---------------------------------------------------------------------------
# Mode: list
# ---------------------------------------------------------------------------
if [[ "$mode" == "list" ]]; then
  if ! out=$(gh pr list --label "release" --state open \
        --json number,title,headRefName,baseRefName,url,author 2>&1); then
    _die "$EX_SYSTEM" "gh pr list failed: $out"
  fi
  if (( json )); then
    printf '%s\n' "$out"
  else
    # Pretty rendering for human consumption.
    if [[ "$(printf '%s' "$out" | jq 'length')" == "0" ]]; then
      echo "(no open release PRs)"
    else
      printf '%s\n' "$out" | jq -r '
        .[] | "#\(.number)  \(.headRefName) → \(.baseRefName)  \(.title)\n  \(.url)"'
    fi
  fi
  exit "$EX_OK"
fi

# ---------------------------------------------------------------------------
# Resolve PR identifier (branch or number) → full PR JSON
# ---------------------------------------------------------------------------
if [[ -z "$release_branch" && -z "$pr_number" ]]; then
  _die "$EX_USER" "pr-merge.sh: --release-branch or --pr-number is required"
fi

# Defensive: reject leading-dash inputs to prevent option injection into gh.
if [[ "$release_branch" == -* ]]; then
  _die "$EX_USER" "Invalid --release-branch: '$release_branch' must not start with '-'"
fi
if [[ -n "$pr_number" && ! "$pr_number" =~ ^[0-9]+$ ]]; then
  _die "$EX_USER" "Invalid --pr-number: '$pr_number' must be a positive integer"
fi

PR_JSON_FIELDS="number,state,title,url,baseRefName,headRefName,mergeable,reviewDecision,statusCheckRollup"
pr_json=""

if [[ -n "$pr_number" ]]; then
  if ! pr_json=$(gh pr view "$pr_number" --json "$PR_JSON_FIELDS" 2>&1); then
    _die "$EX_USER" "PR #$pr_number not found: $pr_json"
  fi
else
  # Look up by head branch.
  if ! list_json=$(gh pr list --head "$release_branch" --state all \
        --json "$PR_JSON_FIELDS" 2>&1); then
    _die "$EX_SYSTEM" "gh pr list failed: $list_json"
  fi
  count=$(printf '%s' "$list_json" | jq 'length')
  if [[ "$count" == "0" ]]; then
    _die "$EX_USER" "No PR found for branch '$release_branch'"
  elif [[ "$count" != "1" ]]; then
    # Prefer an OPEN PR if there's exactly one.
    open_json=$(printf '%s' "$list_json" | jq '[.[] | select(.state == "OPEN")]')
    open_count=$(printf '%s' "$open_json" | jq 'length')
    if [[ "$open_count" == "1" ]]; then
      pr_json=$(printf '%s' "$open_json" | jq '.[0]')
    else
      _die "$EX_AMBIGUOUS" "Multiple PRs match branch '$release_branch' (open=$open_count, total=$count)"
    fi
  else
    pr_json=$(printf '%s' "$list_json" | jq '.[0]')
  fi
fi

pr_number=$(printf '%s' "$pr_json" | jq -r '.number')
pr_state=$(printf '%s' "$pr_json" | jq -r '.state')
pr_title=$(printf '%s' "$pr_json" | jq -r '.title')
pr_url=$(printf '%s' "$pr_json" | jq -r '.url')
pr_base=$(printf '%s' "$pr_json" | jq -r '.baseRefName')
pr_head=$(printf '%s' "$pr_json" | jq -r '.headRefName')
pr_mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable')
pr_review=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // ""')

# ---------------------------------------------------------------------------
# Compute gates
# ---------------------------------------------------------------------------
# Approval: APPROVED or empty/null (no review requirement) is OK.
approved="false"
if [[ "$pr_review" == "APPROVED" || -z "$pr_review" ]]; then
  approved="true"
fi

# Conflicts: only MERGEABLE is OK. UNKNOWN is treated as not-ready.
no_conflicts="false"
if [[ "$pr_mergeable" == "MERGEABLE" ]]; then
  no_conflicts="true"
fi

# Checks: aggregate statusCheckRollup. Each entry has a `state` (CheckRun)
# or `conclusion` (CommitStatus); empty rollup = no checks configured = pass.
checks_passing="true"
checks_running="false"
failing_checks_json=$(printf '%s' "$pr_json" | jq '[.statusCheckRollup // []
  | .[]
  | select(
      ((.conclusion // .status // .state // "") | ascii_upcase) as $r
      | $r != "SUCCESS" and $r != "NEUTRAL" and $r != "SKIPPED"
        and $r != "PENDING" and $r != "QUEUED" and $r != "IN_PROGRESS"
        and $r != ""
    )]')
running_checks_json=$(printf '%s' "$pr_json" | jq '[.statusCheckRollup // []
  | .[]
  | select(((.conclusion // .status // .state // "") | ascii_upcase) as $r
      | $r == "PENDING" or $r == "QUEUED" or $r == "IN_PROGRESS")]')

if [[ "$(printf '%s' "$failing_checks_json" | jq 'length')" != "0" ]]; then
  checks_passing="false"
fi
if [[ "$(printf '%s' "$running_checks_json" | jq 'length')" != "0" ]]; then
  checks_running="true"
fi

# Aggregate: ready means all gates green AND no checks still running.
ready="false"
if [[ "$approved" == "true" && "$no_conflicts" == "true" \
      && "$checks_passing" == "true" && "$checks_running" == "false" ]]; then
  ready="true"
fi

# Blocking issues — human-readable list, used for diagnostics.
# For MERGED PRs the per-gate checks are skipped: GitHub reports
# mergeable=UNKNOWN once a PR is merged, which would otherwise produce a
# misleading "mergeable: UNKNOWN" entry. The PR is in a terminal state, so
# the gates no longer apply.
blocking=()
case "$pr_state" in
  CLOSED) blocking+=("PR is closed") ;;
  MERGED) ;;  # not blocking — already done; skip gate checks below
esac
if [[ "$pr_state" != "MERGED" ]]; then
  [[ "$approved"      != "true"  ]] && blocking+=("review decision: ${pr_review:-REVIEW_REQUIRED}")
  [[ "$no_conflicts"  != "true"  ]] && blocking+=("mergeable: $pr_mergeable")
  [[ "$checks_passing" != "true" ]] && blocking+=("status checks failing")
  [[ "$checks_running" == "true" ]] && blocking+=("status checks still running")
fi

# ---------------------------------------------------------------------------
# Emit the report (used by both plan and apply)
# ---------------------------------------------------------------------------
emit_report() {
  if (( json )); then
    jq -n \
      --argjson pr             "$pr_json" \
      --arg     approved       "$approved" \
      --arg     no_conflicts   "$no_conflicts" \
      --arg     checks_passing "$checks_passing" \
      --arg     checks_running "$checks_running" \
      --arg     ready          "$ready" \
      --argjson failing_checks "$failing_checks_json" \
      --argjson running_checks "$running_checks_json" \
      --argjson blocking       "$(printf '%s\n' "${blocking[@]+"${blocking[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')" \
      --arg     mode           "$mode" \
      '{
        mode: $mode,
        pr: $pr,
        gates: {
          approved:       ($approved       == "true"),
          no_conflicts:   ($no_conflicts   == "true"),
          checks_passing: ($checks_passing == "true"),
          checks_running: ($checks_running == "true"),
          ready:          ($ready          == "true")
        },
        failing_checks: $failing_checks,
        running_checks: $running_checks,
        blocking_issues: $blocking
      }'
  else
    local conflicts_line
    if [[ "$no_conflicts" == "true" ]]; then conflicts_line="none"
    else conflicts_line="yes ($pr_mergeable)"; fi
    cat <<EOF
PR #$pr_number: $pr_title
  $pr_head → $pr_base
  state:       $pr_state
  url:         $pr_url
  approved:    $approved (reviewDecision=${pr_review:-<none>})
  conflicts:   $conflicts_line
  checks:      passing=$checks_passing running=$checks_running
  ready:       $ready
EOF
    if (( ${#blocking[@]} > 0 )); then
      echo "  blocking:"
      printf '    - %s\n' "${blocking[@]}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Plan mode — describe state and exit 0
# ---------------------------------------------------------------------------
if [[ "$mode" == "plan" ]]; then
  emit_report
  exit "$EX_OK"
fi

# ---------------------------------------------------------------------------
# Apply mode — enforce gates (with overrides), then merge
# ---------------------------------------------------------------------------
case "$pr_state" in
  CLOSED)
    emit_report
    _die "$EX_USER" "Cannot merge: PR #$pr_number is closed"
    ;;
  MERGED)
    if (( json )); then
      jq -n \
        --argjson pr "$pr_json" \
        '{ ok: true, already_merged: true, pr: $pr }'
    else
      echo "PR #$pr_number is already merged. Nothing to do."
    fi
    exit "$EX_OK"
    ;;
esac

# Enforce gates with override flags.
if [[ "$no_conflicts" != "true" ]]; then
  emit_report
  _die "$EX_USER" "Cannot merge: $pr_mergeable (resolve conflicts first)"
fi

if [[ "$approved" != "true" && $allow_unapproved -eq 0 ]]; then
  emit_report
  _die "$EX_USER" "Cannot merge: review decision is ${pr_review:-REVIEW_REQUIRED} (use --allow-unapproved to override)"
fi

if [[ "$checks_passing" != "true" && $allow_failing_checks -eq 0 ]]; then
  emit_report
  _die "$EX_USER" "Cannot merge: status checks failing (use --allow-failing-checks to override)"
fi

if [[ "$checks_running" == "true" ]]; then
  emit_report
  _die "$EX_USER" "Cannot merge: status checks still running (re-run later or wait)"
fi

# Build the gh pr merge invocation.
merge_args=("$pr_number" "--$merge_strategy")
if (( delete_branch )); then
  merge_args+=("--delete-branch")
fi

if ! merge_out=$(gh pr merge "${merge_args[@]}" 2>&1); then
  _die "$EX_SYSTEM" "gh pr merge failed: $merge_out"
fi

if (( json )); then
  jq -n \
    --argjson pr "$pr_json" \
    --arg strategy "$merge_strategy" \
    --arg deleted_branch "$([[ $delete_branch -eq 1 ]] && echo true || echo false)" \
    '{
      ok: true,
      merged: true,
      pr: $pr,
      strategy: $strategy,
      deleted_branch: ($deleted_branch == "true")
    }'
else
  echo
  echo "✓ Merged PR #$pr_number ($pr_head → $pr_base) with strategy=$merge_strategy"
  if (( delete_branch )); then
    echo "  branch deleted"
  fi
fi

exit "$EX_OK"
