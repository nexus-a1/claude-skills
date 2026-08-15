#!/usr/bin/env bash
# plugin/shared/jira/lib.sh
#
# Shared primitives for the Jira domain's two scripts (jira.sh, jira-write.sh).
# Same-domain sourcing only — jira.sh's own header forbids cross-domain
# shared/*/ imports, but two files inside one domain sharing a library is a
# different thing entirely; this file is exactly the "second file" jira.sh's
# original self-location comment anticipated.
#
# Deliberately does NOT contain _run_acli/_project: those are read-path
# control flow built on a trust assumption (rc != 0 -> EX_USER) that the
# write path must not reuse, since rc == 0 on total write failure is now a
# confirmed acli behaviour (see the work item's plan.md, Decision D-2).
# jira-write.sh defines its own runner instead of sourcing this one.
set -euo pipefail

# Re-source guard: avoid a `readonly` re-declaration error if a future
# caller ever sources lib.sh twice in one process (residual risk noted in
# docs/decisions/012-jira-write-verb-contract.md — closed here rather than
# left undefended, matching the existing precedent in
# plugin/shared/release/lib.sh).
if [[ -n "${_JIRA_LIB_SOURCED:-}" ]]; then
  # shellcheck disable=SC2317  # exit 0 is reachable when run directly (not sourced)
  return 0 2>/dev/null || exit 0
fi
_JIRA_LIB_SOURCED=1

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # constants are used by scripts that source this file
readonly EX_OK=0
readonly EX_USER=20
readonly EX_SYSTEM=30
# Write-path only: acli reported success but the mandatory read-back could
# not confirm it, or the response body could not be verified in the first
# place. jira.sh (read-only) never emits this.
# shellcheck disable=SC2034
readonly EX_AMBIGUOUS=40

readonly ACLI_TIMEOUT=10
readonly TIMEOUT_RC=124

# acli's failure text is unverified. Bound every echo of it so a debug or
# proxy error carrying a credential cannot dump unbounded into the session.
readonly ERR_EXCERPT=400

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

_excerpt() {
  [[ -s "$1" ]] || return 0
  head -c "$ERR_EXCERPT" <"$1"
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
# The anchored regex is the SOLE leading-dash defence for callers that cannot
# use a `--` separator (acli's view verb rejects it outright). Full-match only.
jira_validate_key() {
  local key="${1:-}"
  [[ -n "$key" ]] || _die "$EX_USER" "No work item key supplied. Expected form: PROJ-123"
  [[ "$key" != -* ]] || _die "$EX_USER" "Invalid work item key '$key': must not start with '-'."
  [[ "$key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || _die "$EX_USER" \
    "Invalid work item key '$key' — expected form PROJ-123 (uppercase project, hyphen, digits)."
}

readonly SITE_UNKNOWN="(unknown — verify with: acli jira auth status)"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
# All three binaries are hard requirements for both the read and write paths.
# yq is not optional: degrading when it is absent would create a second path
# into the unknown-site state and weaken the signal that exists to stop you
# acting against the wrong tenant. yq is already a plugin-wide dependency.
#
# Shared for the same reason as jira_resolve_site below: jira-write.sh needs
# byte-identical auth/dependency gating, and duplicating it would reproduce
# the drift risk the shared-primitive extraction (D-8/R11) exists to avoid.
jira_preflight() {
  command -v acli >/dev/null 2>&1 || _die "$EX_SYSTEM" \
    "acli not found on PATH.
Install it from https://developer.atlassian.com/cloud/acli/guides/introduction/
then authenticate with: acli jira auth login"

  command -v jq >/dev/null 2>&1 || _die "$EX_SYSTEM" "jq is required but was not found on PATH."
  command -v yq >/dev/null 2>&1 || _die "$EX_SYSTEM" "yq is required but was not found on PATH."

  # Verified: this returns rc=1 when unauthenticated, so it is a trustworthy
  # gate — unlike the write verbs, which return 0 even on total failure.
  local rc=0
  timeout "$ACLI_TIMEOUT" acli jira auth status >/dev/null 2>&1 </dev/null || rc=$?
  if (( rc == TIMEOUT_RC )); then
    _die "$EX_SYSTEM" "Timed out after ${ACLI_TIMEOUT}s contacting Jira. Check your network or try again."
  fi
  if (( rc != 0 )); then
    _die "$EX_USER" \
      "Not authenticated with Jira.
Run: acli jira auth login"
  fi
}

# ---------------------------------------------------------------------------
# Site resolution
# ---------------------------------------------------------------------------
# The active profile is read from acli's own config, scalar only — never the
# profile list or the whole document, whose populated shape is unverified.
# Shared because both jira.sh (read results) and jira-write.sh (confirmation
# prompts and write results) must show it — AC-SEC-1 requires the write
# confirmation to name the site, and duplicating this logic would reproduce
# exactly the drift risk the other shared primitives above were extracted
# to avoid (D-8/R11).
#
# The yq `//` alternative fires on null, NOT on an empty string, and this key
# holds "" when unauthenticated. The bash-side test below is the actual
# control; the `// ""` merely stops yq printing "null".
jira_resolve_site() {
  local config="${HOME}/.config/acli/jira_config.yaml"
  local site=""
  if [[ -r "$config" ]]; then
    site="$(yq -r '.current_profile // ""' "$config" 2>/dev/null || true)"
  fi
  # Shape guard: if the key ever holds a map or multi-line value, yq would
  # emit the subtree into a user-visible field. Only a plain scalar passes.
  [[ "$site" =~ ^[A-Za-z0-9._:/-]{1,128}$ ]] || site="$SITE_UNKNOWN"
  printf '%s' "$site"
}

# ---------------------------------------------------------------------------
# Shared jq helpers
# ---------------------------------------------------------------------------
# scalar/1 collapses the several shapes a Jira field can arrive in — a bare
# string, an object carrying .name or .displayName, null, or an empty string
# — to either a plain string or null. It never lets an object through, which
# is what keeps self-links, ids and icon URLs out of the rendered output.
# shellcheck disable=SC2016,SC2034  # $v/$r are jq variables, not shell expansions; used by scripts that source this file
readonly JQ_HELPERS='
  def scalar($v):
    if $v == null then null
    elif ($v | type) == "object" then ($v.name // $v.displayName // null)
    elif ($v | type) == "string" then (if $v == "" then null else $v end)
    elif ($v | type) == "array" then null
    else ($v | tostring) end;
  def orNone($v): if $v == null then "none" else $v end;
'
