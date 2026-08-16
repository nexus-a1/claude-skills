#!/usr/bin/env bash
# plugin/shared/jira/jira-write.sh
#
# Write access to Jira work items via the Atlassian CLI (acli): comment,
# transition, and assign. Invoked flag-first by plugin/skills/jira/SKILL.md
# Step 2b, ONLY after an AskUserQuestion confirmation:
#
#   jira-write.sh --op comment-create --key KEY-123 --body TEXT --confirmed
#   jira-write.sh --op transition     --key KEY-123 --status NAME --confirmed
#   jira-write.sh --op assign         --key KEY-123 --assignee VALUE --confirmed
#   jira-write.sh --op assign         --key KEY-123 --remove-assignee --confirmed
#
# `create` (a new work item) is deliberately NOT implemented here — its
# success-response shape was never captured live (the ticket owner scoped
# Wave-0 verification to reusing an existing disposable item, not creating a
# new one). It is split to a follow-up ticket. See
# docs/decisions/012-jira-write-verb-contract.md.
#
# This file exists SEPARATELY from jira.sh so the read path's structural
# guarantees (tests/jira/03-invocation-contract.test's source-grep
# assertions) never have to be weakened to accommodate write verbs. It
# shares plugin/shared/jira/lib.sh with jira.sh for validation, exit codes,
# and diagnostics — same-domain sourcing, not the cross-domain shared/*/
# coupling jira.sh's own header forbids elsewhere.
#
# The core guarantee: a reported success is a VERIFIED success. acli returns
# exit code 0 even when a write totally fails (confirmed live, see the
# contract doc above) — this file NEVER trusts rc for success. It gates on
# the response body's results[0].status + successCount == totalCount == 1,
# and every op re-reads the affected field afterward as the real authority.
# Any response this file cannot fully verify reports the ambiguous EX_AMBIGUOUS
# state, never a false success or a false failure.
#
# Verified against acli 1.3.22-stable, live, on 2026-08-15. See
# docs/decisions/012-jira-write-verb-contract.md for the exact captured
# payloads this file's success gate is built on.
set -euo pipefail

JIRA_LIB_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=./lib.sh
source "$JIRA_LIB_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Temp files and cleanup
# ---------------------------------------------------------------------------
# Same rationale as jira.sh: a RETURN trap does not fire when _die calls
# exit, so cleanup is registered once at top level on EXIT.
OUT_F=""
ERR_F=""

# Set by main() once past every gate, right before dispatching to an op —
# never for an early usage/validation/config-disabled exit, since those are
# refusals, not write ATTEMPTS (AC-SEC-5's own wording). Read by the audit
# trap below; empty AUDIT_ACTION means "no write was attempted this run."
AUDIT_ACTION=""
AUDIT_KEY=""
AUDIT_SITE=""

_cleanup() {
  [[ -n "$OUT_F" ]] && rm -f "$OUT_F"
  [[ -n "$ERR_F" ]] && rm -f "$ERR_F"
  return 0
}

# ---------------------------------------------------------------------------
# Write-audit record (AC-SEC-5)
# ---------------------------------------------------------------------------
# Wired generically here in the EXIT trap — not inside any one op function —
# so every current and future op (transition, assign, ...) gets audit
# coverage automatically from the moment it sets AUDIT_ACTION/KEY/SITE and
# calls the shared runner, with no separate per-op task required.
#
# Never contains ticket body text (AC-SEC-5) — only action/key/site/outcome.
# Appended, not overwritten: a JSONL line per attempt, so two concurrent
# /jira write sessions cannot lose each other's record via a read-modify-
# write race (a known, documented limitation: concurrent-append interleaving
# itself is not tested — see the ADR's residual-risk section).
#
# Path precedent: plugin/hooks/record-audit.sh already writes to
# .claude/session-state/ relative to the git root; mirrored here rather than
# inventing a second resolution mechanism.
_audit_write() {
  local rc=$?
  [[ -n "$AUDIT_ACTION" ]] || return 0

  # success/failure are both VERIFIED outcomes (a Jira rejection is just as
  # confirmed as a success); ambiguous/error are the two unverifiable states.
  local outcome
  case "$rc" in
    0)  outcome="success"   ;;
    20) outcome="failure"   ;;
    40) outcome="ambiguous" ;;
    *)  outcome="error"     ;;
  esac

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root="$PWD"
  local audit_dir="$repo_root/.claude/session-state"
  # A lost audit record must never turn a verified write into an error — the
  # write's own outcome (already printed/returned) stands regardless. But
  # AC-SEC-5 requires a record for every attempt, so a failure to produce
  # one is surfaced loudly (stderr), never swallowed silently.
  if ! mkdir -p "$audit_dir" 2>/dev/null; then
    # `|| true`: this runs inside the EXIT trap under `set -e`. If stderr
    # itself is unwritable (closed fd, EPIPE, full disk), a failing _log
    # here must not change the write's own already-decided exit code.
    _log "WARNING: could not create $audit_dir — this write's audit record was not persisted (AC-SEC-5)." || true
    return 0
  fi
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || ts="unknown"

  if ! jq -nc \
    --arg action "$AUDIT_ACTION" --arg key "$AUDIT_KEY" --arg site "$AUDIT_SITE" \
    --arg ts "$ts" --arg outcome "$outcome" \
    '{action:$action, key:$key, site:$site, timestamp:$ts, confirmed:true, outcome:$outcome, verified:($outcome=="success" or $outcome=="failure")}' \
    >> "$audit_dir/jira-write-audit.jsonl" 2>/dev/null
  then
    _log "WARNING: could not append to $audit_dir/jira-write-audit.jsonl — this write's audit record was not persisted (AC-SEC-5)." || true
  fi
}

_on_exit() {
  _audit_write
  _cleanup
}
trap _on_exit EXIT

_usage() {
  cat >&2 <<'USAGE'
Usage:
  jira-write.sh --op comment-create --key KEY-123 --body TEXT --confirmed
  jira-write.sh --op transition     --key KEY-123 --status NAME --confirmed
  jira-write.sh --op assign         --key KEY-123 --assignee VALUE --confirmed
  jira-write.sh --op assign         --key KEY-123 --remove-assignee --confirmed

--confirmed is required on every invocation. Writes are refused unless
enabled in .claude/configuration.yml (jira.write.enabled: true).
USAGE
}


# ---------------------------------------------------------------------------
# Per-op input validation
# ---------------------------------------------------------------------------
# Reject-never-coerce, anchored where the value has a known shape. Status and
# assignee are intentionally NOT checked against a built-in enumeration
# (AC-2.3) — Jira workflows and directories are per-instance and unbounded.
# A leading dash is NOT rejected here: unlike jira_validate_key (which feeds
# a positional acli argument with no `--` escape available), body/status/
# assignee values are passed as ordinary argv elements after their own flag,
# and argv-array assembly — never string interpolation — is the actual
# leading-dash defence (AC-SEC-6). Rejecting a leading dash here would
# reject legitimate content (e.g. a comment body that starts with "- ").
jira_validate_body() {
  local body="${1:-}"
  [[ -n "$body" ]] || _die "$EX_USER" "No comment body supplied. Use --body TEXT."
}

jira_validate_status() {
  local status="${1:-}"
  [[ -n "$status" ]] || _die "$EX_USER" "No target status supplied. Use --status NAME."
  # A whitespace-only value would normalize to "" in _normalize_status,
  # matching an absent/blank read-back status and turning a claimed
  # success into a false-positive match instead of a correct ambiguous
  # outcome. Reject before it ever reaches the comparison.
  [[ -n "${status//[[:space:]]/}" ]] || _die "$EX_USER" "No target status supplied. Use --status NAME."
}

jira_validate_assignee() {
  local assignee="${1:-}"
  [[ -n "$assignee" ]] || _die "$EX_USER" \
    "No assignee supplied. Use --assignee VALUE (email, account id, or @me), or --remove-assignee to unassign."
}

# ---------------------------------------------------------------------------
# Write-enable config flag (D-10)
# ---------------------------------------------------------------------------
# Resolved and enforced HERE, not by SKILL.md prose alone, so a direct
# invocation of this script with --confirmed still cannot mutate when the
# flag is off, absent, or unresolvable for any reason. Fail-closed:
# unresolvable is treated identically to false, never to true — mirrors
# AC-5.4's "an unanswerable prompt is never licence to proceed."
#
# Mirrors key-inference.sh's existing defensive-subshell sourcing of
# resolve-config.sh (three-path fallback chain, `set +u` inside the
# subshell) rather than inventing a new pattern — see key-inference.sh's own
# comment for why the subshell and `set +u` are load-bearing, not stylistic:
# resolve-config.sh performs an arithmetic comparison on unexpanded yq
# output, which is a fatal unbound-variable error under `set -u`.
# Echoes two lines: "true"/"false", then a reason token. The reason exists
# purely for diagnostics — the caller must still refuse identically on any
# "false" reason (fail-closed is a single behavior; only the MESSAGE varies).
# Without a reason, "not enabled" and "yq is missing" were indistinguishable
# to the user, and the former's fix instructions ("add jira.write.enabled:
# true") were actively wrong advice when the latter was the real cause.
_write_enabled() {
  local root self="${BASH_SOURCE[0]}"
  case "$self" in
    */*) root="${self%/*}/.." ;;
    *)   root=".." ;;
  esac
  root="$(cd "$root" 2>/dev/null && pwd)" || root=""

  # resolve-config.sh's config-discovery loop walks up the tree with
  # `dirname` and never checks it exists; without it the loop never
  # terminates. Cheaper to verify the dependency than to bound the time.
  if ! command -v dirname >/dev/null 2>&1; then
    printf 'false\nno-dirname'
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
      printf 'false\nno-config-file'
    elif ! command -v yq >/dev/null 2>&1; then
      printf 'false\nno-yq'
    else
      _v="$(yq -r '.jira.write.enabled // "false"' "$CONFIG" 2>/dev/null)" || { printf 'false\nyq-failed'; exit 0; }
      # No `// "true"` here — same false-is-falsy `//` pitfall as lib.sh's
      # jira_master_enabled: it would silently coerce an explicit
      # `enabled: false` back to "true". Fetch the raw value and test it.
      _master="$(yq -r '.jira.enabled' "$CONFIG" 2>/dev/null)" || { printf 'false\nyq-failed'; exit 0; }
      if [ "$_master" = "false" ]; then
        # Master switch off: writes are refused regardless of jira.write.enabled
        # — a project that opted out of Jira entirely shouldn't still mutate it.
        printf 'false\nresolved-false-master-disabled'
      elif [ "$_v" = "true" ]; then
        printf 'true\nresolved-true'
      else
        printf 'false\nresolved-false'
      fi
    fi
  )" || result="false
unresolvable"

  printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# Write-specific acli runner
# ---------------------------------------------------------------------------
# Mirrors jira.sh's _run_acli hardening (timeout, separate stdout/stderr,
# argv-only invocation) but deliberately does NOT reuse it: _run_acli's
# `rc != 0 -> EX_USER` mapping encodes a trust assumption the live capture in
# docs/decisions/012-jira-write-verb-contract.md proved false for write
# verbs — acli returns rc=0 on total write failure. Success/failure here is
# decided entirely by _write_gate, from the response body.
_run_acli_write() {
  local what="$1"; shift
  local rc=0
  timeout "$ACLI_TIMEOUT" acli "$@" >"$OUT_F" 2>"$ERR_F" </dev/null || rc=$?

  if (( rc == TIMEOUT_RC )); then
    _die "$EX_SYSTEM" "Timed out after ${ACLI_TIMEOUT}s attempting $what. Check your network or try again."
  fi
  # rc is otherwise NOT checked here — see the header comment above.
}

# Interprets the captured --json envelope:
#   {results: [{status: "SUCCESS"|"FAILURE", message, id}], totalCount, successCount}
# (live-captured shape, docs/decisions/012-jira-write-verb-contract.md).
# Any response that does not match this exactly is unverifiable and dies
# with EX_AMBIGUOUS directly — there is no third return value the caller
# could mistake for a clean outcome. On a clean match, echoes SUCCESS or
# FAILURE on stdout; the caller reads .results[0].message for FAILURE text.
_write_gate() {
  local what="$1"
  if [[ ! -s "$OUT_F" ]]; then
    local stderr_hint=""
    [[ -s "$ERR_F" ]] && stderr_hint="
acli stderr: $(_excerpt "$ERR_F")"
    _die "$EX_AMBIGUOUS" \
      "$what: acli produced no output. The write may or may not have completed — verify the ticket manually before retrying.${stderr_hint}"
  fi

  local status total success
  if ! status=$(jq -r '.results[0].status // empty' <"$OUT_F" 2>/dev/null) \
     || ! total=$(jq -r '.totalCount // empty' <"$OUT_F" 2>/dev/null) \
     || ! success=$(jq -r '.successCount // empty' <"$OUT_F" 2>/dev/null); then
    local stderr_hint=""
    [[ -s "$ERR_F" ]] && stderr_hint="
acli stderr: $(_excerpt "$ERR_F")"
    _die "$EX_AMBIGUOUS" \
      "$what: acli's response could not be interpreted as JSON. The write may or may not have completed — verify the ticket manually before retrying.
Received: $(_excerpt "$OUT_F")${stderr_hint}"
  fi

  if [[ -z "$status" || -z "$total" || -z "$success" ]]; then
    _die "$EX_AMBIGUOUS" \
      "$what: acli's response was missing an expected field (status/totalCount/successCount). The write may or may not have completed — verify the ticket manually before retrying.
Received: $(_excerpt "$OUT_F")"
  fi

  if [[ "$total" != "1" ]]; then
    _die "$EX_AMBIGUOUS" \
      "$what: expected exactly one result for a single-key write, got totalCount=$total. The write may or may not have completed — verify the ticket manually before retrying."
  fi

  case "$status" in
    SUCCESS)
      [[ "$success" == "1" ]] || _die "$EX_AMBIGUOUS" \
        "$what: acli reported status SUCCESS but successCount=$success (expected 1). The write may or may not have completed — verify the ticket manually before retrying."
      printf 'SUCCESS'
      ;;
    FAILURE)
      printf 'FAILURE'
      ;;
    *)
      _die "$EX_AMBIGUOUS" \
        "$what: acli reported an unrecognised status '$status'. The write may or may not have completed — verify the ticket manually before retrying."
      ;;
  esac
}

# Extracts and bounds .results[0].message from the just-completed write's
# OUT_F, for the FAILURE case each op reports to the user. Bounded to the
# same ERR_EXCERPT length lib.sh's _excerpt uses everywhere else acli's own
# text is echoed: it is server-controlled and unverified, and SKILL.md
# instructs surfacing it verbatim — an unbounded echo is exactly the
# unbounded-dump path _excerpt exists to close for every other acli text
# path (_excerpt itself takes a file path, not a string, so a plain bash
# substring bound is used here instead of routing through it).
_gate_message() {
  local msg
  msg="$(jq -r '.results[0].message // empty' <"$OUT_F" 2>/dev/null || true)"
  [[ -n "$msg" ]] || msg="unknown error"
  printf '%s' "${msg:0:$ERR_EXCERPT}"
}

# ---------------------------------------------------------------------------
# Read-back (D-9)
# ---------------------------------------------------------------------------
# Subprocess call to jira.sh, not a reimplementation: reuses the read path's
# already-tested, already-scrubbed comment-list output rather than
# re-deriving PII-scrubbing/shape-tolerance logic here (that duplication is
# exactly what lib.sh's extraction (D-8) exists to avoid one layer up).
_read_comments() {
  local key="$1"
  bash "$JIRA_LIB_DIR/jira.sh" --op comment-list --key "$key" --limit 200 2>/dev/null
}

# ---------------------------------------------------------------------------
# Operations (transition/assign land in a later chunk)
# ---------------------------------------------------------------------------

# The reference operation (US-1). Read-back is a before/after diff of
# comment ids, NOT a match against a returned id (D-11, as amended after
# T2's live capture): the comment-create success response's only id field
# is the work-item key, identical across every write verb's envelope — it
# carries no comment-specific identifier to match against. See
# docs/decisions/012-jira-write-verb-contract.md.
op_comment_create() {
  local key="$1" body="$2" site="$3"

  local before_json before_ids
  before_json="$(_read_comments "$key")" || _die "$EX_AMBIGUOUS" \
    "Could not read $key's existing comments before posting. Refusing to write without a pre-write baseline to verify against."
  before_ids="$(jq -r '.comments[].id // empty' <<<"$before_json" 2>/dev/null | grep -v '^$' || true)"

  _run_acli_write "posting a comment on $key" jira workitem comment create --key "$key" --body "$body" --json

  local outcome
  outcome="$(_write_gate "comment on $key")"

  if [[ "$outcome" == "FAILURE" ]]; then
    local msg
    msg="$(_gate_message)"
    _die "$EX_USER" "Could not comment on $key: $msg"
  fi

  # acli claims SUCCESS — now the mandatory, independent read-back.
  local after_json after_ids new_ids new_count
  after_json="$(_read_comments "$key")" || _die "$EX_AMBIGUOUS" \
    "Comment on $key may have posted (acli reported success) but the post-write read-back failed. Verify the ticket manually before retrying."
  after_ids="$(jq -r '.comments[].id // empty' <<<"$after_json" 2>/dev/null | grep -v '^$' || true)"

  new_ids="$(comm -13 <(printf '%s\n' "$before_ids" | sort -u) <(printf '%s\n' "$after_ids" | sort -u) | grep -v '^$' || true)"
  new_count=$(printf '%s\n' "$new_ids" | grep -c . || true)

  if [[ "$new_count" -ne 1 ]]; then
    _die "$EX_AMBIGUOUS" \
      "Comment on $key: acli reported success but the read-back found $new_count new comment(s) (expected exactly 1). The write may or may not have completed as intended — verify the ticket manually before retrying, rather than posting again."
  fi

  local new_id actual_body
  new_id="$(printf '%s\n' "$new_ids" | head -1)"
  actual_body="$(jq -r --arg id "$new_id" '.comments[] | select(.id == $id) | .body' <<<"$after_json" 2>/dev/null)"

  if [[ "$actual_body" != "$body" ]]; then
    _die "$EX_AMBIGUOUS" \
      "Comment on $key: a new comment (id $new_id) appeared but its body does not match what was submitted. The write may or may not have completed as intended — verify the ticket manually before retrying."
  fi

  jq -n --arg key "$key" --arg id "$new_id" --arg site "$site" \
    '{key: $key, site: $site, action: "comment", outcome: "success", comment_id: $id}'
}

# Lowercase + trim only — used solely to compare the requested status
# against the read-back for AC-2.1's confirmation, never to validate or
# transform what's actually sent to acli (AC-2.3 still passes $status
# through to the acli call completely untouched). `tr`, not bash 4's
# ${var,,}: the plugin must not assume a bash newer than macOS's default
# 3.2 (see jira.sh's own header on avoiding non-portable assumptions).
_normalize_status() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]'
}

# Status names pass through verbatim, never validated against a built-in
# list (AC-2.3) — Jira workflows are per-project and unbounded. The no-op
# case (already in the target status) still issues the write and still
# counts as success (AC-2.4): idempotent re-confirmation, not a distinct state.
op_transition() {
  local key="$1" status="$2" site="$3"

  _run_acli_write "transitioning $key to '$status'" jira workitem transition --key "$key" --status "$status" --json --yes

  local outcome
  outcome="$(_write_gate "transition of $key")"

  if [[ "$outcome" == "FAILURE" ]]; then
    local msg
    msg="$(_gate_message)"
    _die "$EX_USER" "Could not transition $key: $msg"
  fi

  # acli claims SUCCESS — re-read and confirm the status now matches. Uses
  # jira.sh (D-9 subprocess), never a reimplementation of op_view.
  local after actual_status
  after="$(bash "$JIRA_LIB_DIR/jira.sh" --op view --key "$key" 2>/dev/null)" || _die "$EX_AMBIGUOUS" \
    "Transition of $key may have completed (acli reported success) but the post-write read-back failed. Verify the ticket manually before retrying."
  actual_status="$(jq -r '.status // empty' <<<"$after" 2>/dev/null)"

  # Case/whitespace-insensitive: acli's matching behavior for --status was
  # never live-verified (docs/decisions/012-jira-write-verb-contract.md only
  # captured an exact-case request), so a genuinely successful transition
  # requested as e.g. "in progress" must not read back as a false ambiguous
  # just because Jira renders it "In Progress". A real mismatch still exits
  # 40 either way — this only widens what counts as a match, never narrows it.
  if [[ "$(_normalize_status "$actual_status")" != "$(_normalize_status "$status")" ]]; then
    _die "$EX_AMBIGUOUS" \
      "Transition of $key: acli reported success but the ticket now shows status '$actual_status', not the requested '$status'. The write may or may not have completed as intended — verify the ticket manually before retrying."
  fi

  jq -n --arg key "$key" --arg status "$actual_status" --arg site "$site" \
    '{key: $key, site: $site, action: "transition", outcome: "success", status: $status}'
}

# Handles both assign and unassign (--remove-assignee). The no-op case
# (already assigned to the requested value, or already unassigned) still
# issues the write and still counts as success (AC-3.4), same as transition.
op_assign() {
  local key="$1" assignee="$2" remove="$3" site="$4"

  local desc argv=(jira workitem assign --key "$key" --json --yes)
  if [[ "$remove" == "true" ]]; then
    argv+=(--remove-assignee)
    desc="removing $key's assignee"
  else
    argv+=(--assignee "$assignee")
    desc="assigning $key to '$assignee'"
  fi

  _run_acli_write "$desc" "${argv[@]}"

  local outcome
  outcome="$(_write_gate "assignment on $key")"

  if [[ "$outcome" == "FAILURE" ]]; then
    local msg
    msg="$(_gate_message)"
    _die "$EX_USER" "Could not update $key's assignee: $msg"
  fi

  local after actual_assignee
  after="$(bash "$JIRA_LIB_DIR/jira.sh" --op view --key "$key" 2>/dev/null)" || _die "$EX_AMBIGUOUS" \
    "Assignment on $key may have completed (acli reported success) but the post-write read-back failed. Verify the ticket manually before retrying."
  actual_assignee="$(jq -r '.assignee // empty' <<<"$after" 2>/dev/null)"

  if [[ "$remove" == "true" ]]; then
    if [[ "$actual_assignee" != "none" ]]; then
      _die "$EX_AMBIGUOUS" \
        "Unassignment of $key: acli reported success but the ticket still shows an assignee ('$actual_assignee'). The write may or may not have completed as intended — verify the ticket manually before retrying."
    fi
  else
    # The read-back is a DISPLAY NAME; the request may have been an email,
    # @me, or account id (see docs/decisions/012-jira-write-verb-contract.md's
    # implementation note) — exact string equality against the request value
    # is not meaningful here. Confirm only that an assignee is now SET, and
    # surface the actual display name for the human to visually cross-check.
    if [[ "$actual_assignee" == "none" ]]; then
      _die "$EX_AMBIGUOUS" \
        "Assignment of $key: acli reported success but the ticket shows no assignee. The write may or may not have completed as intended — verify the ticket manually before retrying."
    fi
  fi

  jq -n --arg key "$key" --arg assignee "$actual_assignee" --arg site "$site" \
    '{key: $key, site: $site, action: "assign", outcome: "success", assignee: $assignee}'
}

# ---------------------------------------------------------------------------
# Argument parsing (flag-first)
# ---------------------------------------------------------------------------
_need_value() {
  (( $1 >= 2 )) || _die "$EX_USER" "$2 requires a value."
}

main() {
  local op="" key="" confirmed="false"
  local body="" status="" assignee="" remove_assignee="false"

  while (( $# > 0 )); do
    case "$1" in
      --op=*)             op="${1#--op=}";               shift ;;
      --op)               _need_value $# "--op";            op="$2";           shift 2 ;;
      --key=*)            key="${1#--key=}";              shift ;;
      --key)              _need_value $# "--key";           key="$2";          shift 2 ;;
      --body=*)           body="${1#--body=}";            shift ;;
      --body)              _need_value $# "--body";          body="$2";         shift 2 ;;
      --status=*)         status="${1#--status=}";        shift ;;
      --status)            _need_value $# "--status";        status="$2";       shift 2 ;;
      --assignee=*)       assignee="${1#--assignee=}";    shift ;;
      --assignee)          _need_value $# "--assignee";       assignee="$2";     shift 2 ;;
      --remove-assignee)  remove_assignee="true";          shift ;;
      --confirmed)        confirmed="true";                shift ;;
      -h|--help)          _usage; exit "$EX_OK" ;;
      # Bulk/query-targeting rejection (AC-5.3, R6). Matched HERE, as flag
      # positions in the parser's own loop, not via a separate blind
      # pre-scan of "$@" — a pre-scan can't distinguish a flag from a
      # flag's VALUE, so content that merely happens to equal e.g. "--jql"
      # (a comment body, a status name) was previously rejected as if it
      # were the real flag. A value consumed via `shift 2` above never
      # re-enters this case match, so this arm only ever fires on an
      # actual flag token — still checked before any op dispatch below,
      # since the whole parsing loop completes first either way.
      --jql|--jql=*|--filter|--filter=*|--ignore-errors|--paginate)
        _die "$EX_USER" \
          "jira-write.sh: '$1' is a bulk/query-targeting flag and is never accepted here. Every write targets exactly one key."
        ;;
      *) _usage; _die "$EX_USER" "jira-write.sh: unknown argument '$1'" ;;
    esac
  done

  if [[ -z "$op" ]]; then
    _usage
    _die "$EX_USER" "No operation supplied."
  fi

  case "$op" in
    comment-create|transition|assign) ;;
    *) _usage; _die "$EX_USER" "Unsupported operation '$op'. Supported: comment-create, transition, assign." ;;
  esac

  # --confirmed is a loud-failure guard against an ACCIDENTAL direct
  # invocation (D-6) — not a security boundary against a deliberate one. The
  # real control is the AskUserQuestion confirmation in SKILL.md Step 2b.
  [[ "$confirmed" == "true" ]] || _die "$EX_USER" \
    "jira-write.sh: --confirmed is required. This performs a real Jira write and must not run without explicit confirmation."

  jira_validate_key "$key"

  case "$op" in
    comment-create) jira_validate_body "$body" ;;
    transition)     jira_validate_status "$status" ;;
    assign)
      if [[ "$remove_assignee" == "true" && -n "$assignee" ]]; then
        _die "$EX_USER" \
          "jira-write.sh: --assignee and --remove-assignee are mutually exclusive. Pass exactly one — the executed write must match what was confirmed, and this pair does not name a single unambiguous action."
      fi
      [[ "$remove_assignee" == "true" ]] || jira_validate_assignee "$assignee"
      ;;
  esac

  local enable_check enabled enable_reason
  enable_check="$(_write_enabled)"
  enabled="${enable_check%%$'\n'*}"
  enable_reason="${enable_check#*$'\n'}"

  if [[ "$enabled" != "true" ]]; then
    case "$enable_reason" in
      resolved-false-master-disabled)
        _die "$EX_USER" \
          "jira-write.sh: Jira integration is disabled for this project (jira.enabled: false in .claude/configuration.yml). Enable it first, then enable writes separately if needed."
        ;;
      no-config-file|resolved-false)
        _die "$EX_USER" \
          "jira-write.sh: Jira write operations are not enabled for this project.
Enable them by adding to .claude/configuration.yml:
  jira:
    write:
      enabled: true"
        ;;
      no-dirname|no-yq)
        _die "$EX_USER" \
          "jira-write.sh: could not check whether writes are enabled — '${enable_reason#no-}' is required but was not found on PATH. Writes stay refused until it is available (fail-closed), even if jira.write.enabled is already set to true."
        ;;
      *)
        _die "$EX_USER" \
          "jira-write.sh: could not determine whether writes are enabled for this project (config unresolvable). Writes stay refused until this is fixed (fail-closed), even if jira.write.enabled is already set to true."
        ;;
    esac
  fi

  jira_preflight

  OUT_F="$(mktemp)"; ERR_F="$(mktemp)"

  local site
  site="$(jira_resolve_site)"

  # From here on this IS a write attempt (AC-SEC-5) — every exit path below,
  # success or not, is captured by the _audit_write EXIT trap.
  AUDIT_ACTION="$op"
  AUDIT_KEY="$key"
  AUDIT_SITE="$site"

  case "$op" in
    comment-create) op_comment_create "$key" "$body" "$site" ;;
    transition)     op_transition "$key" "$status" "$site" ;;
    assign)         op_assign "$key" "$assignee" "$remove_assignee" "$site" ;;
  esac
}

main "$@"
