#!/usr/bin/env bash
# plugin/shared/jira/jira-write.sh
#
# Write access to Jira work items via the Atlassian CLI (acli): comment,
# transition, assign, and create. Invoked flag-first by
# plugin/skills/jira/SKILL.md Step 2b, ONLY after an AskUserQuestion
# confirmation:
#
#   jira-write.sh --op comment-create --key KEY-123 --body TEXT --confirmed
#   jira-write.sh --op transition     --key KEY-123 --status NAME --confirmed
#   jira-write.sh --op assign         --key KEY-123 --assignee VALUE --confirmed
#   jira-write.sh --op assign         --key KEY-123 --remove-assignee --confirmed
#   jira-write.sh --op create --project P --type T --summary S [--description D] --confirmed
#
# `create` (CL-44) is the one verb here whose gate is NOT the shared
# results[] envelope, because its live-captured behaviour differs from every
# other write verb's on both halves of the contract:
#
#   * on success it returns a BARE Jira REST issue object — top-level `key`,
#     `id`, `self`, `fields`, and no results[]/successCount/totalCount at all;
#   * on failure it exits NON-ZERO with an empty stdout and plain text on
#     stderr — there is no JSON failure body to parse.
#
# Both were captured live across eleven runs; see addenda 2, 3 and 4 of
# docs/decisions/012-jira-write-verb-contract.md. So create gates on rc first
# and then on a top-level `key`, while the mandatory read-back stays exactly
# as mandatory as everywhere else — partial success (the item is created but
# a follow-on field write fails) was never reproduced deliberately, so it is
# unobserved rather than ruled out, and the read-back is its only defence.
#
# `create-bulk` remains out of scope: the confirmation model is per-write,
# and bulk creation needs its own consent design.
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
# contract doc above) — NO op in this file ever treats rc as evidence of
# success. comment/transition/assign gate on the response body's
# results[0].status + successCount == totalCount == 1; create gates on a
# top-level `key` (see above). Every op then re-reads the affected item
# afterward as the real authority. Any response this file cannot fully verify
# reports the ambiguous EX_AMBIGUOUS state, never a false success or a false
# failure.
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
# create only: the submitted description is handed to acli as a FILE
# (--description-file), never as a flag value, because --description-file is
# the form every live capture in the ADR used. Registered for cleanup here
# with the other temp files for the same reason they are.
DESC_F=""

# Set by main() once past every gate, right before dispatching to an op —
# never for an early usage/validation/config-disabled exit, since those are
# refusals, not write ATTEMPTS (AC-SEC-5's own wording). Read by the audit
# trap below; empty AUDIT_ACTION means "no write was attempted this run."
AUDIT_ACTION=""
AUDIT_KEY=""
AUDIT_SITE=""
AUDIT_SITE_RAW=""

# acli's raw `current_profile` label, set alongside them. Kept separate from
# the displayed site because create's browse URL must resolve from the identity
# the config is keyed by, not from the string a human reads (CL-49).
SITE_RAW=""

# Whether SITE_RAW resolved to a hostname — "true"/"false", emitted as
# `site_resolved` in every write envelope. `site` alone is a display string and
# on the fallback path reads "<label> (unresolved — …)", so a consumer parsing
# it as a hostname would silently get prose. The boolean is what makes the two
# cases machine-distinguishable, matching what `jira.sh --op site` already
# returns to the confirmation prompt.
SITE_RESOLVED="false"

_cleanup() {
  [[ -n "$OUT_F" ]] && rm -f "$OUT_F"
  [[ -n "$ERR_F" ]] && rm -f "$ERR_F"
  [[ -n "$DESC_F" ]] && rm -f "$DESC_F"
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
    --arg site_raw "$AUDIT_SITE_RAW" \
    --arg ts "$ts" --arg outcome "$outcome" \
    '{action:$action, key:$key, site:$site, site_raw:$site_raw, timestamp:$ts, confirmed:true, outcome:$outcome, verified:($outcome=="success" or $outcome=="failure")}' \
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
  jira-write.sh --op create --project PROJ --type TYPE --summary TEXT \
                            [--description TEXT] --confirmed

--confirmed is required on every invocation. Writes are refused unless
enabled in .claude/configuration.yml (jira.write.enabled: true).

create takes no --key: the key does not exist until Jira assigns one.
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
  # A whitespace-only value would normalize to "" in _normalize_text,
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

# create only. The project key is the one create-time value with a known,
# checkable shape — and the only one this script can compare the returned
# key against, which is what makes "the item Jira created is the item this
# invocation asked for" a checkable claim rather than a trusting one.
# Deliberately the same character class as jira_validate_key's project half,
# so a project this accepts can never produce a key the read-back path would
# then refuse as malformed.
jira_validate_project() {
  local project="${1:-}"
  [[ -n "$project" ]] || _die "$EX_USER" "No project supplied. Use --project PROJ."
  [[ "$project" =~ ^[A-Z][A-Z0-9]+$ ]] || _die "$EX_USER" \
    "Invalid project key '$project' — expected an uppercase key of two or more characters, e.g. PROJ."
}

# Issue types are per-project and unbounded (Epic/Story/Task/Bug/Subtask plus
# whatever a project has configured), so this is a non-empty check only —
# exactly the AC-2.3 reasoning that keeps --status off a built-in list. Jira
# itself rejects an unknown type, and that rejection is now a verified
# failure this script can report (acli exits non-zero on it — addendum 3).
jira_validate_type() {
  local type="${1:-}"
  [[ -n "${type//[[:space:]]/}" ]] || _die "$EX_USER" "No issue type supplied. Use --type TYPE (e.g. Task, Bug, Story)."
}

# A whitespace-only summary would create a real work item with a blank title
# and then read back as a "match" against the equally-blank submitted value —
# a false success. Rejected before it can reach acli, same rationale as
# jira_validate_status's whitespace check.
jira_validate_summary() {
  local summary="${1:-}"
  [[ -n "${summary//[[:space:]]/}" ]] || _die "$EX_USER" "No summary supplied. Use --summary TEXT."
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
#
# ACLI_RC records the exit code for the one verb whose rc is load-bearing:
# `create` exits non-zero on every failure mode probed (addendum 3), unlike
# comment/transition/assign which exit 0 on total failure. It is RECORDED,
# never acted on here — each op decides for itself whether rc means anything
# for its own verb, so the three exit-0-always verbs keep ignoring it exactly
# as before.
ACLI_RC=0

_run_acli_write() {
  local what="$1"; shift
  local rc=0
  timeout "$ACLI_TIMEOUT" acli "$@" >"$OUT_F" 2>"$ERR_F" </dev/null || rc=$?
  ACLI_RC="$rc"

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

  jq -n --arg key "$key" --arg id "$new_id" --arg site "$site" --argjson resolved "$SITE_RESOLVED" \
    '{key: $key, site: $site, site_resolved: $resolved, action: "comment", outcome: "success", comment_id: $id}'
}

# Lowercase + trim only — used solely to compare the requested status
# against the read-back for AC-2.1's confirmation, never to validate or
# transform what's actually sent to acli (AC-2.3 still passes $status
# through to the acli call completely untouched). `tr`, not bash 4's
# ${var,,}: the plugin must not assume a bash newer than macOS's default
# 3.2 (see jira.sh's own header on avoiding non-portable assumptions).
# Leading/trailing whitespace only — the half of _normalize_text that applies
# where case must be preserved (a summary is user-visible prose; a case
# difference there is a real difference, a trailing space Jira stripped is not).
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_normalize_text() {
  printf '%s' "$(_trim "$1")" | tr '[:upper:]' '[:lower:]'
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
  if [[ "$(_normalize_text "$actual_status")" != "$(_normalize_text "$status")" ]]; then
    _die "$EX_AMBIGUOUS" \
      "Transition of $key: acli reported success but the ticket now shows status '$actual_status', not the requested '$status'. The write may or may not have completed as intended — verify the ticket manually before retrying."
  fi

  jq -n --arg key "$key" --arg status "$actual_status" --arg site "$site" --argjson resolved "$SITE_RESOLVED" \
    '{key: $key, site: $site, site_resolved: $resolved, action: "transition", outcome: "success", status: $status}'
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

  jq -n --arg key "$key" --arg assignee "$actual_assignee" --arg site "$site" --argjson resolved "$SITE_RESOLVED" \
    '{key: $key, site: $site, site_resolved: $resolved, action: "assign", outcome: "success", assignee: $assignee}'
}

# ---------------------------------------------------------------------------
# create (US-4 / CL-44)
# ---------------------------------------------------------------------------

# `jira_resolve_site` returns acli's `current_profile`, a LABEL that on a real
# OAuth profile is "<cloud_id>:<account_id>" and not a hostname. Resolving that
# label to the profile's own `site` host now lives in lib.sh
# (`jira_resolve_site_host` / `jira_clean_site` / `jira_is_hostname`), moved
# there by CL-49 once the other three verbs and the confirmation prompt needed
# it too — CL-44 wrote it here when create's browse URL was its only caller.

# The user-facing link for a newly created item, built from the KEY and the
# configured site — never from the response's `self`, which live capture
# showed to be a `/rest/api/3/issue/<id>` URL on an internal API host, not
# anywhere a person can open. Echoes nothing when the site cannot be resolved
# to a plain hostname, for the reason above.
_browse_url() {
  local key="$1" site="$2" host
  host="$(jira_resolve_site_host "$site")"
  [[ -n "$host" ]] || return 0
  printf 'https://%s/browse/%s' "$host" "$key"
}

# create's own success gate. Deliberately NOT _write_gate: the envelope has
# no results[]/successCount/totalCount to read (addendum 2), and rc is
# load-bearing here where it is worthless everywhere else (addendum 3).
# Echoes the new key on stdout; every other path dies.
_create_gate() {
  local what="$1"
  local stderr_hint=""
  [[ -s "$ERR_F" ]] && stderr_hint="
acli stderr: $(_excerpt "$ERR_F")"

  if (( ACLI_RC != 0 )); then
    # Observed in all eight probed failure modes: exit 1, stdout exactly 0
    # bytes, the reason as plain text on stderr — client-side validation and
    # server-side rejection alike. Nothing was created, so this is a VERIFIED
    # failure (EX_USER), not the ambiguous state.
    if [[ -s "$OUT_F" ]]; then
      # Never observed: a non-zero exit that still produced a body. Refusing
      # to classify it either way is the whole point of EX_AMBIGUOUS —
      # this is exactly the "a mode that exits differently may still exist"
      # caveat addendum 3 recorded rather than discharged.
      _die "$EX_AMBIGUOUS" \
        "$what: acli exited $ACLI_RC but still returned a response body, a combination never observed. The work item may or may not have been created — check the project in Jira before retrying.
Received: $(_excerpt "$OUT_F")${stderr_hint}"
    fi
    _die "$EX_USER" "Could not create the work item.${stderr_hint}"
  fi

  if [[ ! -s "$OUT_F" ]]; then
    _die "$EX_AMBIGUOUS" \
      "$what: acli exited 0 but produced no output. The work item may or may not have been created — check the project in Jira before retrying.${stderr_hint}"
  fi

  local new_key
  if ! new_key=$(jq -r '.key // empty' <"$OUT_F" 2>/dev/null); then
    _die "$EX_AMBIGUOUS" \
      "$what: acli's response could not be interpreted as JSON. The work item may or may not have been created — check the project in Jira before retrying.
Received: $(_excerpt "$OUT_F")${stderr_hint}"
  fi

  if [[ -z "$new_key" ]]; then
    # Covers the shared results[] envelope too: if acli ever starts returning
    # comment-create's shape here, it has no top-level key and lands right
    # here as ambiguous rather than being silently mis-parsed.
    _die "$EX_AMBIGUOUS" \
      "$what: acli's response carried no top-level 'key'. The work item may or may not have been created — check the project in Jira before retrying.
Received: $(_excerpt "$OUT_F")"
  fi

  # jira_validate_key's exact pattern, reused rather than re-invented: a key
  # this accepts is by construction one the read-back below can pass to
  # jira.sh, so the gate can never hand the next step a key it will refuse.
  if [[ ! "$new_key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
    _die "$EX_AMBIGUOUS" \
      "$what: acli returned '${new_key:0:64}' as the new key, which is not a work item key. The work item may or may not have been created — check the project in Jira before retrying."
  fi

  printf '%s' "$new_key"
}

# Creates one work item. The read-back asserts ONLY on fields `view --json`
# actually returns populated (addendum 2 measured that projection at five:
# assignee, description, issuetype, status, summary) — asserting on project
# or reporter would fail a CORRECT write, since those come back null from
# the view projection no matter what the item holds.
#
# Description is NOT asserted on, deliberately. It is submitted as plain text
# and read back through jira.sh's ADF renderer, so a correct write does not
# round-trip byte-for-byte; comparing them would manufacture ambiguous
# outcomes for writes that actually landed. Summary (a plain string on both
# sides) and issue type carry the identity check instead.
op_create() {
  local project="$1" type="$2" summary="$3" description="$4" site="$5"

  local argv=(jira workitem create --project "$project" --type "$type" --summary "$summary")
  if [[ -n "$description" ]]; then
    DESC_F="$(mktemp)"
    printf '%s' "$description" >"$DESC_F"
    argv+=(--description-file "$DESC_F")
  fi
  argv+=(--json)

  _run_acli_write "creating a $type in $project" "${argv[@]}"

  local new_key
  new_key="$(_create_gate "create in $project")"

  # The audit record names the item that was actually created, not just the
  # project it was aimed at — set as soon as the key is known so every exit
  # path below (including an ambiguous read-back) records it.
  AUDIT_KEY="$new_key"

  # acli claims the item exists — now the mandatory, independent read-back.
  local after actual_summary actual_type actual_status
  after="$(bash "$JIRA_LIB_DIR/jira.sh" --op view --key "$new_key" 2>/dev/null)" || _die "$EX_AMBIGUOUS" \
    "Create in $project: acli reported $new_key was created but reading it back failed. The work item may or may not exist as intended — check $new_key in Jira before retrying, rather than creating a second one."

  local actual_key
  actual_key="$(jq -r '.key // empty' <<<"$after" 2>/dev/null)"
  actual_summary="$(jq -r '.summary // empty' <<<"$after" 2>/dev/null)"
  actual_type="$(jq -r '.type // empty' <<<"$after" 2>/dev/null)"
  actual_status="$(jq -r '.status // empty' <<<"$after" 2>/dev/null)"

  # The item read back must be the item the key names. jira.sh falls back to
  # the requested key when the response carries none, so this can only fire
  # on a response that actively disagrees — a moved or redirected item, say —
  # never on a merely terse one.
  if [[ "$actual_key" != "$new_key" ]]; then
    _die "$EX_AMBIGUOUS" \
      "Create in $project: acli reported $new_key was created but reading that key back returned '${actual_key:0:64}'. The work item may or may not have been created as intended — check $new_key in Jira before retrying, rather than creating a second one."
  fi

  # Trimmed on both sides, case-sensitive. Jira trims a submitted summary, so
  # a trailing space would otherwise read back "changed" and turn a perfectly
  # good write into a false ambiguous. Case is NOT folded: a summary is
  # user-visible prose, and a case difference there is a real difference.
  if [[ "$(_trim "$actual_summary")" != "$(_trim "$summary")" ]]; then
    _die "$EX_AMBIGUOUS" \
      "Create in $project: $new_key was reported created but its summary reads back as '${actual_summary:0:120}', not the submitted one. The work item may or may not have been created as intended — check $new_key in Jira before retrying, rather than creating a second one."
  fi

  # Case/whitespace-insensitive for the same reason the transition read-back
  # is: how acli matches a requested type name against Jira's own rendering
  # was never live-verified, and a correct write must not read back as a
  # false ambiguous merely because "bug" is rendered "Bug". A real mismatch
  # still exits 40 either way.
  if [[ "$(_normalize_text "$actual_type")" != "$(_normalize_text "$type")" ]]; then
    _die "$EX_AMBIGUOUS" \
      "Create in $project: $new_key was reported created but its type reads back as '${actual_type:0:64}', not the requested '$type'. The work item may or may not have been created as intended — check $new_key in Jira before retrying, rather than creating a second one."
  fi

  # From SITE_RAW, not from $site: $site is the display string, which carries
  # the "(unresolved …)" annotation when the label did not resolve and would
  # never be a hostname anyway. Building the URL from the raw label keeps
  # create's link behaviour byte-identical to CL-44's.
  local url
  url="$(_browse_url "$new_key" "$SITE_RAW")"

  jq -n --arg key "$new_key" --arg site "$site" --argjson resolved "$SITE_RESOLVED" --arg type "$actual_type" \
        --arg summary "$actual_summary" --arg status "$actual_status" --arg url "$url" \
    '{key: $key, site: $site, site_resolved: $resolved, action: "create", outcome: "success",
      type: $type, summary: $summary, status: $status,
      url: (if $url == "" then null else $url end)}'
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
  local project="" type="" summary="" description="" key_given="false"

  while (( $# > 0 )); do
    case "$1" in
      --op=*)             op="${1#--op=}";               shift ;;
      --op)               _need_value $# "--op";            op="$2";           shift 2 ;;
      --key=*)            key="${1#--key=}"; key_given="true";             shift ;;
      --key)              _need_value $# "--key";           key="$2"; key_given="true"; shift 2 ;;
      --project=*)        project="${1#--project=}";      shift ;;
      --project)           _need_value $# "--project";       project="$2";      shift 2 ;;
      --type=*)           type="${1#--type=}";            shift ;;
      --type)              _need_value $# "--type";          type="$2";         shift 2 ;;
      --summary=*)        summary="${1#--summary=}";      shift ;;
      --summary)           _need_value $# "--summary";       summary="$2";      shift 2 ;;
      --description=*)    description="${1#--description=}"; shift ;;
      --description)       _need_value $# "--description";   description="$2";  shift 2 ;;
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
    comment-create|transition|assign|create) ;;
    # create-bulk is named explicitly rather than falling into the generic
    # arm: it is a real acli verb whose omission is a deliberate consent
    # decision, not an oversight, and a caller reaching for it deserves to
    # be told which of those it is.
    create-bulk)
      _usage
      _die "$EX_USER" \
        "jira-write.sh: 'create-bulk' is not supported. Every write here targets exactly one item and carries its own confirmation; bulk creation needs its own consent design."
      ;;
    *) _usage; _die "$EX_USER" "Unsupported operation '$op'. Supported: comment-create, transition, assign, create." ;;
  esac

  # --confirmed is a loud-failure guard against an ACCIDENTAL direct
  # invocation (D-6) — not a security boundary against a deliberate one. The
  # real control is the AskUserQuestion confirmation in SKILL.md Step 2b.
  [[ "$confirmed" == "true" ]] || _die "$EX_USER" \
    "jira-write.sh: --confirmed is required. This performs a real Jira write and must not run without explicit confirmation."

  # create is the one op with no key to validate — the key does not exist
  # until Jira assigns one. A --key passed anyway is refused rather than
  # ignored: it names a target this op cannot honour, so the executed write
  # would not be the one the caller described (the same reasoning that makes
  # --assignee + --remove-assignee a rejection rather than a precedence rule).
  if [[ "$op" == "create" ]]; then
    [[ "$key_given" != "true" ]] || _die "$EX_USER" \
      "jira-write.sh: --key is not accepted for --op create. A new work item's key is assigned by Jira; pass --project, --type and --summary instead."
  else
    jira_validate_key "$key"
  fi

  case "$op" in
    comment-create) jira_validate_body "$body" ;;
    transition)     jira_validate_status "$status" ;;
    create)
      jira_validate_project "$project"
      jira_validate_type "$type"
      jira_validate_summary "$summary"
      ;;
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

  # Two values, deliberately. SITE_RAW is acli's `current_profile` — the
  # identity the config is keyed by, and the only thing create's browse URL can
  # be resolved from. $site is what a human is shown: the resolved hostname, or
  # the raw label marked unresolved (CL-49). Every user-facing field below
  # carries the second; nothing resolves from the first except the URL.
  local site site_host
  SITE_RAW="$(jira_resolve_site)"
  site="$(jira_site_display "$SITE_RAW")"
  # Decided by whether a host came back, never by comparing display against raw:
  # a profile whose label already IS its hostname resolves to itself, and a
  # string comparison would report that — the one unambiguous case — as
  # unresolved. Same rule jira.sh's `site` op applies.
  site_host="$(jira_resolve_site_host "$SITE_RAW")"
  [[ -n "$site_host" ]] && SITE_RESOLVED="true"

  # From here on this IS a write attempt (AC-SEC-5) — every exit path below,
  # success or not, is captured by the _audit_write EXIT trap.
  AUDIT_ACTION="$op"
  # create has no key yet; op_create overwrites this the moment Jira returns
  # one, so a record is never lost even if the read-back then comes back
  # ambiguous. Until then the record still names the target project, so an
  # attempt that failed before any key existed is auditable too.
  if [[ "$op" == "create" ]]; then
    AUDIT_KEY="(new item in $project)"
  else
    AUDIT_KEY="$key"
  fi
  AUDIT_SITE="$site"
  # The audit record keeps the RAW label too. The displayed hostname is the
  # readable half, but `current_profile` is the identity acli keys by and the
  # only value that still means something if the config is later edited — an
  # audit trail that kept only the rendered string would have quietly changed
  # format when CL-49 changed what `site` displays.
  AUDIT_SITE_RAW="$SITE_RAW"

  case "$op" in
    comment-create) op_comment_create "$key" "$body" "$site" ;;
    transition)     op_transition "$key" "$status" "$site" ;;
    assign)         op_assign "$key" "$assignee" "$remove_assignee" "$site" ;;
    create)         op_create "$project" "$type" "$summary" "$description" "$site" ;;
  esac
}

main "$@"
