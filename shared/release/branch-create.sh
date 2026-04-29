#!/usr/bin/env bash
# plugin/shared/release/branch-create.sh
#
# Action script for /create-release-branch.
#
# Validates the requested version and source ref, refuses to clobber an
# existing release branch, then creates and pushes release/vX.Y.Z.
#
# Usage:
#   bash branch-create.sh --version=<vX.Y.Z> --source=<ref> --source-kind=<branch|tag>
#                         (--plan|--apply) [--json]
#
# Modes:
#   --plan   Validate everything and emit the plan; do not mutate anything.
#   --apply  Same validation, then create + push.
#
# The skill calling this script is expected to have already invoked
# `record-audit.sh` to satisfy git-mutation-guard.sh's audit gate. The
# internal `git push` does not re-trigger the outer hook because the hook
# only inspects the outer Bash command string.
#
# Exit codes (lib.sh):
#   0  EX_OK         — success (or plan validated cleanly)
#   20 EX_USER       — version/source invalid, branch already exists, etc.
#   30 EX_SYSTEM     — git/network failure
set -euo pipefail

PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PLUGIN_RELEASE_DIR/lib.sh"

version=""
source_hint=""
source_kind=""
mode=""
json=0

while (( $# > 0 )); do
  case "$1" in
    --version=*)     version="${1#--version=}"; shift ;;
    --version)       version="${2:-}"; shift 2 ;;
    --source=*)      source_hint="${1#--source=}"; shift ;;
    --source)        source_hint="${2:-}"; shift 2 ;;
    --source-kind=*) source_kind="${1#--source-kind=}"; shift ;;
    --source-kind)   source_kind="${2:-}"; shift 2 ;;
    --plan)          mode="plan";  shift ;;
    --apply)         mode="apply"; shift ;;
    --json)          json=1; shift ;;
    *) _die "$EX_SYSTEM" "branch-create.sh: unknown arg '$1'" ;;
  esac
done

[[ -z "$version" ]]     && _die "$EX_USER" "branch-create.sh: --version is required"
[[ -z "$source_hint" ]] && _die "$EX_USER" "branch-create.sh: --source is required"
[[ -z "$source_kind" ]] && _die "$EX_USER" "branch-create.sh: --source-kind is required"
[[ -z "$mode" ]]        && _die "$EX_USER" "branch-create.sh: --plan or --apply is required"

case "$source_kind" in
  branch|tag) ;;
  *) _die "$EX_USER" "branch-create.sh: --source-kind must be 'branch' or 'tag'" ;;
esac

# Defensive: reject leading-dash sources to prevent option injection into
# downstream git invocations.
if [[ "$source_hint" == -* ]]; then
  _die "$EX_USER" "Invalid source: '$source_hint' must not start with '-'"
fi

_require_git_repo

# ---------------------------------------------------------------------------
# Normalize + validate version
# ---------------------------------------------------------------------------
raw_version="$version"
if ! version=$(_normalize_version "$version"); then
  _die "$EX_USER" "Invalid version: '$raw_version' (expected vMAJOR.MINOR.PATCH)"
fi

release_branch="release/$version"

# ---------------------------------------------------------------------------
# Resolve source ref
# ---------------------------------------------------------------------------
resolved_ref=""
resolved_sha=""
resolved_subject=""

if [[ "$source_kind" == "branch" ]]; then
  if ! resolved_ref=$(_resolve_branch_ref "$source_hint"); then
    _die "$EX_USER" "Source branch '$source_hint' not found locally or on origin"
  fi
else
  # tag
  # Try direct, then with v-prefix normalization.
  candidate="$source_hint"
  if [[ "$(_ref_exists "$candidate")" != 1 ]]; then
    # Attempt fetch in case the tag exists only on origin.
    git fetch --tags origin >/dev/null 2>&1 || true
    if [[ "$(_ref_exists "$candidate")" != 1 ]]; then
      _die "$EX_USER" "Source tag '$source_hint' not found"
    fi
  fi
  resolved_ref="$candidate"
fi

resolved_sha=$(git rev-parse --verify "$resolved_ref" 2>/dev/null || true)
if [[ -z "$resolved_sha" ]]; then
  _die "$EX_SYSTEM" "Failed to resolve sha for '$resolved_ref'"
fi
# Use rev-list -1 then format the subject; failure here is non-fatal cosmetic.
resolved_subject=$(git log -1 --format="%h %s" "$resolved_sha" 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# Refuse clobber
# ---------------------------------------------------------------------------
if [[ "$(_ref_exists "$release_branch")" == 1 ]]; then
  _die "$EX_USER" "Release branch '$release_branch' already exists locally"
fi
if [[ "$(_ref_exists "origin/$release_branch")" == 1 ]]; then
  _die "$EX_USER" "Release branch 'origin/$release_branch' already exists on remote"
fi

# ---------------------------------------------------------------------------
# Plan output
# ---------------------------------------------------------------------------
emit_plan() {
  if (( json )); then
    jq -n \
      --arg version          "$version" \
      --arg release_branch   "$release_branch" \
      --arg source_hint      "$source_hint" \
      --arg source_kind      "$source_kind" \
      --arg resolved_ref     "$resolved_ref" \
      --arg resolved_sha     "$resolved_sha" \
      --arg resolved_subject "$resolved_subject" \
      --arg mode             "$mode" \
      '{
        version:          $version,
        release_branch:   $release_branch,
        source: {
          hint:    $source_hint,
          kind:    $source_kind,
          ref:     $resolved_ref,
          sha:     $resolved_sha,
          subject: $resolved_subject
        },
        actions: [
          ("create local branch " + $release_branch + " from " + $resolved_ref),
          ("push -u origin " + $release_branch)
        ],
        mode: $mode
      }'
  else
    cat <<EOF
Plan:
  version:          $version
  release branch:   $release_branch
  source:           $resolved_ref ($source_kind)
  source sha:       $resolved_sha
  source subject:   $resolved_subject
  actions:
    1. git checkout -b $release_branch $resolved_ref
    2. git push -u origin $release_branch
EOF
  fi
}

if [[ "$mode" == "plan" ]]; then
  emit_plan
  exit "$EX_OK"
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
# Only print the plan when emitting human-readable output; in --json mode the
# stdout must be a single JSON document (the success object below). Mirrors
# release-create.sh.
if (( json == 0 )); then
  emit_plan
  echo
fi

# Create the local branch from the resolved sha (most stable — avoids any
# subtle interpretation differences for branch vs tag refs). Capture output
# so it doesn't bleed into stdout in --json mode.
if ! checkout_out=$(git checkout -b "$release_branch" "$resolved_sha" 2>&1); then
  _die "$EX_SYSTEM" "Failed to create local branch '$release_branch': $checkout_out"
fi

# Push to origin. The git-mutation-guard.sh hook is on the OUTER Bash call
# (which is `bash branch-create.sh ...`); the inner `git push` here does not
# trip the hook. The skill that invoked us is responsible for having called
# record-audit.sh first so any later push *outside* this script is also OK.
if ! push_out=$(git push -u origin "$release_branch" 2>&1); then
  echo "(rolling back local branch $release_branch — push failed: $push_out)" >&2
  git checkout - >/dev/null 2>&1 || true
  git branch -D "$release_branch" >/dev/null 2>&1 || true
  _die "$EX_SYSTEM" "Failed to push '$release_branch' to origin: $push_out"
fi

if (( json )); then
  jq -n \
    --arg version        "$version" \
    --arg release_branch "$release_branch" \
    --arg resolved_sha   "$resolved_sha" \
    '{
      ok:             true,
      version:        $version,
      release_branch: $release_branch,
      resolved_sha:   $resolved_sha
    }'
else
  cat <<EOF

Created and pushed release branch.
  version: $version
  branch:  $release_branch
  sha:     $resolved_sha
EOF
fi

exit "$EX_OK"
