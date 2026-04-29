#!/usr/bin/env bash
# plugin/shared/release/lib.sh
#
# Shared helpers for the release-management shell library. Sourced by every
# script in plugin/shared/release/. Never executed directly.
#
# Conventions enforced here:
#   - Exit codes: 0 ok, 10 ambiguous-input, 20 user-error, 30 system-error.
#   - Diagnostic output goes to stderr; JSON / structured stdout stays clean.
#   - All version strings carry the leading 'v' (see release-concepts.md).
#
# This file does not run anything on source — it only defines functions and
# exit-code constants. Callers must `set -euo pipefail` themselves.

# Re-source guard: avoid reinitializing if a script sources lib.sh twice.
if [[ -n "${_RELEASE_LIB_SOURCED:-}" ]]; then
  # shellcheck disable=SC2317  # exit 0 is reachable when run directly (not sourced)
  return 0 2>/dev/null || exit 0
fi
_RELEASE_LIB_SOURCED=1

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # constants are used by scripts that source this file
readonly EX_OK=0
# shellcheck disable=SC2034
readonly EX_AMBIGUOUS=10
readonly EX_USER=20
readonly EX_SYSTEM=30

# ---------------------------------------------------------------------------
# Plugin-root resolution
# ---------------------------------------------------------------------------
# Used by scripts to locate sibling helpers (resolve-latest-release.sh).
# Expects the script to set PLUGIN_RELEASE_DIR via:
#   PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# before sourcing lib.sh; this is enforced by _require_release_dir.
_require_release_dir() {
  if [[ -z "${PLUGIN_RELEASE_DIR:-}" || ! -d "$PLUGIN_RELEASE_DIR" ]]; then
    _die "$EX_SYSTEM" "internal: PLUGIN_RELEASE_DIR not set by caller"
  fi
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
_log() {
  printf '%s\n' "$*" >&2
}

# Print message to stderr, exit with given code.
# Usage: _die <exit_code> <message...>
_die() {
  local code="$1"
  shift
  printf '%s\n' "$*" >&2
  exit "$code"
}

# ---------------------------------------------------------------------------
# Repo / git helpers
# ---------------------------------------------------------------------------
_require_git_repo() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _die "$EX_USER" "Not in a git repository (cwd: $(pwd))."
  fi
}

# Echo "1" if ref resolves, "0" otherwise. Always exits 0 to be safe in pipelines.
_ref_exists() {
  local ref="$1"
  if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------
# Normalize a version string: ensure leading 'v', validate semver shape.
# Accepts:
#   v1.2.3
#   1.2.3
#   v1.2.3-rc.1
#   1.2.3-rc.1
# Echoes the normalized version on stdout.
# Returns non-zero (and prints nothing) if the version is malformed.
_normalize_version() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    return 1
  fi
  # Strip leading whitespace.
  raw="${raw#"${raw%%[![:space:]]*}"}"
  # Add v prefix if missing.
  case "$raw" in
    v*|V*) ;;
    *) raw="v$raw" ;;
  esac
  # Validate shape: vMAJOR.MINOR.PATCH with optional -prerelease suffix.
  if [[ ! "$raw" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    return 1
  fi
  printf '%s' "$raw"
}

# Echo the strict-semver core (no prerelease suffix). For "v1.2.3-rc.1" → "v1.2.3".
_version_core() {
  local v="$1"
  printf '%s' "${v%%-*}"
}

# Echo the prerelease suffix portion of a version, including the leading dash.
# For "v1.2.3-rc.1" → "-rc.1". For "v1.2.3" → "" (empty).
_version_prerelease() {
  local v="$1"
  if [[ "$v" == *-* ]]; then
    printf '%s' "-${v#*-}"
  fi
}

# Compute next patch version: v1.2.3 → v1.2.4
_bump_patch() {
  local v core
  v="$(_version_core "$1")"
  core="${v#v}"
  local maj="${core%%.*}"
  local rest="${core#*.}"
  local min="${rest%%.*}"
  local pat="${rest#*.}"
  printf 'v%s.%s.%s' "$maj" "$min" "$((pat + 1))"
}

# Compute next minor version: v1.2.3 → v1.3.0
_bump_minor() {
  local v core
  v="$(_version_core "$1")"
  core="${v#v}"
  local maj="${core%%.*}"
  local rest="${core#*.}"
  local min="${rest%%.*}"
  printf 'v%s.%s.0' "$maj" "$((min + 1))"
}

# Compute next major version: v1.2.3 → v2.0.0
_bump_major() {
  local v core
  v="$(_version_core "$1")"
  core="${v#v}"
  local maj="${core%%.*}"
  printf 'v%s.0.0' "$((maj + 1))"
}

# ---------------------------------------------------------------------------
# Branch / ref normalization
# ---------------------------------------------------------------------------
# Given a branch hint like "master", "main", "origin/master", or
# "release/v1.2.0", echo the first form that resolves locally. Returns
# non-zero if none of the candidates resolve.
_resolve_branch_ref() {
  local hint="$1"
  local candidates=()
  case "$hint" in
    origin/*)
      candidates=("$hint" "${hint#origin/}")
      ;;
    *)
      candidates=("$hint" "origin/$hint")
      ;;
  esac
  local c
  for c in "${candidates[@]}"; do
    if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# Strip the "origin/" prefix from a branch ref if present. Used when passing
# a branch to `gh release create --target` or as a base for `gh pr create`.
_strip_origin_prefix() {
  local ref="$1"
  printf '%s' "${ref#origin/}"
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
# Compose a JSON object from key=value args. Values are passed as-is to jq
# so they must be valid jq value expressions when invoked via _emit_json.
# For convenience use _json_string / _json_array helpers when escaping.
_have_jq() {
  command -v jq >/dev/null 2>&1
}

# Escape a string for embedding in JSON via jq (-R reads raw, -s slurps).
# Echoes a JSON-quoted string.
_json_str() {
  if _have_jq; then
    printf '%s' "$1" | jq -Rs .
  else
    # Fallback: rudimentary escape. Good enough for our controlled inputs.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
  fi
}

# Emit an array literal of strings. Args are individual string elements.
_json_str_array() {
  local first=1
  printf '['
  local x
  for x in "$@"; do
    if (( first )); then
      first=0
    else
      printf ','
    fi
    _json_str "$x"
  done
  printf ']'
}
