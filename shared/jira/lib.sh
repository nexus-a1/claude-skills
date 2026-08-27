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
# Appended to the raw profile label when it could not be resolved to a
# hostname, so an opaque "<cloud_id>:<account_id>" is never shown as though it
# were the site's name (CL-49).
readonly SITE_UNRESOLVED=" (unresolved — verify with: acli jira auth status)"

# ---------------------------------------------------------------------------
# Master enable/disable gate
# ---------------------------------------------------------------------------
# Governs whether /jira may call acli AT ALL for this project. Distinct from
# jira_preflight below: preflight checks whether acli technically works
# (installed, authenticated); this checks whether the project has opted in
# in the first place. Default true (opt-out) — unlike jira.write.enabled
# (opt-in), this must not change established behavior for configs written
# before this flag existed. Its purpose is to let a project state "no acli
# here" once, in .claude/configuration.yml, instead of Claude discovering
# that by probing acli on every /jira invocation (CL-23).
#
# Mirrors jira-write.sh's _write_enabled(): same resolve-config.sh sourcing
# chain, same two-line "true/false"+reason echo contract, so a caller can
# tell "explicitly disabled" apart from "couldn't resolve config" if it
# ever needs to. Duplicated rather than shared with _write_enabled because
# the two default oppositely (true vs false) and lib.sh's header already
# documents why read/write control flow is kept apart.
jira_master_enabled() {
  local root self="${BASH_SOURCE[0]}"
  case "$self" in
    */*) root="${self%/*}/.." ;;
    *)   root=".." ;;
  esac
  root="$(cd "$root" 2>/dev/null && pwd)" || root=""

  if ! command -v dirname >/dev/null 2>&1; then
    printf 'true\nno-dirname'
    return 0
  fi

  local result
  result="$(
    set +u
    if [ -n "$root" ] && [ -f "$root/resolve-config.sh" ]; then
      # shellcheck source=../resolve-config.sh
      . "$root/resolve-config.sh" >/dev/null 2>&1
    elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
      . "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" >/dev/null 2>&1
    elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
      . "$HOME/.claude/shared/resolve-config.sh" >/dev/null 2>&1
    fi
    if [ -z "${CONFIG:-}" ] || [ ! -f "$CONFIG" ]; then
      printf 'true\nno-config-file'
    elif ! command -v yq >/dev/null 2>&1; then
      printf 'true\nno-yq'
    else
      # No `// "true"` here: jq/yq's `//` treats a literal `false` value as
      # falsy, same as `null` — `.jira.enabled // "true"` would silently
      # coerce an explicit `enabled: false` back to "true" (the exact
      # pitfall resolve_playwright_scoping_enabled's comment already warns
      # about). Fetch the raw value and test it explicitly instead.
      _v="$(yq -r '.jira.enabled' "$CONFIG" 2>/dev/null)" || { printf 'true\nyq-failed'; exit 0; }
      if [ "$_v" = "false" ]; then
        printf 'false\nresolved-false'
      else
        printf 'true\nresolved-true'
      fi
    fi
  )" || result="true
unresolvable"

  printf '%s' "$result"
}

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
# Resolving the profile LABEL to the site's actual hostname (CL-49)
# ---------------------------------------------------------------------------
# `jira_resolve_site` above returns acli's `current_profile`, which is a LABEL,
# not necessarily a hostname — on a real OAuth profile it is
# "<cloud_id>:<account_id>", an opaque UUID pair. The three helpers below turn
# that label into the profile's actual `site` host, read from acli's own
# config and matched on the identity acli itself keys by, so a hostname is
# never shown for a profile other than the active one.
#
# They live here rather than in jira-write.sh (where CL-44 first wrote them for
# create's browse URL) because the write path needs the hostname in four
# success envelopes and in the pre-write confirmation prompt, not just in one
# URL — ADR-012 addendum 5 recorded the label/host distinction, and CL-49
# recorded that only create was acting on it.
#
# `jira_resolve_site` itself is still deliberately NOT changed: its value is
# the site *label* both scripts display, and changing what it returns would
# change every read result's site field too, which is not this ticket's
# business.

# A dotted, length-bounded hostname and nothing else. The dot is required: a
# profile label like "default" or "work" is hostname-SHAPED but is not a host,
# and https://default/browse/KEY-1 is exactly the wrong link this refuses. The
# 253-byte cap mirrors the 128-byte bound applied to the site label above, so
# an oversized value from the profiles list cannot land unbounded in a result.
jira_is_hostname() {
  local h="$1"
  (( ${#h} >= 1 && ${#h} <= 253 )) || return 1
  [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# A profile's `site` as acli might one day store it. Today it is a bare host,
# but a future release storing "https://acme.atlassian.net/" must not silently
# degrade the result to unresolved — normalise the two decorations that would.
jira_clean_site() {
  local s="$1"
  s="${s#http://}"
  s="${s#https://}"
  s="${s%/}"
  printf '%s' "$s"
}

# The config is consulted FIRST, and a literal host is accepted only when there
# is no config to consult. Order matters here, and getting it backwards is a
# real defect rather than a stylistic one: `current_profile` is a LABEL, and a
# label may be dotted — an installation naming its profile `acme.prod` is
# hostname-SHAPED and would otherwise be handed straight through as a host,
# naming a tenant that does not exist. So the label only becomes a host after
# the profiles list has been given the chance to say what the site actually is.
#
# Echoes nothing when it cannot resolve with certainty. Callers decide what to
# do with that: create omits the URL, the other three verbs and the
# confirmation prompt fall back to the raw label via jira_site_display below.
jira_resolve_site_host() {
  local site="$1"
  local config="${HOME}/.config/acli/jira_config.yaml"

  if [[ -r "$config" ]]; then
    local ident host_candidate host=""
    # One "<cloud_id>:<account_id> <site>" line per profile. The match happens
    # in bash rather than inside the yq program so no caller-supplied value is
    # ever interpolated into the expression. A profile matches on the identity
    # acli itself keys by, or on its own site — some profiles are named after
    # the site they point at, and that is a match, not a coincidence.
    while IFS=' ' read -r ident host_candidate; do
      host_candidate="$(jira_clean_site "$host_candidate")"
      if [[ "$ident" == "$site" || "$host_candidate" == "$(jira_clean_site "$site")" ]]; then
        host="$host_candidate"
        break
      fi
    done < <(yq -r '.profiles[] | ((.cloud_id // "") + ":" + (.account_id // "")) + " " + (.site // "")' "$config" 2>/dev/null || true)

    # A readable config that names no matching profile is not a licence to
    # fall back to the label: it is evidence the label is not a site.
    jira_is_hostname "$host" || return 0
    printf '%s' "$host"
    return 0
  fi

  # No config to consult. A hostname-shaped label is the only thing left, and
  # accepting it here can only widen coverage — there is nothing to contradict.
  local literal
  literal="$(jira_clean_site "$site")"
  jira_is_hostname "$literal" || return 0
  printf '%s' "$literal"
}

# What a human is shown: the hostname when it resolves, otherwise the raw label
# marked as what it is. The label is never silently dropped — a user confirming
# a write has to be able to tell "this is the tenant" from "I could not work out
# which tenant this is", and an unannotated UUID pair reads as neither.
#
# SITE_UNKNOWN is passed through untouched: it already carries its own
# explanation, and appending a second parenthetical to it would say the same
# thing twice.
jira_site_display() {
  local site="$1" host
  [[ "$site" == "$SITE_UNKNOWN" ]] && { printf '%s' "$site"; return 0; }
  host="$(jira_resolve_site_host "$site")"
  if [[ -n "$host" ]]; then
    printf '%s' "$host"
  else
    printf '%s%s' "$site" "$SITE_UNRESOLVED"
  fi
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

# adfToText walks an Atlassian Document Format doc (Jira's rich-text
# description/comment shape) and renders it to plain text. Descriptions and
# comments arrive as either a plain string or an ADF doc depending on the
# ticket's edit history — this covers the ADF case so op_view and
# op_comment_list both stop replacing real content with a placeholder.
#
# Deliberately a SINGLE self-recursive def (adfBlock calling itself for list
# items, table rows/cells, blockquotes, and any unrecognised-but-nested
# type): jq resolves top-level `def`s in dependency order with no forward
# references, so splitting listItem/tableCell handling into separate helper
# defs that call adfBlock (which would need to call them back) does not
# compile — verified directly (`def a: b; def b: a;` fails with
# "b/0 is not defined"). Folding every block-level case into one function
# sidesteps the ordering requirement entirely via ordinary self-recursion.
#
# Unrecognised or malformed shapes resolve to null rather than partial/wrong
# text, so the caller can fall back to the existing RICH_TEXT marker instead
# of rendering something confidently incomplete.
# shellcheck disable=SC2016,SC2034  # jq syntax, not shell expansions; used by scripts that source this file
readonly JQ_ADF_HELPERS='
  def adfText:
    reduce (.marks // [])[] as $m (.text // "";
      if $m.type == "strong" then "**" + . + "**"
      elif $m.type == "em" then "_" + . + "_"
      elif $m.type == "code" then "`" + . + "`"
      elif $m.type == "strike" then "~~" + . + "~~"
      else .
      end);

  # " UNRECOGNIZED " (the sentinel below) marks an inline node type this
  # walker does not know, so adfToText can return null (placeholder) rather
  # than silently dropping that node out of an otherwise-successful
  # transcription. Without this, a doc mixing recognized inline nodes with
  # one unrecognized one would render as PARTIAL text with no signal that
  # anything was dropped. Real ADF text content colliding with this exact
  # padded, all-caps string is not a realistic concern.
  def adfInline:
    if .type == "text" then adfText
    elif .type == "hardBreak" then "\n"
    elif .type == "mention" then ("@" + (.attrs.text // "mention"))
    elif .type == "emoji" then (.attrs.text // .attrs.shortName // "")
    elif .type == "inlineCard" or .type == "blockCard" then (.attrs.url // "")
    elif .type == "date" then (.attrs.timestamp // "")
    elif .type == "status" then (.attrs.text // "")
    else " UNRECOGNIZED "
    end;

  def adfInlineJoin:
    map(adfInline) | join("");

  # depth is an explicit recursion-depth counter, not an ADF field — every
  # self-call increments it and a doc nested past ADF_MAX_DEPTH truncates
  # rather than recursing further. jq 1.7 itself already refuses to PARSE
  # JSON nested past ~50-100 levels ("Exceeds depth limit for parsing"),
  # which already stops this specific stack on an adversarially deep doc
  # before adfBlock ever runs — verified directly. But this plugin ships to
  # unknown environments with an unpinned jq version/implementation (some
  # parse deeper, or without a limit at all), so the depth cap here is
  # defense-in-depth for portability, not a fix for an exploitable crash on
  # any one stack. Caught by the jira.sh:203 try/catch either way, but
  # bailing at a known depth is cheaper and more predictable than trusting a
  # C-stack overflow to surface as a catchable jq error. The "…" truncation
  # marker is a deliberate, separate signal from the " UNRECOGNIZED "
  # sentinel below — depth-capping is an intentional bound on legitimate
  # nested content, not an unrecognized-shape drop, so it does not fall back
  # to the RICH_TEXT placeholder the way an unrecognized node type does.
  def adfBlock(depth):
    # depth is a non-$ function parameter, so jq treats it as a lazily
    # re-evaluated closure — left unbound, checking it at nesting level n
    # would replay a chain of n nested "+1" closures on every call, making
    # the depth check itself O(n) and the whole render O(n^2) in nesting
    # depth. Binding it once up front makes each check O(1) again.
    (depth) as $depth |
    if $depth > 50 then "…"
    elif .type == "paragraph" then ((.content // []) | adfInlineJoin)
    elif .type == "heading" then
      ( ((.attrs.level // 1) as $raw
         # Clamped to the ADF spec 1-6 heading range, not just floored at 1:
         # an attacker-authored level like 1e9 would otherwise make
         # "#" * $lvl build a near-unbounded string with no timeout to
         # catch it (jq here runs unwrapped, unlike every acli call in
         # this domain).
         | (if ($raw|type) == "number" and $raw > 0 then ([$raw, 6] | min) else 1 end)) as $lvl
        | ("#" * $lvl) + " " + ((.content // []) | adfInlineJoin)
      )
    elif .type == "codeBlock" then
      ("```" + (.attrs.language // "") + "\n" + ((.content // []) | map(.text // "") | join("")) + "\n```")
    elif .type == "blockquote" then
      (((.content // []) | map(adfBlock(depth+1)) | join("\n")) | split("\n") | map("> " + .) | join("\n"))
    elif .type == "rule" then "---"
    elif .type == "listItem" then
      ((.content // []) | map(adfBlock(depth+1)) | join("\n"))
    elif .type == "bulletList" then
      ((.content // []) | map("- " + adfBlock(depth+1)) | join("\n"))
    elif .type == "orderedList" then
      ( (.attrs.order // 1) as $start
        | (.content // []) as $items
        | [ range(0; ($items | length)) as $i | (($start + $i | tostring) + ". " + ($items[$i] | adfBlock(depth+1))) ]
        | join("\n")
      )
    elif .type == "tableCell" or .type == "tableHeader" then
      ((.content // []) | map(adfBlock(depth+1)) | join(" "))
    elif .type == "tableRow" then
      ((.content // []) | map(adfBlock(depth+1)) | join(" | "))
    elif .type == "table" then
      ((.content // []) | map(adfBlock(depth+1)) | join("\n"))
    elif .type == "panel" then
      ((.content // []) | map(adfBlock(depth+1)) | join("\n"))
    elif (.type == "mediaSingle" or .type == "mediaGroup" or .type == "media") then "[attachment]"
    else
      # Unrecognized block type. A container (has .content) still recurses
      # into its children so their text is not lost — but a leaf with no
      # .content carries content this walker cannot see, so it sentinels
      # rather than silently rendering "" (see the adfInline sentinel comment
      # above; same AC-5.5 rationale applies to block-level leaves).
      (if (.content? // null) != null then ((.content) | map(adfBlock(depth+1)) | join("\n")) else " UNRECOGNIZED " end)
    end;

  # Only recognized doc-shaped input is walked, and the result is checked
  # for the " UNRECOGNIZED " sentinel before it is trusted: a doc mixing
  # recognized and unrecognized node types must fall back to the RICH_TEXT
  # placeholder as a whole, not render a partial transcription with the
  # unrecognized parts silently missing.
  def adfToText:
    if (type) == "object" and .type == "doc" and ((.content? // null) != null) then
      (([(.content)[] | adfBlock(0)] | join("\n\n")) as $out
       | if ($out == "" or ($out | contains(" UNRECOGNIZED "))) then null else $out end)
    else null
    end;
'
