#!/usr/bin/env bash
# plugin/shared/release/pr-create.sh
#
# Action script for /create-release.
#
# Validates target+release branches, optionally pushes the release branch,
# then opens a PR with `gh pr create`. The PR body is supplied by the
# caller via --body-file (the skill prompt is responsible for authoring it
# from commits-data.sh JSON), and the title defaults to "Release <version>".
#
# Usage:
#   bash pr-create.sh --target=<branch> --release-branch=<release/vX.Y.Z>
#                     --body-file=<path>
#                     [--title=<...>] [--label=<release>]
#                     (--plan|--apply) [--update-existing] [--json]
#
# Modes:
#   --plan   Validate, emit a plan; do not push or create.
#   --apply  Push release branch (if needed), gh pr create. If a PR for the
#            head branch already exists and --update-existing is set, edit
#            its body+title in place; otherwise refuse with EX_USER.
#
# The skill must call record-audit.sh immediately before --apply because
# this script issues `git push`.
#
# Exit codes:
#   0  EX_OK         — success / plan validated
#   10 EX_AMBIGUOUS  — existing PR found and --update-existing not set
#   20 EX_USER       — branch missing, no commits to release, etc.
#   30 EX_SYSTEM     — git/gh failure
set -euo pipefail

PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PLUGIN_RELEASE_DIR/lib.sh"

target=""
release_branch=""
body_file=""
title=""
label="release"
mode=""
update_existing=0
json=0

while (( $# > 0 )); do
  case "$1" in
    --target=*)         target="${1#--target=}"; shift ;;
    --target)           target="${2:-}"; shift 2 ;;
    --release-branch=*) release_branch="${1#--release-branch=}"; shift ;;
    --release-branch)   release_branch="${2:-}"; shift 2 ;;
    --body-file=*)      body_file="${1#--body-file=}"; shift ;;
    --body-file)        body_file="${2:-}"; shift 2 ;;
    --title=*)          title="${1#--title=}"; shift ;;
    --title)            title="${2:-}"; shift 2 ;;
    --label=*)          label="${1#--label=}"; shift ;;
    --label)            label="${2:-}"; shift 2 ;;
    --plan)             mode="plan"; shift ;;
    --apply)            mode="apply"; shift ;;
    --update-existing)  update_existing=1; shift ;;
    --json)             json=1; shift ;;
    *) _die "$EX_SYSTEM" "pr-create.sh: unknown arg '$1'" ;;
  esac
done

[[ -z "$target" ]]         && _die "$EX_USER" "pr-create.sh: --target is required"
[[ -z "$release_branch" ]] && _die "$EX_USER" "pr-create.sh: --release-branch is required"
[[ -z "$mode" ]]           && _die "$EX_USER" "pr-create.sh: --plan or --apply is required"
if [[ "$mode" == "apply" && -z "$body_file" ]]; then
  _die "$EX_USER" "pr-create.sh: --body-file is required for --apply"
fi
if [[ -n "$body_file" && ! -f "$body_file" ]]; then
  _die "$EX_USER" "pr-create.sh: --body-file '$body_file' does not exist"
fi

# Defensive: reject leading-dash inputs.
for v in "$target" "$release_branch" "$label"; do
  if [[ "$v" == -* ]]; then
    _die "$EX_USER" "Invalid argument: '$v' must not start with '-'"
  fi
done

_require_git_repo
if ! command -v gh >/dev/null 2>&1; then
  _die "$EX_SYSTEM" "pr-create.sh: gh CLI not found on PATH"
fi
if ! _have_jq; then
  _die "$EX_SYSTEM" "pr-create.sh: jq is required"
fi

# Default title.
if [[ -z "$title" ]]; then
  # Strip "release/" prefix to derive the version label.
  version_label="${release_branch#release/}"
  title="Release $version_label"
fi

# ---------------------------------------------------------------------------
# Fetch target branch so commit range reflects current upstream state
# ---------------------------------------------------------------------------
git fetch -q origin "$target" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Resolve target ref
# ---------------------------------------------------------------------------
if ! target_ref=$(_resolve_branch_ref "$target"); then
  _die "$EX_USER" "Target branch '$target' not found locally or on origin"
fi
target_local=$(_strip_origin_prefix "$target_ref")

# ---------------------------------------------------------------------------
# Resolve release branch (must exist somewhere — local or remote)
# ---------------------------------------------------------------------------
release_local_exists=0
release_remote_exists=0
if [[ "$(_ref_exists "$release_branch")" == "1" ]]; then
  release_local_exists=1
fi
if [[ "$(_ref_exists "origin/$release_branch")" == "1" ]]; then
  release_remote_exists=1
fi

if (( release_local_exists == 0 && release_remote_exists == 0 )); then
  _die "$EX_USER" "Release branch '$release_branch' does not exist locally or on origin (run /create-release-branch first)"
fi

# Pick a usable ref to compute commit count from.
if (( release_local_exists )); then
  release_ref="$release_branch"
else
  release_ref="origin/$release_branch"
fi

# Count commits between target and release.
if ! commit_count=$(git rev-list --count "${target_ref}..${release_ref}" 2>&1); then
  _die "$EX_SYSTEM" "git rev-list failed for ${target_ref}..${release_ref}: $commit_count"
fi

# ---------------------------------------------------------------------------
# Check for existing PR for this head branch
# ---------------------------------------------------------------------------
existing_pr_json=""
existing_pr_state=""
existing_pr_number=""
existing_pr_url=""
if existing_list=$(gh pr list --head "$release_branch" --state all \
      --json number,state,title,url --limit 5 2>&1); then
  open_count=$(printf '%s' "$existing_list" | jq '[.[] | select(.state == "OPEN")] | length')
  if [[ "$open_count" != "0" ]]; then
    existing_pr_json=$(printf '%s' "$existing_list" | jq '[.[] | select(.state == "OPEN")] | .[0]')
    existing_pr_state="OPEN"
    existing_pr_number=$(printf '%s' "$existing_pr_json" | jq -r '.number')
    existing_pr_url=$(printf '%s' "$existing_pr_json" | jq -r '.url')
  fi
else
  _log "warning: gh pr list failed: $existing_list"
fi

# ---------------------------------------------------------------------------
# Plan output
# ---------------------------------------------------------------------------
emit_plan() {
  # Derived booleans replace the rendered command-string list. The skill
  # prompt has every field it needs (target, release_branch, existing_pr,
  # commit_count) to phrase the plan; shipping the literal `gh pr create
  # --base ... --head ...` strings to the LLM was duplication.
  local will_push_branch="false"
  local will_update_existing="false"
  local will_refuse_existing="false"
  if (( release_remote_exists == 0 )); then
    will_push_branch="true"
  fi
  if [[ -n "$existing_pr_number" ]]; then
    if (( update_existing )); then
      will_update_existing="true"
    else
      will_refuse_existing="true"
    fi
  fi

  if (( json )); then
    jq -n \
      --arg     target               "$target_local" \
      --arg     release_branch       "$release_branch" \
      --arg     title                "$title" \
      --arg     label                "$label" \
      --arg     existing_state       "$existing_pr_state" \
      --arg     existing_number      "$existing_pr_number" \
      --arg     existing_url         "$existing_pr_url" \
      --argjson commit_count         "$commit_count" \
      --arg     mode                 "$mode" \
      --arg     will_push_branch     "$will_push_branch" \
      --arg     will_update_existing "$will_update_existing" \
      --arg     will_refuse_existing "$will_refuse_existing" \
      '{
        mode:           $mode,
        target:         $target,
        release_branch: $release_branch,
        title:          $title,
        label:          $label,
        commit_count:   $commit_count,
        existing_pr: {
          state:  (if $existing_state  == "" then null else $existing_state  end),
          number: (if $existing_number == "" then null else ($existing_number | tonumber) end),
          url:    (if $existing_url    == "" then null else $existing_url    end)
        },
        will_push_branch:     ($will_push_branch     == "true"),
        will_update_existing: ($will_update_existing == "true"),
        will_refuse_existing: ($will_refuse_existing == "true")
      }'
  else
    local actions_arr=()
    if (( release_local_exists == 0 )); then
      actions_arr+=("checkout local release branch from origin/$release_branch")
    fi
    if [[ "$will_push_branch" == "true" ]]; then
      actions_arr+=("git push -u origin $release_branch")
    fi
    if [[ "$will_update_existing" == "true" ]]; then
      actions_arr+=("gh pr edit $existing_pr_number --title=... --body-file=...")
    elif [[ "$will_refuse_existing" == "true" ]]; then
      actions_arr+=("(would refuse — PR #$existing_pr_number already open; pass --update-existing to update)")
    else
      actions_arr+=("gh pr create --base $target_local --head $release_branch --title='$title' --label=$label --body-file=...")
    fi
    cat <<EOF
Plan:
  target:           $target_local
  release branch:   $release_branch
  title:            $title
  label:            $label
  commits:          $commit_count
EOF
    if [[ -n "$existing_pr_number" ]]; then
      echo "  existing PR:      #$existing_pr_number ($existing_pr_state) — $existing_pr_url"
    fi
    echo "  actions:"
    printf '    - %s\n' "${actions_arr[@]+"${actions_arr[@]}"}"
  fi
}

if [[ "$mode" == "plan" ]]; then
  emit_plan
  exit "$EX_OK"
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
if [[ "$commit_count" == "0" && -z "$existing_pr_number" ]]; then
  _die "$EX_USER" "No commits between '$target_local' and '$release_branch' — nothing to release"
fi

if [[ -n "$existing_pr_number" && $update_existing -eq 0 ]]; then
  _die "$EX_AMBIGUOUS" "PR #$existing_pr_number is already open for $release_branch ($existing_pr_url) — pass --update-existing to update"
fi

# Only print the plan when emitting human-readable output; in --json mode the
# stdout must be a single JSON document (the success object below). Mirrors
# release-create.sh.
if (( json == 0 )); then
  emit_plan
  echo
fi

# Step 1 — make sure local branch exists. Capture output so it doesn't bleed
# into stdout in --json mode.
if (( release_local_exists == 0 )); then
  if ! checkout_out=$(git checkout -q -b "$release_branch" "origin/$release_branch" 2>&1); then
    _die "$EX_SYSTEM" "Failed to check out local '$release_branch' from origin: $checkout_out"
  fi
fi

# Step 2 — push to origin if missing.
if (( release_remote_exists == 0 )); then
  if ! push_out=$(git push -u origin "$release_branch" 2>&1); then
    _die "$EX_SYSTEM" "Failed to push '$release_branch' to origin: $push_out"
  fi
fi

# Step 3 — create or update PR.
result_url=""
if [[ -n "$existing_pr_number" ]]; then
  if ! gh_out=$(gh pr edit "$existing_pr_number" \
        --title "$title" --body-file "$body_file" 2>&1); then
    _die "$EX_SYSTEM" "gh pr edit failed: $gh_out"
  fi
  result_url="$existing_pr_url"
  pr_number="$existing_pr_number"
  action="updated"
else
  if ! gh_out=$(gh pr create \
        --base "$target_local" --head "$release_branch" \
        --title "$title" --label "$label" --body-file "$body_file" 2>&1); then
    _die "$EX_SYSTEM" "gh pr create failed: $gh_out"
  fi
  # gh pr create prints the URL on the last line of stdout.
  result_url=$(printf '%s' "$gh_out" | tail -n1 | tr -d '[:space:]')
  pr_number="${result_url##*/}"
  action="created"
fi

if (( json )); then
  jq -n \
    --arg url    "$result_url" \
    --arg number "$pr_number" \
    --arg action "$action" \
    --arg target "$target_local" \
    --arg head   "$release_branch" \
    --arg title  "$title" \
    '{
      ok: true,
      action: $action,
      pr: {
        number: ($number | tonumber? // null),
        url:    $url,
        title:  $title,
        base:   $target,
        head:   $head
      }
    }'
else
  cat <<EOF

✓ PR $action
  number: $pr_number
  url:    $result_url
  $release_branch → $target_local
EOF
fi

exit "$EX_OK"
