#!/usr/bin/env bash
# plugin/shared/release/version-suggest.sh
#
# Suggest the next release version based on the current repo state.
#
# Strategy:
#   1. Resolve the latest release via resolve-latest-release.sh.
#   2. Inspect commits since that release to detect bump kind:
#        feat:                 → minor
#        fix:/docs:/chore:/... → patch
#        BREAKING CHANGE: or ! → major
#   3. Emit recommended + alternatives.
#
# Usage:
#   bash version-suggest.sh [--json] [--line=v1.8] [--prerelease]
#
# Flags:
#   --json              Emit machine-readable JSON.
#   --base-branch=<ref> Count commits up to this ref instead of HEAD. Pass the
#                       release target (e.g. origin/master) so suggestions are
#                       correct when the script is called from a feature branch.
#   --line=vX.Y         Force a "next patch in vX.Y line" suggestion (used when
#                       the user invokes /release with a partial version like v1.8).
#   --prerelease        Suggest the next -rc.N for the current/specified version
#                       rather than a regular bump.
#
# Output (with --json):
#   { "current":     "v1.2.3",
#     "current_kind":"tag" | "branch" | "none",
#     "recommended": "v1.3.0",
#     "reason":      "minor bump — 3 feat commit(s) since v1.2.3",
#     "alternatives":[{"version":"v1.2.4","reason":"patch only"},
#                     {"version":"v2.0.0","reason":"major — breaking"}],
#     "commit_breakdown":{"feat":3,"fix":7,"chore":2,"breaking":0}
#   }
#
# Exit codes: 0 ok, 30 system-error.
set -euo pipefail

PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PLUGIN_RELEASE_DIR/lib.sh"
# shellcheck source=../resolve-latest-release.sh
source "$(cd "$PLUGIN_RELEASE_DIR/.." && pwd)/resolve-latest-release.sh"

json=0
line=""
prerelease=0
base_branch=""

while (( $# > 0 )); do
  case "$1" in
    --json)              json=1; shift ;;
    --line=*)            line="${1#--line=}"; shift ;;
    --line)              line="${2:-}"; shift 2 ;;
    --prerelease)        prerelease=1; shift ;;
    --base-branch=*)     base_branch="${1#--base-branch=}"; shift ;;
    --base-branch)       base_branch="${2:-}"; shift 2 ;;
    *)                   _die "$EX_SYSTEM" "version-suggest.sh: unknown arg '$1'" ;;
  esac
done

_require_git_repo

# Resolve latest release: "<kind> <ref> <version>".
# resolve-latest-release.sh wasn't written under `set -euo pipefail`; its
# internal `grep | head` pipelines exit 1 (and abort us) when no tags or
# release branches exist. Run it with errexit/pipefail temporarily relaxed.
set +e +o pipefail
resolver_out=$(resolve_latest_release)
resolver_status=$?
set -e -o pipefail
if (( resolver_status != 0 )) || [[ -z "$resolver_out" ]]; then
  resolver_out="none - 0.0.0"
fi
read -r current_kind current_ref current_ver <<<"$resolver_out"

# ---------------------------------------------------------------------------
# Branch 1: --line=vX.Y — find latest matching tag and suggest next patch.
# ---------------------------------------------------------------------------
if [[ -n "$line" ]]; then
  # Strip 'v' / 'x' suffix variants.
  line="${line#v}"; line="${line#V}"
  line="${line%.x}"; line="${line%.X}"
  if [[ ! "$line" =~ ^[0-9]+\.[0-9]+$ ]]; then
    _die "$EX_USER" "version-suggest.sh: --line must be vMAJOR.MINOR (got '$line')"
  fi
  # `grep` exits 1 when no tags match the pattern, which under pipefail/errexit
  # would abort the assignment. Tolerate empty matches with `|| true`.
  latest_in_line=$(git tag --list "v${line}.*" --sort=-v:refname 2>/dev/null \
    | { grep -E "^v${line//./\\.}\.[0-9]+$" || true; } | head -n1)
  if [[ -z "$latest_in_line" ]]; then
    recommended="v${line}.0"
    reason="no v${line}.x tags exist; starting at v${line}.0"
  else
    recommended=$(_bump_patch "$latest_in_line")
    reason="next patch in v${line}.x line (latest: $latest_in_line)"
  fi
  if (( json )); then
    jq -n \
      --arg current     "$current_ver" \
      --arg current_kind "$current_kind" \
      --arg recommended "$recommended" \
      --arg reason      "$reason" \
      --arg latest_in_line "$latest_in_line" \
      '{
        current:        ("v" + $current),
        current_kind:   $current_kind,
        recommended:    $recommended,
        reason:         $reason,
        alternatives:   [],
        commit_breakdown: {},
        line_match:     (if $latest_in_line == "" then null else $latest_in_line end)
      }'
  else
    echo "current:        v$current_ver ($current_kind)"
    echo "recommended:    $recommended"
    echo "reason:         $reason"
  fi
  exit "$EX_OK"
fi

# ---------------------------------------------------------------------------
# Branch 2: --prerelease — increment -rc.N within current version.
# ---------------------------------------------------------------------------
if (( prerelease )); then
  base="v$current_ver"
  if [[ "$current_kind" == "branch" ]]; then
    base="${current_ref#release/}"
  fi
  # Find existing rcs for this base.
  rc_num=0
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    if [[ "$tag" =~ ^${base//./\\.}-rc\.([0-9]+)$ ]]; then
      n="${BASH_REMATCH[1]}"
      if (( n > rc_num )); then rc_num="$n"; fi
    fi
  done < <(git tag --list "${base}-rc.*" 2>/dev/null)
  recommended="${base}-rc.$((rc_num + 1))"
  reason="next RC for $base (latest rc: ${rc_num:-none})"
  if (( json )); then
    jq -n \
      --arg current     "$current_ver" \
      --arg current_kind "$current_kind" \
      --arg recommended "$recommended" \
      --arg reason      "$reason" \
      '{
        current:        ("v" + $current),
        current_kind:   $current_kind,
        recommended:    $recommended,
        reason:         $reason,
        alternatives:   [],
        commit_breakdown: {}
      }'
  else
    echo "current:        v$current_ver ($current_kind)"
    echo "recommended:    $recommended"
    echo "reason:         $reason"
  fi
  exit "$EX_OK"
fi

# ---------------------------------------------------------------------------
# Branch 3: regular bump — analyze commits since current release.
# ---------------------------------------------------------------------------
feat_count=0
fix_count=0
chore_count=0
breaking_count=0

# Determine the comparison ref for "commits since latest release".
# - tag: use the tag itself.
# - branch: use the branch tip.
# - none: count all commits on HEAD (or --base-branch tip).
since_ref=""
case "$current_kind" in
  tag)    since_ref="$current_ref" ;;
  branch) since_ref="$current_ref" ;;
  none)   since_ref="" ;;
esac

# The head of the range defaults to HEAD, but the caller can override with
# --base-branch so that suggestions are accurate when run from a feature
# branch or detached HEAD (skills pass the release target, e.g. origin/master).
head_ref="HEAD"
if [[ -n "$base_branch" ]]; then
  if resolved=$(_resolve_branch_ref "$base_branch" 2>/dev/null); then
    head_ref="$resolved"
  else
    _log "warning: --base-branch '$base_branch' not found; falling back to HEAD"
  fi
fi

if [[ -n "$since_ref" ]]; then
  commits_range="${since_ref}..${head_ref}"
else
  commits_range="${head_ref}"
fi

# Read each subject line and classify. Use process substitution to avoid
# subshell variable scope issues.
while IFS= read -r subject; do
  [[ -z "$subject" ]] && continue
  # Detect breaking change: either "BREAKING CHANGE" anywhere, or "!:" / "!(scope):"
  if [[ "$subject" =~ BREAKING[[:space:]]CHANGE ]] \
     || [[ "$subject" =~ ^[a-zA-Z]+(\([^\)]+\))?\!: ]]; then
    breaking_count=$((breaking_count + 1))
    continue
  fi
  if [[ "$subject" =~ ^feat(\([^\)]+\))?: ]]; then
    feat_count=$((feat_count + 1))
  elif [[ "$subject" =~ ^fix(\([^\)]+\))?: ]]; then
    fix_count=$((fix_count + 1))
  else
    chore_count=$((chore_count + 1))
  fi
done < <(git log --no-merges --format="%s" "$commits_range" 2>/dev/null || true)

base_for_bump="v$current_ver"

if (( breaking_count > 0 )); then
  recommended=$(_bump_major "$base_for_bump")
  reason="major bump — $breaking_count breaking change(s) since $base_for_bump"
elif (( feat_count > 0 )); then
  recommended=$(_bump_minor "$base_for_bump")
  reason="minor bump — $feat_count feat commit(s) since $base_for_bump"
else
  recommended=$(_bump_patch "$base_for_bump")
  reason="patch bump — fix/chore commits only since $base_for_bump"
fi

alt_patch=$(_bump_patch "$base_for_bump")
alt_minor=$(_bump_minor "$base_for_bump")
alt_major=$(_bump_major "$base_for_bump")

if (( json )); then
  jq -n \
    --arg current      "$current_ver" \
    --arg current_kind "$current_kind" \
    --arg recommended  "$recommended" \
    --arg reason       "$reason" \
    --arg alt_patch    "$alt_patch" \
    --arg alt_minor    "$alt_minor" \
    --arg alt_major    "$alt_major" \
    --argjson feat     "$feat_count" \
    --argjson fix      "$fix_count" \
    --argjson chore    "$chore_count" \
    --argjson breaking "$breaking_count" \
    '{
      current:        ("v" + $current),
      current_kind:   $current_kind,
      recommended:    $recommended,
      reason:         $reason,
      alternatives:   [
        {version: $alt_patch, reason: "patch only"},
        {version: $alt_minor, reason: "minor — feature additions"},
        {version: $alt_major, reason: "major — breaking changes"}
      ] | map(select(.version != $recommended)),
      commit_breakdown: {
        feat:     $feat,
        fix:      $fix,
        chore:    $chore,
        breaking: $breaking
      }
    }'
else
  echo "current:        v$current_ver ($current_kind)"
  echo "recommended:    $recommended"
  echo "reason:         $reason"
  echo "commits since:  feat=$feat_count fix=$fix_count chore=$chore_count breaking=$breaking_count"
  echo "alternatives:   $alt_patch | $alt_minor | $alt_major"
fi

exit "$EX_OK"
