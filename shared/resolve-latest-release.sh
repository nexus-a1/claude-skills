#!/usr/bin/env bash
# Deterministic "latest release" resolver for release-management skills.
#
# Implements the rules in plugin/shared/release-concepts.md:
#   - Compare newest tag `vX.Y.Z` against newest branch `release/vX.Y.Z`
#   - Whichever has the higher semver wins; ties go to the tag
#   - If only one exists, it wins; if neither, result is `none`
#
# Usage:
#   source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-latest-release.sh"
#   resolve_latest_release
#
# Output (single line, space-separated):
#   <kind> <ref> <version>
#     kind    = tag | branch | none
#     ref     = v3.5.0 | release/v3.6.0 | -
#     version = 3.5.0  | 3.6.0          | 0.0.0

# Strip leading v/V from a version string. "v3.5.0" -> "3.5.0"
_rl_strip_v() {
  local s="$1"
  echo "${s#[vV]}"
}

# Print the higher of two semver strings (X.Y.Z). Ties print $1.
_rl_semver_max() {
  local a="$1" b="$2"
  if [[ -z "$a" ]]; then echo "$b"; return; fi
  if [[ -z "$b" ]]; then echo "$a"; return; fi
  # sort -V is version-aware; ascending sort, last line is the max
  printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1
}

# Resolve the newest tag of the form vX.Y.Z. Echoes "vX.Y.Z" or empty.
# RC/pre-release tags (anything with a suffix like -rc.1, -beta.2) are excluded —
# they are not "real" tags for latest-release resolution.
_rl_latest_tag() {
  git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname 2>/dev/null \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -n1
}

# Resolve the newest branch of the form release/vX.Y.Z (local + remote).
# Echoes "release/vX.Y.Z" or empty. Branches with pre-release suffixes are excluded.
_rl_latest_branch() {
  local refs
  refs=$(git for-each-ref \
    --format='%(refname:short)' \
    --sort=-v:refname \
    'refs/heads/release/v[0-9]*.[0-9]*.[0-9]*' \
    'refs/remotes/origin/release/v[0-9]*.[0-9]*.[0-9]*' \
    2>/dev/null)

  # Strip "origin/" prefix so local and remote refs dedupe on branch name,
  # then keep only strict release/vN.N.N (exclude pre-release suffixes).
  echo "$refs" \
    | sed 's#^origin/##' \
    | grep -E '^release/v[0-9]+\.[0-9]+\.[0-9]+$' \
    | awk 'NF && !seen[$0]++' \
    | head -n1
}

resolve_latest_release() {
  local tag branch tag_ver branch_ver

  tag=$(_rl_latest_tag)
  branch=$(_rl_latest_branch)

  tag_ver=$(_rl_strip_v "$tag")
  branch_ver=$(_rl_strip_v "${branch#release/}")

  if [[ -z "$tag" && -z "$branch" ]]; then
    echo "none - 0.0.0"
    return 0
  fi

  if [[ -z "$branch" ]]; then
    echo "tag $tag $tag_ver"
    return 0
  fi

  if [[ -z "$tag" ]]; then
    echo "branch $branch $branch_ver"
    return 0
  fi

  # Both exist — compare. Tie goes to the tag.
  local winner
  winner=$(_rl_semver_max "$tag_ver" "$branch_ver")

  if [[ "$winner" == "$tag_ver" ]]; then
    echo "tag $tag $tag_ver"
  else
    echo "branch $branch $branch_ver"
  fi
}

# Run directly when invoked as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_latest_release
fi
