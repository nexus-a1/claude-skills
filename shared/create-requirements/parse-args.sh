#!/usr/bin/env bash
# plugin/shared/create-requirements/parse-args.sh
#
# Deterministic argument parser for /create-requirements.
#
# The skill used to read its arguments as prose and take the first
# ticket-shaped word it found anywhere as the ticket, so a description that
# said "fix UTF-8 handling" or "follow-up to PROJ-150" started a session on the
# wrong ticket. This script makes that decision once, in code, and the skill
# acts on the JSON verdict it prints.
#
# Usage:
#   bash parse-args.sh --op parse --input <dir>   # reads <dir>/arguments
#   bash parse-args.sh --op usage
#
# The argument text arrives as a file the skill writes with the Write tool,
# never as argv: the skill runtime pastes the arguments into the skill text
# before bash runs, so a backtick or $( ) in a description would execute if it
# ever reached a command line. Nothing here evals the text or word-splits it
# into a command.
#
# Grammar: options are read only at the START of the arguments. Every leading
# token that begins with `--` is an option; the first token that does not ends
# option parsing, and everything from there on is the description, verbatim.
#
#   --help                    print usage and stop (beats every error)
#   --light                   lightweight mode
#   --no-ticket               draft session, no ticket yet
#   --ticket <KEY>            the ticket, any case, stored uppercase
#   --from-brainstorm [slug]  seed from a brainstorm (bare flag = picker)
#   --from-meeting [ref]      seed from a meeting (bare flag = picker)
#
# Bare-key shortcut: with neither --ticket nor --no-ticket, a remainder that is
# exactly one ticket key is the ticket and the description is empty. That is
# also what keeps the older `--from-brainstorm <slug> <KEY>` handoff working.
#
# Output (stdout, one JSON object):
#   {"ok":true,"help":true}                                       exit 0
#   {"ok":true,"help":false,"ticket":"PROJ-1"|null,"no_ticket":bool,
#    "light":bool,"from_brainstorm":"slug"|""|null,
#    "from_meeting":"ref"|""|null,"reconcile":bool,
#    "description":"..."}                                          exit 0
#   {"ok":false,"error":"..."}                                     exit 20
#   exit 30 with a message on stderr: the input itself is unusable. The
#   caller stops; a parser that could not read the arguments has decided
#   nothing, and "no ticket" is a decision.
#
# "reconcile" is true only for the exact `reconcile <draft-id> <ticket-id>`
# shape with no option ahead of it: Reconcile reads the raw arguments file
# word by word, so a leading option would shift its identifiers by one.
set -uo pipefail
# Byte-wise matching: under a UTF-8 locale bash's [A-Za-z] also matches é and
# friends, which would let a non-ASCII "key" name a work directory and a branch.
export LC_ALL=C

# Same codes as plugin/shared/tasks/tasks.sh and plugin/shared/release/lib.sh.
EX_USER=20
EX_SYSTEM=30
# Same ceiling as plugin/shared/jira/key-inference.sh's MAX_KEY_LEN.
MAX_KEY_LEN=32
# The key SHAPE deliberately does not follow key-inference.sh's KEY_RE
# ([A-Z][A-Z0-9]+-[0-9]+). A ticket becomes a work directory and a branch
# name, and the naming rule in plugin/CLAUDE.md, tasks.sh parse-handoff and
# draft-reconcile all use [A-Z]+-[0-9]+. So a project key with digits (AB2-5)
# is refused here, and a key Jira itself rejects (A-1) only skips the fetch.

_die() { echo "parse-args.sh: ${1}" >&2; exit "$EX_SYSTEM"; }

_is_key() {
  local v="${1}"
  [ "${#v}" -le "$MAX_KEY_LEN" ] && [[ "$v" =~ ^[A-Za-z]+-[0-9]+$ ]]
}

# A brainstorm slug or meeting ref is later substituted into a skill's shell
# fences, so only plain name characters get through: no quote, $, backtick,
# space or slash. Slugs are kebab-case and meeting refs are slugs or
# timestamped directory names, so both fit.
_is_name() { [[ "${1}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

_trimmed() {
  local v="${1}"
  v="${v#"${v%%[![:space:]]*}"}"
  printf '%s' "${v%"${v##*[![:space:]]}"}"
}

_upper() { printf '%s' "${1}" | LC_ALL=C tr '[:lower:]' '[:upper:]'; }

_usage() {
  cat <<'USAGE'
Usage:
  /create-requirements [options] [feature description]
  /create-requirements <TICKET-KEY>
  /create-requirements reconcile <draft-id> <ticket-id>
  /create-requirements --from-task <id>      (sent by /todo-work, not typed by hand)

Options (only at the start; anything after the first non-option word is the
description, so option words inside a description do nothing):
  --help                    Print this help and stop. Nothing is started.
  --ticket <KEY>            The ticket for this work, e.g. --ticket PROJ-123.
                            Any case is accepted and stored uppercase.
  --no-ticket               Start a DRAFT-<slug> session with no ticket, no
                            branch and no push. Cannot be combined with --ticket.
  --light                   Cheaper run (see the skill for what it changes).
  --from-brainstorm [slug]  Seed from a saved brainstorm. Without a slug, pick one.
  --from-meeting [ref]      Seed from a wrapped meeting. Without a ref, pick one.
                            The word after either flag is its slug, so to get
                            the picker put the flag last or before another option.

Ticket:
  The ticket comes from --ticket, or from the ticket question. A ticket key
  inside the description (UTF-8, "follow-up to PROJ-150") is never the ticket.
  Shortcut: with neither --ticket nor --no-ticket, an argument that is exactly
  one ticket key is the ticket (/create-requirements PROJ-12).
  An unknown option at the start is an error.

Reconcile:
  reconcile <draft-id> <ticket-id> renames a DRAFT session to a real ticket,
  asks for a base branch, and stops.

A run writes, under <work dir>/<TICKET>-<slug>/: state.json, context/,
spec.md, plan.md, tasks.md and <TICKET>-<slug>-JIRA_TICKET.md. It creates
and pushes branch feature/<TICKET>-<slug> (not for --no-ticket). It never
implements anything; run /implement next.
USAGE
}

_parse() {
  local input="" text rest tok
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --input) input="${2:-}"; shift 2 || shift ;;
      *) _die "unknown option '${1}'" ;;
    esac
  done
  [ -n "$input" ] || _die "--input <dir> is required"
  { [ -d "$input" ] && [ ! -L "$input" ]; } || _die "not a directory: '$input'"
  { [ -f "$input/arguments" ] && [ ! -L "$input/arguments" ]; } \
    || _die "$input/arguments is missing"
  text="$(cat "$input/arguments")" || _die "could not read $input/arguments"

  local help=false light=false no_ticket=false ticket="" ticket_seen=false
  local from_brainstorm="" from_meeting="" fb_given=false fm_given=false err=""
  rest="$text"
  # Each step: drop leading whitespace, take one token, consume it if it is an
  # option. ${rest#"$tok"} strips the token as a literal, not a pattern.
  _next() {
    rest="${rest#"${rest%%[![:space:]]*}"}"
    tok="${rest%%[[:space:]]*}"
  }
  _take() { rest="${rest#"$tok"}"; }
  # An option value is the next token unless it is another option or absent.
  _value() {
    _take; _next
    if [ -z "$tok" ] || [[ "$tok" == --* ]]; then
      return 1
    fi
    _take
  }
  while :; do
    _next
    [[ "$tok" == --* ]] || break
    case "$tok" in
      --help) help=true; _take ;;
      --light) light=true; _take ;;
      --no-ticket) no_ticket=true; _take ;;
      --ticket)
        if [ "$ticket_seen" = true ]; then
          [ -n "$err" ] || err="--ticket is given more than once"
        fi
        ticket_seen=true
        if _value; then
          if _is_key "$tok"; then
            ticket="$(_upper "$tok")"
          else
            [ -n "$err" ] || err="--ticket '$tok' is not a ticket key (letters, a hyphen, digits; at most $MAX_KEY_LEN characters, e.g. PROJ-123)"
          fi
        else
          [ -n "$err" ] || err="--ticket needs a value, e.g. --ticket PROJ-123"
        fi
        ;;
      --from-brainstorm)
        fb_given=true
        if _value; then
          from_brainstorm="$tok"
          _is_name "$tok" || { [ -n "$err" ] || err="--from-brainstorm '$tok' is not a brainstorm slug"; }
        fi ;;
      --from-meeting)
        fm_given=true
        if _value; then
          from_meeting="$tok"
          _is_name "$tok" || { [ -n "$err" ] || err="--from-meeting '$tok' is not a meeting slug or directory name"; }
        fi ;;
      *)
        [ -n "$err" ] || err="unknown option '$tok'; run /create-requirements --help"
        _take ;;
    esac
  done

  if [ "$help" = true ]; then
    jq -nc '{ok: true, help: true}'
    return 0
  fi
  if [ -z "$err" ] && [ "$ticket_seen" = true ] && [ "$no_ticket" = true ]; then
    err="--ticket and --no-ticket cannot be combined"
  fi
  if [ -n "$err" ]; then
    jq -nc --arg e "$err" '{ok: false, error: $e}'
    return "$EX_USER"
  fi

  # Trim the description, keeping its inside exactly as typed.
  rest="${rest#"${rest%%[![:space:]]*}"}"
  rest="${rest%"${rest##*[![:space:]]}"}"
  local reconcile=false w1 w3 w4
  # The raw text must also START with the word: Reconcile reads the file's
  # first line, and a leading blank line would hand it three empty values.
  if [ "$rest" = "$(_trimmed "$text")" ] && [ -z "${text%%[![:space:]]*}" ]; then
    read -r w1 _ w3 w4 <<< "$rest"
    if [ "$w1" = reconcile ] && [ -n "$w3" ] && [ -z "$w4" ] && [[ "$rest" != *$'\n'* ]]; then
      reconcile=true
    fi
  fi
  if [ "$ticket_seen" = false ] && [ "$no_ticket" = false ] && _is_key "$rest"; then
    ticket="$(_upper "$rest")"
    rest=""
  fi

  jq -nc \
    --arg ticket "$ticket" \
    --argjson no_ticket "$no_ticket" \
    --argjson light "$light" \
    --arg fb "$from_brainstorm" --argjson fb_given "$fb_given" \
    --arg fm "$from_meeting" --argjson fm_given "$fm_given" \
    --argjson reconcile "$reconcile" \
    --arg desc "$rest" \
    '{ok: true, help: false,
      ticket: (if $ticket == "" then null else $ticket end),
      no_ticket: $no_ticket, light: $light,
      from_brainstorm: (if $fb_given then $fb else null end),
      from_meeting: (if $fm_given then $fm else null end),
      reconcile: $reconcile,
      description: $desc}'
}

command -v jq >/dev/null 2>&1 || _die "jq is required"
op=""
if [ "${1:-}" = "--op" ]; then op="${2:-}"; shift 2 || shift; fi
case "$op" in
  parse) _parse "$@" ;;
  usage) _usage ;;
  *) _die "usage: parse-args.sh --op <parse|usage> [--input <dir>]" ;;
esac
