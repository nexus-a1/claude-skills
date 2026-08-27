#!/usr/bin/env bash
# plugin/shared/jira/key-inference.sh
#
# Gathers work-item key CANDIDATES from the local session for the no-argument
# path of plugin/skills/jira/SKILL.md. It proposes; it never reads. Nothing
# here contacts Jira, and no candidate becomes a read target without the
# explicit user confirmation that SKILL.md Step 1a performs.
#
#   key-inference.sh [--branch STR] [--commits-file F] [--sessions-file F]
#                    [--session-id STR] [--commit-count N]
#
# Every flag is a test-injection override. With none supplied the helper
# self-discovers all three signals. This self-collection is deliberate and
# load-bearing: A6/bash-allowlist-coverage builds its scan buffer from a
# SKILL.md's own fenced bash blocks and never opens a called script, so
# keeping `git`, `jq` and `cat` inside this file lets the skill ship with
# `Bash(bash:*)` alone rather than growing three more tool grants. Moving any
# of these commands up to the skill layer turns a green build red.
#
# The fourth signal — the conversation itself — has no mechanical substrate
# and lives in SKILL.md prose. This helper covers three of the four; the
# 400-char bound below therefore applies to three of the four, and SKILL.md
# carries the same obligation in prose for the fourth.
#
# stdout is JSON and always well-formed. Diagnostics would defeat the point of
# a best-effort signal, so there are none: every source is independently
# guarded and an unavailable one reports `empty:<reason>` in `consulted`
# rather than failing. The script always exits 0 — a degraded environment
# (no git, no jq, no session) is a normal outcome, not an error, and the
# library's own preflight writes a better message than this script could.
#
# Conventions mirror jira.sh, deliberately NOT sourced from it: there is no
# shared import path across shared/*/ in a marketplace install.
set -uo pipefail

# Bound on rendered source text, matching jira.sh's ERR_EXCERPT bound on
# external error text. A hard cut, no ellipsis — same as _excerpt there.
readonly SRC_EXCERPT=400
readonly COMMIT_COUNT_DEFAULT=20

# The unanchored form of jira_validate_key's own anchored pattern (jira.sh:152).
# Every candidate it produces survives the final gate.
#
# The length ceiling is applied as a SEPARATE reject step, not as a quantifier
# bound inside this pattern, and the difference is the whole point. A bounded
# quantifier does not refuse an over-long token — it matches a substring of it,
# which silently rewrites the key into one the source never contained:
#
#   PROJ-1234567890  with {1,9} on the digits  ->  PROJ-123456789
#
# That is a different, entirely plausible, possibly real ticket, offered for
# confirmation against a source text the user would have to diff digit by digit
# to catch. It would reintroduce exactly the failure this feature claims to have
# answered — a wrong ticket read without the user noticing — with the
# confirmation prompt present but useless. Reject; never rewrite.
#
# The looser idioms elsewhere in the plugin — commit/SKILL.md's `[A-Z]+-`
# (single-char prefixes) and release/commits-data.sh's case-insensitive form —
# both yield candidates that gate rejects. Neither is modified here; they are
# precedent, not a contract.
readonly KEY_RE='[A-Z][A-Z0-9]+-[0-9]+'

# Any token longer than this is dropped whole. Real Jira keys are far shorter;
# jira_validate_key has no ceiling of its own, so without this a branch named
# A + B*5000 + -1 puts a 5003-character "key" into the prompt and then acli.
readonly MAX_KEY_LEN=32

# Ceiling on distinct candidates. SKILL.md displays at most 10 and quick-selects
# at most 3, so nothing below this is ever visible; the cap exists to bound
# work, not presentation. Without it a single crafted commit subject carrying
# hundreds of keys drives the O(keys x records) assembly below into a
# multi-second stall that reads to the user as a hung command.
readonly MAX_KEYS=50

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_BRANCH=""
OPT_COMMITS_FILE=""
OPT_SESSIONS_FILE=""
OPT_SESSION_ID=""
OPT_COMMIT_COUNT=""
# Distinguishes "not supplied" from "supplied as empty": an injected empty
# branch must mean "no branch", not "fall back to asking git".
HAVE_BRANCH=false
HAVE_SESSION_ID=false

while [ $# -gt 0 ]; do
  case "$1" in
    --branch)        OPT_BRANCH="${2:-}"; HAVE_BRANCH=true; shift 2 || shift $# ;;
    --branch=*)      OPT_BRANCH="${1#*=}"; HAVE_BRANCH=true; shift ;;
    --commits-file)  OPT_COMMITS_FILE="${2:-}"; shift 2 || shift $# ;;
    --commits-file=*) OPT_COMMITS_FILE="${1#*=}"; shift ;;
    --sessions-file) OPT_SESSIONS_FILE="${2:-}"; shift 2 || shift $# ;;
    --sessions-file=*) OPT_SESSIONS_FILE="${1#*=}"; shift ;;
    --session-id)    OPT_SESSION_ID="${2:-}"; HAVE_SESSION_ID=true; shift 2 || shift $# ;;
    --session-id=*)  OPT_SESSION_ID="${1#*=}"; HAVE_SESSION_ID=true; shift ;;
    --commit-count)  OPT_COMMIT_COUNT="${2:-}"; shift 2 || shift $# ;;
    --commit-count=*) OPT_COMMIT_COUNT="${1#*=}"; shift ;;
    # An unknown flag is ignored rather than fatal. This script is advisory;
    # refusing to run would cost the user their candidates over a typo in a
    # debugging invocation they did not write.
    *) shift ;;
  esac
done

COMMIT_COUNT="$COMMIT_COUNT_DEFAULT"
case "$OPT_COMMIT_COUNT" in
  '') ;;
  *[!0-9]*) ;;                     # non-numeric: keep the default
  # 10# forces base 10, so "010" is 10 rather than an octal surprise, and it
  # collapses "0" and "00" into the same rejected case. An unbounded value would
  # walk the entire history; 500 is far past anything useful.
  *) if [ "$((10#$OPT_COMMIT_COUNT))" -gt 0 ] && [ "$((10#$OPT_COMMIT_COUNT))" -le 500 ]; then
       COMMIT_COUNT="$((10#$OPT_COMMIT_COUNT))"
     fi ;;
esac

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

# Bound the length, then remove every character that can make the rendered text
# lie about itself. Both matter: branch names and commit subjects are
# contributor-authored and reach the user's transcript verbatim, and SKILL.md
# leans on that text as "the only thing that lets the user notice a stale
# branch before the wrong ticket is read". Anything that can visually reorder
# or hide part of it defeats exactly that control.
#
# Three classes are removed:
#   C0 (\001-\037)  — ESC lives here, so ANSI sequences are defanged at the
#                     source; newlines cannot forge an extra prompt line.
#   DEL (\177)      — renders inconsistently across terminals.
#   Unicode bidi and zero-width formats — Trojan Source (CVE-2021-42574).
#                     U+202E in a branch name reverses the displayed run order
#                     while leaving the bytes intact, which is the whole attack.
#
# Homoglyphs (Cyrillic О in PROJ-123) are deliberately NOT addressed: the key
# is displayed separately from this text and faces jira_validate_key as a
# second gate, so the cost of a Unicode-confusables table buys nothing here.
#
# Slicing is done with bash parameter expansion rather than `head -c`, which
# counts BYTES: cutting mid-sequence leaves an orphan continuation byte that
# reaches stdout raw, producing JSON that parses but is not valid UTF-8.
_fix_utf8() {
  local s="$1" _conv
  command -v iconv >/dev/null 2>&1 || { printf '%s' "$s"; return; }
  # Gate on whether iconv produced OUTPUT, not on its exit status. `iconv -c`
  # exits 1 on a TRAILING incomplete sequence while still emitting correct
  # sanitised output — measured: `abc\xc3\xa9\xc3` gives rc=1 and the right 5
  # bytes. An rc test therefore reads "succeeded" as "failed" and hands back the
  # raw invalid string, in precisely the case a byte-boundary slice produces. It
  # was reachable with nothing more exotic than a branch name ending in a stray
  # 0xe9, in the default locale.
  #
  # The X sentinel survives command substitution's trailing-newline stripping and
  # makes "iconv emitted nothing" distinguishable from "iconv emitted empty".
  # That distinction is what preserves the original guard: a broken or missing
  # iconv yielding nothing from non-empty input still returns the raw text rather
  # than blanking the provenance display AC-SEC-4 requires the prompt to show.
  _conv="$(printf '%s' "$s" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null; printf X)"
  _conv="${_conv%X}"
  if [ -n "$_conv" ] || [ -z "$s" ]; then printf '%s' "$_conv"; else printf '%s' "$s"; fi
}

# Sanitise only — length is bounded separately by _window, per key. Splitting
# these two jobs is deliberate: a single head-anchored 400-char cut applied
# before extraction silently hides every key past the cut, and applied after
# extraction offers keys whose provenance text does not contain them. Neither is
# acceptable, so length is applied last and around the match.
_clean() {
  local s c
  # Unconditional, not only after truncation. Truncation is not the only way
  # invalid UTF-8 gets here: a latin-1-encoded commit subject is already invalid
  # before this function sees it, needs no length to be so, and requires no
  # hostility — it is ordinary in older repositories.
  s="$(_fix_utf8 "$1")"
  # LC_ALL=C, and via tr rather than a bash bracket range. A range's endpoints are
  # collation-dependent — the very argument made two lines down for the multibyte
  # set — and single-byte ranges are not exempt under glibc. This one carries more
  # weight than cosmetics: _json_escape handles only backslash and quote, so a
  # control character that survived here would reach stdout unescaped and make the
  # JSON invalid.
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\001-\037\177')"
  # Explicit list rather than a bracket range, for the same reason.
  for c in $'​' $'‌' $'‍' $'‎' $'‏' \
           $' ' $' ' \
           $'‪' $'‫' $'‬' $'‭' $'‮' \
           $'⁦' $'⁧' $'⁨' $'⁩' $'﻿' \
           $'­' $'⁠' $'؜' $'᠎'; do
    s="${s//"$c"/}"
  done
  printf '%s' "$s"
}

# Bound the provenance text to SRC_EXCERPT characters, windowed so the key is
# inside it. Matches jira.sh's ERR_EXCERPT bound on external error text.
#
# A head-anchored excerpt would let a key past character 400 be offered against
# text that does not contain it — the user asked to confirm PROJ-9 against 400
# characters of padding, with the provenance display AC-SEC-4 depends on showing
# nothing that justifies the key. Centring on the match keeps every key
# discoverable AND every key visible in its own evidence.
_window() {
  # Declared separately: bash expands every word on a `local` line before
  # assigning any of them, so `local text="$1" len=${#text}` reads an unset
  # `text` and dies under `set -u`.
  local text="$1" key="$2"
  local len=${#text} pre pos start
  if [ "$len" -le "$SRC_EXCERPT" ]; then
    printf '%s' "$text"; return
  fi
  # Characters before the first occurrence. If the key is absent (it should
  # never be), this yields the whole string and start clamps to the tail.
  pre="${text%%"$key"*}"
  pos=${#pre}
  start=$(( pos - (SRC_EXCERPT - ${#key}) / 2 ))
  [ "$start" -lt 0 ] && start=0
  [ $(( start + SRC_EXCERPT )) -gt "$len" ] && start=$(( len - SRC_EXCERPT ))
  [ "$start" -lt 0 ] && start=0
  # ${#} and the slice count characters in a UTF-8 locale and bytes in C/POSIX;
  # under the latter the cut can split a character, so re-run the UTF-8 pass.
  _fix_utf8 "${text:start:SRC_EXCERPT}"
}

# LC_ALL=C is load-bearing, not decoration. POSIX leaves bracket RANGES
# undefined outside the C locale, and under a collation-order locale [A-Z] can
# match lowercase letters (the aAbBcC… sequence). This grep is the sole
# mechanical enforcement of the shape gate, so it must mean the same thing on
# every host the plugin is installed on — not merely on the CI runner where the
# tests happen to pass.
_extract_keys() {
  LC_ALL=C grep -oE "$KEY_RE" 2>/dev/null \
    | LC_ALL=C grep -E "^.{1,${MAX_KEY_LEN}}\$" 2>/dev/null || true
}

# JSON string escaping without jq — jq may legitimately be absent (AC-4.1),
# and the output contract must hold anyway. Backslash first, or the escapes
# introduced by the later substitutions would themselves be escaped.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Record store
#
# One record per (key, source) pair: key US source US text, where US is the
# unit separator. _clean has already removed it from any text, so it cannot
# appear inside a field. A pair is recorded once — the first occurrence wins,
# which is why the branch's own text survives even when a commit subject
# mentions the same key later.
# ---------------------------------------------------------------------------
US=$'\x1f'
RECORDS=()
KEY_COUNT=0
# Set when the MAX_KEYS ceiling drops a distinct candidate; reported in the JSON
# so the caller never states an exact remainder it cannot know.
#
# Scope, because the name invites a stronger reading: this reports the CANDIDATE
# ceiling only, never the COMMIT_COUNT scan depth. `truncated: false` means
# "nothing was dropped from what was scanned", not "all history was scanned" —
# the commit source deliberately looks at recent subjects only.
TRUNCATED=false

_record() {
  local key="$1" source="$2" text="$3" r rest known=false
  for r in ${RECORDS+"${RECORDS[@]}"}; do
    [ "${r%%"$US"*}" = "$key" ] || continue
    known=true
    rest="${r#*"$US"}"
    [ "${rest%%"$US"*}" = "$source" ] && return 0
  done
  if ! $known; then
    # Drop past the ceiling — but record that it happened. A dropped candidate
    # the caller does not know about turns the prompt's "…and N more" into a
    # false statement, and that line sits inside the provenance display the
    # whole confirmation gate depends on. TRUNCATED surfaces in the JSON so the
    # caller can say "50+" instead of naming a number it cannot know.
    #
    # This is the ONLY place that can set TRUNCATED correctly, because it is the
    # only place that knows whether the key was new. A caller that decides on
    # KEY_COUNT alone overstates: a post-ceiling key that is merely a repeat
    # dropped nothing. Return 2 so the caller can stop iterating without having
    # to make that judgement itself.
    if [ "$KEY_COUNT" -ge "$MAX_KEYS" ]; then
      TRUNCATED=true
      return 2
    fi
    KEY_COUNT=$((KEY_COUNT + 1))
  fi
  RECORDS+=("${key}${US}${source}${US}${text}")
}

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
CONSULTED_BRANCH="empty:unknown"
CONSULTED_SESSION="empty:unknown"
CONSULTED_COMMITS="empty:unknown"

_infer_branch() {
  local branch found
  if $HAVE_BRANCH; then
    branch="$OPT_BRANCH"
  else
    if ! command -v git >/dev/null 2>&1; then
      CONSULTED_BRANCH="empty:no-git"; return 0
    fi
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      CONSULTED_BRANCH="empty:not-a-git-repo"; return 0
    fi
    branch="$(git branch --show-current 2>/dev/null)" || branch=""
  fi
  if [ -z "$branch" ]; then
    # Detached HEAD, or an injected empty value.
    CONSULTED_BRANCH="empty:no-branch"; return 0
  fi
  # Clean BEFORE extracting, never after. Extraction over the full text while
  # the display is bounded to 400 characters lets a key past the cut be offered
  # against provenance text that does not contain it — the user is asked to
  # confirm PROJ-9 against 400 characters of padding, and the display AC-SEC-4
  # relies on shows nothing that justifies the key. Extracting from exactly the
  # text that will be shown makes "every offered key appears verbatim in its own
  # source text" a property of the code rather than a claim about it.
  branch="$(_clean "$branch")"
  # First match only: a branch name carries one ticket, and a second key-shaped
  # token in it is far likelier to be noise than a second real ticket.
  found="$(printf '%s\n' "$branch" | _extract_keys | head -1)"
  if [ -z "$found" ]; then
    CONSULTED_BRANCH="empty:no-key"; return 0
  fi
  _record "$found" "branch" "$(_window "$branch" "$found")"
  CONSULTED_BRANCH="ok"
}

# The registry maps session id -> work identifier, and the value is
# {TICKET}-{slug}, not a bare key — so the extraction runs on the value rather
# than the value being used directly.
_infer_active_sessions() {
  local sessions_file sid value found work_dir

  if [ -n "$OPT_SESSIONS_FILE" ]; then
    sessions_file="$OPT_SESSIONS_FILE"
  else
    # Self-locate from this file rather than from ${CLAUDE_PLUGIN_ROOT}: that
    # variable is substituted into SKILL.md prose before bash runs and is not
    # exported into a Bash-tool-spawned child, so it is unreliable here. It is
    # kept only as a fallback for an unusual install layout.
    #
    # Parameter expansion, not `dirname` — jira.sh:26-30 argues the case in this
    # same directory: dirname is an external binary, and calling one before the
    # dependency preflight lets a restricted PATH emit "command not found" ahead
    # of the real message. Two sibling scripts should not disagree on record
    # about the right idiom.
    local root self="${BASH_SOURCE[0]}"
    case "$self" in
      */*) root="${self%/*}/.." ;;
      *)   root=".." ;;
    esac
    root="$(cd "$root" 2>/dev/null && pwd)" || root=""

    # Verify a dependency of the file we are about to hand control to.
    # resolve-config.sh's config-discovery loop (resolve-config.sh:15-21) walks
    # up the tree with `_d="$(dirname "$_d")"` and terminates on `_d != "/"`.
    # It never checks that dirname exists — and with dirname absent, dirname
    # yields "" forever, the guard never trips, and the loop spins without end.
    # The subshell below contains a crash and any side effect, but a subshell
    # cannot contain a hang, and "always terminates with JSON on stdout" is this
    # script's entire contract. Cheaper to check the dependency than to bound
    # the time: `timeout` would need `bash -c`, and a string-built command is
    # exactly what tests/jira/04-key-inference.test forbids here.
    if ! command -v dirname >/dev/null 2>&1; then
      CONSULTED_SESSION="empty:no-dirname"; return 0
    fi

    # Sourcing happens inside a subshell, and this is deliberate. This script's
    # entire contract is "always exits 0, always prints JSON", and SKILL.md
    # Step 1a consumes that verbatim. Sourcing a file it does not own into a
    # `set -u` shell puts that contract at the mercy of foreign top-level code:
    # resolve-config.sh runs an arithmetic comparison on unexpanded yq output
    # (resolve-config.sh:52), and `[[ "null" -gt 0 ]]` under `set -u` is a fatal
    # unbound-variable error that kills the whole shell before the single
    # printf in main() ever runs. mikefarah yq v4 returns 0 rather than null
    # there, so the current pairing is safe — but "safe because of what the
    # other file happens to do today" is not a contract. The subshell also
    # contains any side effect resolve-config.sh might grow, which turns the
    # read-only guarantee from an assertion into a structural property.
    work_dir="$(
      set +u
      if [ -n "$root" ] && [ -f "$root/resolve-config.sh" ]; then
        # shellcheck source=../resolve-config.sh
        . "$root/resolve-config.sh" >/dev/null 2>&1
      elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
        . "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" >/dev/null 2>&1
      elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
        . "$HOME/.claude/shared/resolve-config.sh" >/dev/null 2>&1
      fi
      # Report whether a configuration.yml was actually found, so the caller
      # can tell "the configured path could not be read" from "there was
      # nothing to read". $CONFIG is set by resolve-config.sh's own discovery.
      command -v resolve_artifact >/dev/null 2>&1 && {
        [ -n "${CONFIG:-}" ] && [ -f "${CONFIG:-}" ] && printf 'cfg:'
        resolve_artifact work work 2>/dev/null
      }
    )" || work_dir=""

    # resolve_artifact is yq-dependent ONLY when a configuration.yml exists:
    # every yq call in it sits behind `[[ -f "$CONFIG" ]]`. With a config
    # present and yq absent, the configured work directory cannot be read, so
    # the session registry may not be where this function would look — say so
    # rather than reporting a confident "no registry".
    #
    # This used to be detected by sniffing for a resolved path of exactly "/":
    # an absent yq left the base and subdir empty, and resolve_artifact returned
    # "/" — absolute, so returned unanchored — and this function would otherwise
    # have stat'd //.active-sessions at the filesystem root. CL-52 fixed that at
    # the source (an empty base now falls back to the default and stays anchored
    # to the workspace), which is strictly better but also means the "/"
    # signature never appears again. The condition is now checked directly
    # instead of inferred from a sentinel path that no longer occurs.
    #
    # The check must stay conditional on a config existing. An unconditional
    # `command -v yq` gate ahead of resolution looked equivalent and was not:
    # the plugin ships no configuration.yml by default and /jira does not
    # otherwise need yq, so that version silently killed the strongest signal —
    # the actual in-flight work session — for every plain install without one.
    local _had_config=false
    case "${work_dir:-}" in
      cfg:*) _had_config=true; work_dir="${work_dir#cfg:}" ;;
    esac

    if $_had_config && ! command -v yq >/dev/null 2>&1; then
      CONSULTED_SESSION="empty:no-yq"; return 0
    fi

    # Empty means resolve_artifact never ran at all — resolve-config.sh
    # unreachable, or the subshell died — where yq is not the cause and saying
    # so would misattribute it; the ordinary default applies instead.
    [ -n "${work_dir:-}" ] || work_dir=".claude/work"
    sessions_file="${work_dir}/.active-sessions"
  fi

  if $HAVE_SESSION_ID; then
    sid="$OPT_SESSION_ID"
  else
    sid="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  fi
  if [ -z "$sid" ]; then
    CONSULTED_SESSION="empty:no-session-id"; return 0
  fi
  if [ ! -s "$sessions_file" ]; then
    CONSULTED_SESSION="empty:no-registry"; return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    CONSULTED_SESSION="empty:no-jq"; return 0
  fi

  # Shared lock. The writers in /implement and /create-requirements serialize
  # on a SEPARATE lock file (.active-sessions.lock, held while they mv the
  # temp file into place) — locking .active-sessions itself would interlock
  # with nothing. Only take it if that file already exists: this helper is a
  # read path and must not create files as a side effect. Reading unlocked is
  # an acceptable fallback, since a torn read costs at most one candidate and
  # the user confirms whatever survives.
  local lock="${sessions_file}.lock" rc=0
  # A leading dash would be read as a flag by flock. Reachable only via a
  # configuration.yml work path starting with "-", but the guard is one test.
  if command -v flock >/dev/null 2>&1 && [ -e "$lock" ] && [ "${lock#-}" = "$lock" ]; then
    # $s is a jq variable, not a shell one. shellcheck exempts jq programs when
    # jq is the outer command; here the outer command is flock, so it needs
    # telling. The unlocked branch below reads identically and needs no pragma.
    # shellcheck disable=SC2016
    value="$(flock -s -w 1 "$lock" jq -r --arg s "$sid" '.[$s] // empty' -- "$sessions_file" 2>/dev/null)" || rc=$?
  else
    value="$(jq -r --arg s "$sid" '.[$s] // empty' -- "$sessions_file" 2>/dev/null)" || rc=$?
  fi
  # A non-zero rc and an empty value mean different things, and the consulted
  # map exists precisely to say which: a corrupt registry or a lock timeout is
  # not "this session has no row". Collapsing them would report the one thing a
  # user could act on as the one thing they cannot.
  if [ "$rc" -ne 0 ]; then
    value=""
    CONSULTED_SESSION="empty:unreadable-registry"; return 0
  fi
  if [ -z "$value" ]; then
    CONSULTED_SESSION="empty:no-entry"; return 0
  fi
  # Cleaned before extraction, for the reason given in _infer_branch.
  value="$(_clean "$value")"
  found="$(printf '%s\n' "$value" | _extract_keys | head -1)"
  if [ -z "$found" ]; then
    # A work identifier that embeds no key — a brainstorm slug, for instance.
    CONSULTED_SESSION="empty:no-key"; return 0
  fi
  _record "$found" "active-session" "$(_window "$value" "$found")"
  CONSULTED_SESSION="ok"
}

_infer_commits() {
  local subjects subject key any=false rc

  if [ -n "$OPT_COMMITS_FILE" ]; then
    [ -r "$OPT_COMMITS_FILE" ] || { CONSULTED_COMMITS="empty:no-commits"; return 0; }
    subjects="$(head -n "$COMMIT_COUNT" -- "$OPT_COMMITS_FILE" 2>/dev/null)"
  else
    if ! command -v git >/dev/null 2>&1; then
      CONSULTED_COMMITS="empty:no-git"; return 0
    fi
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      CONSULTED_COMMITS="empty:not-a-git-repo"; return 0
    fi
    subjects="$(git log --format=%s -n "$COMMIT_COUNT" 2>/dev/null)" || subjects=""
  fi
  if [ -z "$subjects" ]; then
    CONSULTED_COMMITS="empty:no-commits"; return 0
  fi

  # Unlike branch and session, this source may legitimately produce several
  # distinct keys — a branch touching two tickets is ordinary. Each is recorded
  # against the first subject that mentioned it, so the user sees the line the
  # key actually came from rather than a generic label.
  #
  # Work is bounded by stopping AT the ceiling, not by pre-cutting the key list.
  # A `head -n` over the extracted keys looked equivalent and was not: it cuts
  # OCCURRENCES while _record dedupes DISTINCT keys, so a duplicate inside the
  # cut absorbs a slot and the genuinely-dropped keys are removed before _record
  # can see — and therefore report — them. TRUNCATED then reads false while
  # candidates are missing, which is the exact false statement it exists to
  # prevent.
  #
  # Stopping here is both cheaper and exact. Once the ceiling is reached nothing
  # further can be recorded from this source: a new key is dropped, and a key
  # already seen necessarily already carries a `commits` record, since that is
  # the only source this loop writes. The guard sits BEFORE the record, so
  # TRUNCATED is set only when a key actually went unrecorded — a run ending
  # exactly at the ceiling truncated nothing and correctly reports false.
  #
  # Extraction runs over the full sanitised subject; the length bound is applied
  # per key by _window, so no key is hidden by the cut and every key offered
  # appears in the text shown for it (see _infer_branch).
  local cleaned
  while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    cleaned="$(_clean "$subject")"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      # _record decides; the caller only obeys. Deciding here on KEY_COUNT would
      # set TRUNCATED for a post-ceiling key that is merely a repeat, reporting a
      # partial list when nothing was dropped — overstating in the safe direction,
      # but still a claim the data does not support.
      _record "$key" "commits" "$(_window "$cleaned" "$key")"
      rc=$?
      [ "$rc" -eq 2 ] && break 2
      any=true
    done < <(printf '%s\n' "$cleaned" | _extract_keys)
  done < <(printf '%s\n' "$subjects")

  if $any; then CONSULTED_COMMITS="ok"; else CONSULTED_COMMITS="empty:no-key"; fi
}

# ---------------------------------------------------------------------------
# Ordering
#
# Display order only. It never removes a candidate and never resolves a
# disagreement — every distinct key reaches the confirmation prompt regardless
# of where it sorts. Corroboration count descending, ties broken by the
# strongest source: branch, then active-session, then commits. Rank 2 is
# reserved for the conversation signal, which SKILL.md merges in afterwards.
#
# CONTRACT: this ordering is stated twice — here as ranks, and in prose in
# plugin/skills/jira/SKILL.md Step 1a ("branch -> active-session -> conversation
# -> commits"). Nothing checks that the two agree. Change one, change the other.
#
# Assigns to the caller's `rk` rather than printing: this runs once per
# (key, record) pair, and a command substitution here forks a subshell each
# time — the single largest cost in candidate assembly.
# ---------------------------------------------------------------------------
_source_rank_into() {
  case "$1" in
    branch)         rk=0 ;;
    active-session) rk=1 ;;
    commits)        rk=3 ;;
    *)              rk=2 ;;
  esac
}

main() {
  _infer_branch
  _infer_active_sessions
  _infer_commits

  # Distinct keys in insertion order.
  local r key keys=() k seen
  for r in ${RECORDS+"${RECORDS[@]}"}; do
    key="${r%%"$US"*}"
    seen=false
    for k in ${keys+"${keys[@]}"}; do
      [ "$k" = "$key" ] && { seen=true; break; }
    done
    $seen || keys+=("$key")
  done

  # Insertion sort by (-count, min source rank, insertion order). At most a
  # couple of dozen candidates, so an in-shell sort beats spawning `sort`.
  local n=${#keys[@]} i j
  local counts=() ranks=()
  for ((i = 0; i < n; i++)); do
    local c=0 minr=9 rk
    for r in ${RECORDS+"${RECORDS[@]}"}; do
      [ "${r%%"$US"*}" = "${keys[i]}" ] || continue
      c=$((c + 1))
      local rest="${r#*"$US"}"
      _source_rank_into "${rest%%"$US"*}"
      [ "$rk" -lt "$minr" ] && minr="$rk"
    done
    counts+=("$c"); ranks+=("$minr")
  done
  for ((i = 1; i < n; i++)); do
    local ck="${keys[i]}" cc="${counts[i]}" cr="${ranks[i]}"
    j=$((i - 1))
    while [ "$j" -ge 0 ] && { [ "${counts[j]}" -lt "$cc" ] || { [ "${counts[j]}" -eq "$cc" ] && [ "${ranks[j]}" -gt "$cr" ]; }; }; do
      keys[j + 1]="${keys[j]}"; counts[j + 1]="${counts[j]}"; ranks[j + 1]="${ranks[j]}"
      j=$((j - 1))
    done
    keys[j + 1]="$ck"; counts[j + 1]="$cc"; ranks[j + 1]="$cr"
  done

  # --- emit ---
  local out="{\"candidates\":[" first=true
  for ((i = 0; i < n; i++)); do
    $first || out="${out},"
    first=false
    out="${out}{\"key\":\"$(_json_escape "${keys[i]}")\",\"sources\":["
    local sfirst=true
    for r in ${RECORDS+"${RECORDS[@]}"}; do
      [ "${r%%"$US"*}" = "${keys[i]}" ] || continue
      local rest="${r#*"$US"}"
      local src="${rest%%"$US"*}" text="${rest#*"$US"}"
      $sfirst || out="${out},"
      sfirst=false
      out="${out}{\"source\":\"$(_json_escape "$src")\",\"text\":\"$(_json_escape "$text")\"}"
    done
    out="${out}]}"
  done
  out="${out}],\"consulted\":{"
  out="${out}\"branch\":\"$(_json_escape "$CONSULTED_BRANCH")\","
  out="${out}\"active-session\":\"$(_json_escape "$CONSULTED_SESSION")\","
  out="${out}\"commits\":\"$(_json_escape "$CONSULTED_COMMITS")\"},"
  out="${out}\"truncated\":${TRUNCATED}}"
  printf '%s\n' "$out"
}

main
exit 0
