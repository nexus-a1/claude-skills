#!/usr/bin/env bash
# plugin/shared/release/release-create.sh
#
# Action script for /release.
#
# Validates a version + branch + (existing tag absence), detects the
# release-branch workflow case, and (in --apply mode) creates the GitHub
# release with `gh release create`. The release notes are supplied by the
# caller via --notes-file (the skill prompt is responsible for authoring
# them from commits-data.sh JSON).
#
# Usage:
#   bash release-create.sh --version=<vX.Y.Z[-rc.N]> --branch=<ref>
#                          [--prerelease] [--allow-unmerged-pr]
#                          [--notes-file=<path>] [--title=<...>]
#                          (--plan|--apply) [--json]
#
# Modes:
#   --plan   Validate everything and emit the plan + workflow_case; no mutation.
#   --apply  Same validation, then run `gh release create`. Refuses if the
#            workflow case requires user routing (no-pr, open-pr) unless
#            --allow-unmerged-pr is passed for the closed-not-merged case.
#
# Workflow cases (relative to a release/<version> branch, when version is
# stable, i.e. not --prerelease):
#   none-no-release-branch — release branch doesn't exist; release directly
#                            off the target branch (typically master). OK.
#   prerelease             — --prerelease flag set; workflow check is skipped
#                            because RC tags come from in-flight branches.
#   merged                 — release/<version> exists and its PR is MERGED. OK.
#   no-pr                  — release/<version> exists, no PR. Apply blocked
#                            (caller should run /create-release first).
#   open-pr                — PR is OPEN. Apply blocked (caller should run
#                            /merge-release first).
#   closed-not-merged      — PR was CLOSED without merge. Apply blocked unless
#                            --allow-unmerged-pr is set.
#
# Exit codes (lib.sh):
#   0  EX_OK         — success / plan validated
#   10 EX_AMBIGUOUS  — workflow case requires user routing or override
#   20 EX_USER       — invalid version, tag exists, branch missing, etc.
#   30 EX_SYSTEM     — gh / git failure
#
# Note on audit gate: `gh release create` is not intercepted by
# git-mutation-guard.sh (the hook only matches `git push`). The calling skill
# is expected to invoke record-audit.sh before --apply to keep the audit
# trail consistent with the other release skills.
set -euo pipefail

PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PLUGIN_RELEASE_DIR/lib.sh"

version=""
branch=""
prerelease=0
allow_unmerged_pr=0
notes_file=""
title=""
mode=""
json=0

while (( $# > 0 )); do
  case "$1" in
    --version=*)            version="${1#--version=}"; shift ;;
    --version)              version="${2:-}"; shift 2 ;;
    --branch=*)             branch="${1#--branch=}"; shift ;;
    --branch)               branch="${2:-}"; shift 2 ;;
    --notes-file=*)         notes_file="${1#--notes-file=}"; shift ;;
    --notes-file)           notes_file="${2:-}"; shift 2 ;;
    --title=*)              title="${1#--title=}"; shift ;;
    --title)                title="${2:-}"; shift 2 ;;
    --prerelease)           prerelease=1; shift ;;
    --allow-unmerged-pr)    allow_unmerged_pr=1; shift ;;
    --plan)                 mode="plan";  shift ;;
    --apply)                mode="apply"; shift ;;
    --json)                 json=1; shift ;;
    *) _die "$EX_SYSTEM" "release-create.sh: unknown arg '$1'" ;;
  esac
done

[[ -z "$version" ]] && _die "$EX_USER" "release-create.sh: --version is required"
[[ -z "$branch"  ]] && _die "$EX_USER" "release-create.sh: --branch is required"
[[ -z "$mode"    ]] && _die "$EX_USER" "release-create.sh: --plan or --apply is required"
if [[ "$mode" == "apply" && -z "$notes_file" ]]; then
  _die "$EX_USER" "release-create.sh: --notes-file is required for --apply"
fi
if [[ -n "$notes_file" && ! -f "$notes_file" ]]; then
  _die "$EX_USER" "release-create.sh: --notes-file '$notes_file' does not exist"
fi

# Defensive: reject leading-dash inputs.
for v in "$version" "$branch"; do
  if [[ "$v" == -* ]]; then
    _die "$EX_USER" "Invalid argument: '$v' must not start with '-'"
  fi
done

_require_git_repo
if ! command -v gh >/dev/null 2>&1; then
  _die "$EX_SYSTEM" "release-create.sh: gh CLI not found on PATH"
fi
if ! _have_jq; then
  _die "$EX_SYSTEM" "release-create.sh: jq is required"
fi

# ---------------------------------------------------------------------------
# Normalize + validate version
# ---------------------------------------------------------------------------
raw_version="$version"
if ! version=$(_normalize_version "$version"); then
  _die "$EX_USER" "Invalid version: '$raw_version' (expected vX.Y.Z or vX.Y.Z-rc.N)"
fi

# Cross-check prerelease flag vs version shape: -rc.N is the only
# pre-release suffix this script blesses; ensure flag and shape agree.
version_suffix=$(_version_prerelease "$version")
if [[ -n "$version_suffix" ]]; then
  if (( prerelease == 0 )); then
    _die "$EX_USER" "Version '$version' has a pre-release suffix but --prerelease was not set"
  fi
  if [[ ! "$version_suffix" =~ ^-rc\.[0-9]+$ ]]; then
    _die "$EX_USER" "Pre-release suffix must match -rc.N (got '$version_suffix')"
  fi
else
  if (( prerelease == 1 )); then
    _die "$EX_USER" "Version '$version' is stable but --prerelease was set (release/* branch targets imply --prerelease; use a master/main target for stable releases, or use a vX.Y.Z-rc.N version for a pre-release)"
  fi
fi

# Default title to the version if caller didn't specify one. (GitHub release
# title MUST be the bare version — no "Release " prefix.)
if [[ -z "$title" ]]; then
  title="$version"
fi

# ---------------------------------------------------------------------------
# Resolve target branch
# ---------------------------------------------------------------------------
if ! target_ref=$(_resolve_branch_ref "$branch"); then
  _die "$EX_USER" "Branch '$branch' not found locally or on origin"
fi
target_local=$(_strip_origin_prefix "$target_ref")

# ---------------------------------------------------------------------------
# Refuse if tag already exists locally or on origin
# ---------------------------------------------------------------------------
tag_exists_local=0
tag_exists_remote=0
if [[ "$(_ref_exists "refs/tags/$version")" == "1" ]]; then
  tag_exists_local=1
fi
# `git ls-remote --tags origin <tag>` prints a line if the tag exists on origin.
if remote_tag=$(git ls-remote --tags origin "$version" 2>/dev/null) \
   && [[ -n "$remote_tag" ]]; then
  tag_exists_remote=1
fi

if (( tag_exists_local || tag_exists_remote )); then
  _die "$EX_USER" "Tag '$version' already exists (local=$tag_exists_local remote=$tag_exists_remote) — pick a different version"
fi

# ---------------------------------------------------------------------------
# Refuse if a GitHub release already exists for this tag
# ---------------------------------------------------------------------------
existing_release_url=""
if release_view_out=$(gh release view "$version" --json url 2>&1); then
  existing_release_url=$(printf '%s' "$release_view_out" | jq -r '.url // ""' 2>/dev/null || true)
  if [[ -n "$existing_release_url" ]]; then
    _die "$EX_USER" "GitHub release '$version' already exists: $existing_release_url"
  fi
fi
# Non-zero exit = release not found, which is the expected happy path.

# ---------------------------------------------------------------------------
# Detect workflow case
# ---------------------------------------------------------------------------
workflow_case=""
existing_pr_number=""
existing_pr_state=""
existing_pr_url=""
release_branch_name="release/${version%-rc.*}"   # strip -rc.N for branch lookup
release_branch_exists=0

if [[ "$(_ref_exists "$release_branch_name")" == "1" \
   || "$(_ref_exists "origin/$release_branch_name")" == "1" ]]; then
  release_branch_exists=1
fi

if (( prerelease )); then
  workflow_case="prerelease"
elif (( release_branch_exists == 0 )); then
  workflow_case="none-no-release-branch"
else
  # Query gh for any PR (open or closed) from this release branch.
  if pr_list=$(gh pr list --head "$release_branch_name" --base "$target_local" --state all \
        --json number,state,url --limit 5 2>&1); then
    pr_count=$(printf '%s' "$pr_list" | jq 'length')
    if [[ "$pr_count" == "0" ]]; then
      workflow_case="no-pr"
    else
      # Prefer MERGED if any; else OPEN; else CLOSED.
      pick=$(printf '%s' "$pr_list" | jq '
        ([.[] | select(.state == "MERGED")] | first) //
        ([.[] | select(.state == "OPEN")]   | first) //
        (.[0])
      ')
      existing_pr_number=$(printf '%s' "$pick" | jq -r '.number')
      existing_pr_state=$(printf '%s' "$pick" | jq -r '.state')
      existing_pr_url=$(printf '%s' "$pick" | jq -r '.url')
      case "$existing_pr_state" in
        MERGED) workflow_case="merged" ;;
        OPEN)   workflow_case="open-pr" ;;
        CLOSED) workflow_case="closed-not-merged" ;;
        *)      workflow_case="unknown" ;;
      esac
    fi
  else
    _log "warning: gh pr list failed for $release_branch_name: $pr_list"
    workflow_case="unknown"
  fi
fi

# ---------------------------------------------------------------------------
# Determine if apply is allowed and what action would happen
# ---------------------------------------------------------------------------
apply_blocked=""
suggested_skill=""
case "$workflow_case" in
  prerelease|none-no-release-branch|merged) ;;
  no-pr)
    apply_blocked="$release_branch_name has no PR — run /create-release first"
    suggested_skill="create-release"
    ;;
  open-pr)
    apply_blocked="PR #$existing_pr_number is still OPEN — run /merge-release first"
    suggested_skill="merge-release"
    ;;
  closed-not-merged)
    if (( allow_unmerged_pr == 0 )); then
      apply_blocked="PR #$existing_pr_number was closed without merging — pass --allow-unmerged-pr to override"
    fi
    ;;
  *)
    apply_blocked="workflow case unknown — refusing to proceed"
    ;;
esac

# ---------------------------------------------------------------------------
# Plan output
# ---------------------------------------------------------------------------
emit_plan() {
  if (( json )); then
    jq -n \
      --arg version          "$version" \
      --arg branch           "$target_local" \
      --arg branch_ref       "$target_ref" \
      --arg title            "$title" \
      --argjson prerelease   "$prerelease" \
      --arg workflow_case    "$workflow_case" \
      --arg release_branch   "$release_branch_name" \
      --argjson rb_exists    "$release_branch_exists" \
      --arg pr_number        "$existing_pr_number" \
      --arg pr_state         "$existing_pr_state" \
      --arg pr_url           "$existing_pr_url" \
      --arg apply_blocked    "$apply_blocked" \
      --arg suggested_skill  "$suggested_skill" \
      --arg mode             "$mode" \
      '{
        mode:           $mode,
        version:        $version,
        branch:         $branch,
        branch_ref:     $branch_ref,
        title:          $title,
        prerelease:     ($prerelease == 1),
        release_branch: {
          name:   $release_branch,
          exists: ($rb_exists == 1)
        },
        existing_pr: {
          number: (if $pr_number == "" then null else ($pr_number | tonumber) end),
          state:  (if $pr_state  == "" then null else $pr_state  end),
          url:    (if $pr_url    == "" then null else $pr_url    end)
        },
        workflow_case:    $workflow_case,
        apply_blocked:    (if $apply_blocked   == "" then null else $apply_blocked   end),
        suggested_skill:  (if $suggested_skill == "" then null else $suggested_skill end)
      }'
  else
    local action_str
    if [[ -n "$apply_blocked" ]]; then
      action_str="(blocked: $apply_blocked)"
    elif (( prerelease )); then
      action_str="gh release create $version --target $target_local --title '$title' --prerelease --notes-file=..."
    else
      action_str="gh release create $version --target $target_local --title '$title' --notes-file=..."
    fi
    cat <<EOF
Plan:
  version:        $version
  branch:         $target_local ($target_ref)
  title:          $title
  prerelease:     $prerelease
  workflow case:  $workflow_case
EOF
    if (( release_branch_exists )); then
      echo "  release branch: $release_branch_name (exists)"
      if [[ -n "$existing_pr_number" ]]; then
        echo "  existing PR:    #$existing_pr_number ($existing_pr_state) — $existing_pr_url"
      fi
    fi
    if [[ -n "$apply_blocked" ]]; then
      echo "  apply blocked:  $apply_blocked"
      if [[ -n "$suggested_skill" ]]; then
        echo "  suggested:      /$suggested_skill"
      fi
    fi
    echo "  action:         $action_str"
  fi
}

if [[ "$mode" == "plan" ]]; then
  emit_plan
  exit "$EX_OK"
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
if [[ -n "$apply_blocked" ]]; then
  if (( json == 0 )); then
    emit_plan
    echo
  fi
  _die "$EX_AMBIGUOUS" "$apply_blocked"
fi

if (( json == 0 )); then
  emit_plan
  echo
fi

gh_args=(release create "$version" \
  --target "$target_local" \
  --title  "$title" \
  --notes-file "$notes_file")
if (( prerelease )); then
  gh_args+=(--prerelease)
fi

if ! gh_out=$(gh "${gh_args[@]}" 2>&1); then
  _die "$EX_SYSTEM" "gh release create failed: $gh_out"
fi

# `gh release create` prints the release URL on stdout (last line in real gh).
release_url=$(printf '%s' "$gh_out" | tail -n1 | tr -d '[:space:]')

if (( json )); then
  jq -n \
    --arg version       "$version" \
    --arg branch        "$target_local" \
    --arg title         "$title" \
    --arg url           "$release_url" \
    --argjson prerelease "$prerelease" \
    '{
      ok:         true,
      version:    $version,
      branch:     $branch,
      title:      $title,
      prerelease: ($prerelease == 1),
      url:        $url
    }'
else
  cat <<EOF

✓ Release created
  version: $version
  branch:  $target_local
  url:     $release_url
EOF
fi

exit "$EX_OK"
