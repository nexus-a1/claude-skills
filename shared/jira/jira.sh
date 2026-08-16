#!/usr/bin/env bash
# plugin/shared/jira/jira.sh
#
# Read-only Jira work item access via the Atlassian CLI (acli).
# Invoked flag-first by plugin/skills/jira/SKILL.md:
#
#   jira.sh --op view         --key KEY-123
#   jira.sh --op comment-list --key KEY-123 [--limit N]
#
# Flag-first matters: plugin/settings.json matches on the resolved command
# line, and a bare subcommand word after the script name matches no glob.
#
# Conventions (mirrors plugin/shared/release/lib.sh, deliberately NOT sourced
# from it — there is no shared import path across shared/*/ in a marketplace
# install, and cross-domain coupling is the wrong dependency direction):
#   - Exit codes: 0 ok, 20 user-error, 30 system-error.
#   - Diagnostic output goes to stderr; structured JSON on stdout stays clean.
#
# acli-specific hardening that release/lib.sh does NOT need:
#   - Streams are captured SEPARATELY. acli prints per-item failures on
#     *stdout*, so merging streams would poison the structured channel.
#   - Every acli invocation is an argv array, never a concatenated string,
#     and runs under `timeout` with stdin closed.
#
# Self-located via parameter expansion (`${BASH_SOURCE[0]%/*}`), not `dirname`
# — dirname is an external binary, and calling it before the dependency
# preflight makes a restricted PATH emit a "command not found" line ahead of
# the real message, which reads like a crash. This is the second file the
# original version of this comment anticipated: shared primitives (exit
# codes, _die/_log, jira_validate_key, JQ_HELPERS) now live in lib.sh,
# sourced below. Same-domain sourcing, not the cross-domain shared/*/
# coupling forbidden above — see lib.sh's own header.
#
# Verified against acli 1.3.22-stable. See the work item's plan.md for the
# full interface contract.
set -euo pipefail

JIRA_LIB_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=./lib.sh
source "$JIRA_LIB_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Read-path-only constants
# ---------------------------------------------------------------------------
# 10 is reserved (ambiguous input) — unused in read-only v1. Exit codes 0,
# 20, 30 and 40 (write-path "may or may not have completed") live in lib.sh.
readonly LIMIT_MIN=1
readonly LIMIT_MAX=200
readonly LIMIT_DEFAULT=20

# Local CPU-bound bound for _project's jq call, distinct from ACLI_TIMEOUT
# (network). Generous relative to real ADF trees (which render in
# milliseconds) but bounds the pathological case a wide-but-shallow (or
# otherwise slow-to-evaluate) ADF tree walked by adfBlock (lib.sh) could
# otherwise hit — complementary to adfBlock's own depth cap, which bounds
# deep nesting specifically.
readonly JQ_TIMEOUT=10

# acli's own default omits priority and labels, both of which the spec
# requires, so the list is always explicit.
readonly VIEW_FIELDS="key,issuetype,summary,status,assignee,description,priority,labels"

# Fallback only (CL-20, extended to comments by CL-21): both op_view's
# description and op_comment_list's body render ADF via adfToText
# (JQ_ADF_HELPERS, lib.sh). This fires for shapes adfToText can't make
# sense of — malformed docs, empty content, a future ADF node type, or a
# doc that mixes recognized and unrecognized node types (adfToText returns
# null in that last case rather than a partial transcription) — so an
# unparseable field degrades to a marker instead of silently rendering
# blank or wrong text.
readonly RICH_TEXT="(rich-text content — not rendered here)"

# ---------------------------------------------------------------------------
# Temp files and cleanup
# ---------------------------------------------------------------------------
# Captured acli output holds full ticket bodies, which may contain customer
# names, incident detail, or secrets someone pasted into a ticket. A RETURN
# trap does NOT fire when _die calls exit, so cleanup is registered once at
# top level on EXIT, which covers every path including error exits.
OUT_F=""
ERR_F=""
JQ_ERR_F=""

_cleanup() {
  [[ -n "$OUT_F"    ]] && rm -f "$OUT_F"
  [[ -n "$ERR_F"    ]] && rm -f "$ERR_F"
  [[ -n "$JQ_ERR_F" ]] && rm -f "$JQ_ERR_F"
  return 0
}
trap _cleanup EXIT

# _log, _die, _excerpt now live in lib.sh (sourced above).

_usage() {
  cat >&2 <<'USAGE'
Usage:
  jira.sh --op view         --key KEY-123
  jira.sh --op comment-list --key KEY-123 [--limit N]

Read-only. Supported operations: view, comment-list.
USAGE
}

# jira_preflight now lives in lib.sh (sourced above) — shared with
# jira-write.sh, which needs byte-identical dependency/auth gating.

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
# jira_validate_key now lives in lib.sh (sourced above) — shared with
# jira-write.sh. jira_validate_limit stays here: it's read-path only,
# nothing in the write path paginates.

# Echoes the normalized limit. Leading zeros are stripped before any
# arithmetic: bash reads 010 as octal 8, and the raw string would also be
# invalid JSON when handed to jq.
jira_validate_limit() {
  local limit="${1:-}"
  [[ "$limit" =~ ^[0-9]+$ ]] || _die "$EX_USER" "Invalid --limit '$limit': must be a whole number."
  local n=$((10#$limit))
  (( n >= LIMIT_MIN && n <= LIMIT_MAX )) || _die "$EX_USER" \
    "Invalid --limit '$limit': must be between $LIMIT_MIN and $LIMIT_MAX."
  printf '%s' "$n"
}

# jira_resolve_site now lives in lib.sh (sourced above) — shared with
# jira-write.sh, which must show the site on every confirmation and result.

# ---------------------------------------------------------------------------
# acli invocation
# ---------------------------------------------------------------------------
# Runs acli with the given argv, capturing stdout and stderr to SEPARATE
# files. Distinguishes timeout from ordinary failure — conflating them
# reports a network stall as "the item does not exist", which is both the
# wrong cause and the wrong error class.
_run_acli() {
  local what="$1"; shift
  local rc=0
  timeout "$ACLI_TIMEOUT" acli "$@" >"$OUT_F" 2>"$ERR_F" </dev/null || rc=$?

  if (( rc == TIMEOUT_RC )); then
    _die "$EX_SYSTEM" "Timed out after ${ACLI_TIMEOUT}s reading $what. Check your network or try again."
  fi
  if (( rc != 0 )); then
    _log "$(_excerpt "$ERR_F")"
    _die "$EX_USER" \
      "Could not read $what.
Either the work item does not exist, or your account lacks Browse permission
on that project. acli reports these identically and cannot distinguish them."
  fi
  # A zero exit with no output is not success. Without this the jq program
  # below never runs, jq exits 0, and an empty result renders as fact.
  [[ -s "$OUT_F" ]] || _die "$EX_SYSTEM" \
    "acli returned no output for $what despite reporting success.
This usually means acli's behaviour changed."
}

# Runs a jq program over the captured stdout. jq's own stderr is preserved
# and surfaced: a parse failure, a type error, and a deliberate
# error(\"missing-required\") are three different problems, and collapsing
# them into one message makes the diagnostic actively misleading.
#
# Timeout-wrapped the same way _run_acli wraps its own acli call (see
# above) — added alongside the ADF walker (adfBlock/adfToText in lib.sh's
# JQ_ADF_HELPERS), which recurses into ticket-author-controlled content.
# adfBlock has its own explicit depth cap (defense-in-depth for jq
# implementations without one), but this wall-clock timeout is a
# complementary, general guard against any pathologically slow jq
# evaluation — wide-but-shallow trees the depth cap would not catch —
# so a malicious or malformed response cannot hang this call indefinitely
# where every other step in the read path is already bounded.
_project() {
  local what="$1"; shift
  local rc=0
  timeout "$JQ_TIMEOUT" jq "$@" <"$OUT_F" 2>"$JQ_ERR_F" || rc=$?
  if (( rc == TIMEOUT_RC )); then
    _die "$EX_SYSTEM" "Timed out after ${JQ_TIMEOUT}s projecting $what. The response may contain pathologically nested content."
  fi
  if (( rc != 0 )); then
    _die "$EX_SYSTEM" \
      "Unexpected acli output for $what — the response could not be interpreted.
acli's response format may have changed.
jq: $(_excerpt "$JQ_ERR_F")
Received: $(_excerpt "$OUT_F")"
  fi
}

# JQ_HELPERS (scalar/orNone) now lives in lib.sh (sourced above).

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------
# The two read verbs take their key DIFFERENTLY. This is not a typo:
#   view          — positional key; the --key flag is rejected outright
#   comment list  — --key flag
op_view() {
  local key="$1" site="$2"

  _run_acli "$key" jira workitem view "$key" --json --fields "$VIEW_FIELDS"

  # Tolerates both a REST-style envelope (fields nested under .fields) and a
  # flattened one, since which acli emits is unverified. Required fields are
  # summary and status; their absence from BOTH shapes is a hard failure.
  # Optional fields are legitimately absent on real tickets — an unassigned
  # item has a null assignee — so they render a marker instead.
  _project "$key" --arg site "$site" --arg key "$key" "
    $JQ_HELPERS
    $JQ_ADF_HELPERS
    . as \$r
    | (if (\$r.fields | type) == \"object\" then \$r.fields else {} end) as \$f
    | (scalar(\$f.summary) // scalar(\$r.summary)) as \$summary
    | (scalar(\$f.status)  // scalar(\$r.status))  as \$status
    | if \$summary == null or \$status == null then error(\"missing-required\") else . end
    | (\$f.description // \$r.description) as \$desc
    | {
        key:      (scalar(\$f.key) // scalar(\$r.key) // \$key),
        type:     orNone(scalar(\$f.issuetype) // scalar(\$r.issuetype)),
        summary:  \$summary,
        status:   \$status,
        assignee: orNone(scalar(\$f.assignee) // scalar(\$r.assignee)),
        priority: orNone(scalar(\$f.priority) // scalar(\$r.priority)),
        labels:   ((if (\$f.labels | type) == \"array\" then \$f.labels
                    elif (\$r.labels | type) == \"array\" then \$r.labels
                    else [] end) | map(tostring)),
        description: (if \$desc == null then \"none\"
                      elif (\$desc | type) == \"string\" then (if \$desc == \"\" then \"none\" else \$desc end)
                      else (try (\$desc | adfToText) catch null) // \"$RICH_TEXT\" end),
        site: \$site
      }
  "
}

op_comment_list() {
  local key="$1" limit="$2" site="$3"

  # Newest-first, bounded. The equals form keeps the flag parser from reading
  # the dash-leading value as another flag. No all-pages flag is used: it
  # overrides the limit and would pull an entire comment history.
  _run_acli "comments for $key" jira workitem comment list \
    --key "$key" --json "--order=-created" --limit "$limit"

  # The array must be LOCATED, not defaulted. Coercing an unrecognised
  # envelope to [] would report "this ticket has no comments" as fact —
  # a wrong answer presented confidently, which is worse than failing.
  # shellcheck disable=SC2016  # $c/$page/$site are jq variables, not shell expansions
  _project "comments for $key" --arg site "$site" --arg key "$key" --argjson limit "$limit" "
    $JQ_HELPERS
    $JQ_ADF_HELPERS
    (.comments // .values // .results // (if type == \"array\" then . else null end)) as \$c
    | if (\$c | type) != \"array\" then error(\"missing-required\") else . end
    | (\$c[:\$limit]) as \$page
    | {
        key: \$key,
        site: \$site,
        shown: (\$page | length),
        comments: [ \$page[] | {
          id:      (orNone(scalar(.id))),
          author:  (orNone(scalar(.author) // scalar(.updateAuthor))),
          created: (orNone(scalar(.created) // scalar(.createdAt))),
          body:    ((.body // .renderedBody) as \$b
                    | if \$b == null then \"\"
                      elif (\$b | type) == \"string\" then \$b
                      else (try (\$b | adfToText) catch null) // \"$RICH_TEXT\" end)
        } ]
      }
  "
}

# ---------------------------------------------------------------------------
# Argument parsing (flag-first)
# ---------------------------------------------------------------------------
# Each value-taking flag checks for its value explicitly. `shift 2` with only
# one argument left returns non-zero, and under `set -e` that kills the script
# silently with exit 1 — outside the documented 0/20/30 contract and with no
# message for the caller to surface.
_need_value() {
  (( $1 >= 2 )) || _die "$EX_USER" "$2 requires a value."
}

main() {
  local op="" key="" limit="$LIMIT_DEFAULT"

  while (( $# > 0 )); do
    case "$1" in
      --op=*)    op="${1#--op=}";        shift ;;
      --op)      _need_value $# "--op";    op="$2";    shift 2 ;;
      --key=*)   key="${1#--key=}";      shift ;;
      --key)     _need_value $# "--key";   key="$2";   shift 2 ;;
      --limit=*) limit="${1#--limit=}";  shift ;;
      --limit)   _need_value $# "--limit"; limit="$2"; shift 2 ;;
      -h|--help) _usage; exit "$EX_OK" ;;
      *) _usage; _die "$EX_USER" "jira.sh: unknown argument '$1'" ;;
    esac
  done

  if [[ -z "$op" ]]; then
    _usage
    _die "$EX_USER" "No operation supplied. Use --op view or --op comment-list."
  fi

  case "$op" in
    view|comment-list) ;;
    *) _usage; _die "$EX_USER" "Unsupported operation '$op'. Supported: view, comment-list." ;;
  esac

  jira_validate_key "$key"
  limit="$(jira_validate_limit "$limit")"

  local _master_state
  _master_state="$(jira_master_enabled)"
  if [[ "${_master_state%%$'\n'*}" == "false" ]]; then
    _die "$EX_USER" \
      "Jira integration is disabled for this project (jira.enabled: false in .claude/configuration.yml).
Run /configuration-init to re-enable it, or edit the config directly."
  fi

  jira_preflight

  OUT_F="$(mktemp)"; ERR_F="$(mktemp)"; JQ_ERR_F="$(mktemp)"

  local site
  site="$(jira_resolve_site)"

  case "$op" in
    view)         op_view "$key" "$site" ;;
    comment-list) op_comment_list "$key" "$limit" "$site" ;;
  esac
}

main "$@"
