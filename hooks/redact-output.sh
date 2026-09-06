#!/bin/bash
# redact-output.sh — PreToolUse hook on Bash: rewrite the command so its
# stdout and stderr stream through redact-stream.sh before the tool captures
# them. The model receives the shape of the output with every secret replaced
# by a stable <REDACTED:kind:n> placeholder; the value itself never enters the
# conversation. Subagents and workflow agents go through the same hook, so
# one registration covers the review panels too.
#
# WHY A REWRITE AND NOT A POST-FILTER
#
# A PostToolUse hook cannot change what a built-in tool returned; only MCP
# tools have that field. PreToolUse can rewrite the tool's INPUT
# (hookSpecificOutput.updatedInput), and a Bash command can be made to filter
# its own output. So the only place to put a redactor is inside the command.
#
# WHAT THE REWRITE LOOKS LIKE
#
#     exec > >(bash /…/redact-stream.sh --map /…/redaction-map.tsv) 2>&1  # nexus-redact
#     _nexus_redact_pid=$!; trap '<close fds; bounded wait>' EXIT
#     <the original command, untouched>
#
# `exec >` moves the shell's own stdout/stderr, so there is no subshell around
# the user's command: `cd` still persists to the next call, and `$?` and
# `exit N` are the command's own. The EXIT trap closes the descriptors and
# waits for the filter to drain — measured: without it the shell can exit
# before the filter has written, and the output is lost. The wait is bounded
# (5 s) because a process the command left running with the pipe inherited
# (`sleep 100 &`) would otherwise hold the trap forever; whatever that
# process prints later still passes through the filter, it just arrives
# after the tool has stopped listening.
#
# ONE WRITER. Claude Code runs the PreToolUse hooks for a call in parallel,
# each on the ORIGINAL input, and when two return updatedInput "the last one
# to finish takes effect" — non-deterministic. So this hook is the only hook
# that returns updatedInput for Bash: it runs bash-token-filter.py itself,
# takes its quiet-flag rewrite as the starting point, and wraps that. The
# token filter is no longer registered on its own in hooks.json for exactly
# this reason; its NEXUS_DISABLED_HOOKS name still works, because the script
# checks its own kill-switch.
#
# FAILS CLOSED where it can: a missing or non-executable redact-stream.sh
# blocks the call (exit 2) rather than letting it run unfiltered. Inside the
# rewritten command, a filter that cannot load its patterns withholds output
# rather than passing it through (see redact-stream.sh).
#
# What this cannot cover, stated so nobody assumes it: the Read tool's own
# result (read-guard.sh refuses sensitive files and redirects to cat), Grep
# and Glob results, @file mentions and pasted text, and the command text
# itself — a secret the model writes into a command was already in context.

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → keep safety hooks (redact-output is safety)
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="redact-output"; _nexus_class="safety"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && { echo "WARN: safety hook $_nexus_name disabled via NEXUS_HOOK_PROFILE=off — Bash output is NOT redacted" >&2; exit 0; }
# safety hooks are NOT disabled by "minimal" — only "off" reaches them
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) echo "WARN: safety hook $_nexus_name disabled via NEXUS_DISABLED_HOOKS — Bash output is NOT redacted" >&2; exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

set -u

# Absolute, because the path is written into the rewritten command, and that
# command runs wherever the session's cwd is — not where this hook was found.
_hook_dir="${BASH_SOURCE[0]%/*}"
_hook_dir="$(cd "$_hook_dir" 2>/dev/null && pwd -P)" || {
    echo "BLOCKED: redact-output cannot resolve its own directory (${BASH_SOURCE[0]%/*})." >&2
    exit 2
}

# jq BEFORE anything else, and fail closed without it. hook-input.sh's own
# no-jq branch is scoped to the git guard: a payload with no "git" in it
# resets every variable and returns 0, so this hook would exit 0 silently
# and the WARN it meant to print would never appear. A safety hook that is
# absent without saying so is the failure this whole file exists to prevent,
# so a jq-less machine blocks the call and says how to opt out.
if ! command -v jq >/dev/null 2>&1; then
    echo "BLOCKED: redact-output needs jq to rewrite the command and jq is not installed — refusing to run the command unredacted." >&2
    echo "Install jq, or disable this hook explicitly: NEXUS_DISABLED_HOOKS=redact-output" >&2
    exit 2
fi

# Read the payload once, keep the raw text: bash-token-filter.py needs it too.
_raw="$(cat 2>/dev/null || true)"

# shellcheck source=hook-input.sh
. "$_hook_dir/hook-input.sh" || {
    echo "BLOCKED: redact-output could not load its input contract (hooks/hook-input.sh)." >&2
    exit 2
}
type hook_read_input >/dev/null 2>&1 || {
    echo "BLOCKED: redact-output loaded hooks/hook-input.sh but hook_read_input is not defined." >&2
    exit 2
}
# Not our tool: leave before the contract judges the payload. The contract
# blocks a command-less payload from any tool it does not know, which is
# right for a Bash hook and wrong for a Grep call that a mis-set matcher
# routed here.
_tool="$(printf '%s' "$_raw" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ -z "$_tool" ] || [ "$_tool" = "Bash" ] || exit 0

# The contract reads stdin; feed it the text already read, byte for byte. A
# here-string would append a newline, and an empty payload would then reach
# the contract as "\n" — which jq 1.6 (Debian 12) parses as nothing and
# reports as success, so the contract's empty-input block never fired on the
# CI runner. Process substitution adds nothing.
hook_read_input "$_nexus_name" < <(printf '%s' "$_raw") || exit 2

[ "${HOOK_TOOL_NAME:-}" = "Bash" ] || exit 0

_cmd="${HOOK_COMMAND:-}"
[ -n "$_cmd" ] || exit 0

_stream="$_hook_dir/redact-stream.sh"
if [ ! -f "$_stream" ] || [ ! -r "$_stream" ]; then
    echo "BLOCKED: redact-output cannot find its filter at $_stream — refusing to run the command unfiltered." >&2
    echo "Reinstall the nexus plugin, or disable this hook explicitly: NEXUS_DISABLED_HOOKS=redact-output" >&2
    exit 2
fi

# Both paths are written into a command that will be executed. Single-quoted
# there, with any single quote in the path closed, escaped and reopened, so
# a directory named with $(…), a backtick or a double quote is a name and
# never code. A newline cannot be quoted into one line: refuse it.
case "$_stream" in *$'\n'*)
    echo "BLOCKED: redact-output's own path contains a newline; refusing to build a command from it." >&2
    exit 2 ;;
esac
_sq() { local q="'"; printf "%s" "$q${1//$q/$q\\$q$q}$q"; }
_stream_q="$(_sq "$_stream")"


# Quiet-flag rewrite first, so this stays the single writer of updatedInput.
# Advisory: a missing python3 or a filter that says nothing leaves the
# command as it was. Its own kill-switch is honoured inside the script.
_context=""
if command -v python3 >/dev/null 2>&1 && [ -f "$_hook_dir/bash-token-filter.py" ]; then
    _tf_out="$(printf '%s' "$_raw" | python3 "$_hook_dir/bash-token-filter.py" pre 2>/dev/null || true)"
    if [ -n "$_tf_out" ]; then
        _tf_cmd="$(printf '%s' "$_tf_out" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)"
        [ -n "$_tf_cmd" ] && _cmd="$_tf_cmd"
        _context="$(printf '%s' "$_tf_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
    fi
fi

# The session map lives with the repository the session is in, under
# .claude/session-state/. Outside a repository it lives under the same
# subdirectory of the user's own ~/.claude — a subdirectory this hook owns,
# never ~/.claude itself, because the `*` .gitignore written beside the map
# would otherwise ignore the user's whole config directory. Created here,
# mode 0600, so the filter never has to.
_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$_root" ]; then
    _state="$_root/.claude/session-state"
else
    _state="${HOME:-/tmp}/.claude/session-state"
fi
_map="$_state/redaction-map.tsv"
# The map holds every value the session redacted, in clear, so that later
# output can be redacted consistently. Three things keep it from leaving:
# mode 0600; a .gitignore of `*` beside it, because a user's project has no
# reason to ignore .claude/session-state/ and `git add -A` would stage it;
# and read-guard, whose sensitive-path list names it.
( umask 077
  mkdir -p "$_state" 2>/dev/null || exit 1
  [ -e "$_state/.gitignore" ] || printf '*\n' > "$_state/.gitignore"
  [ -e "$_map" ] || : > "$_map"
) 2>/dev/null || _map=""
case "$_map" in *$'\n'*) _map="" ;; esac
_map_q=""
[ -n "$_map" ] && _map_q="$(_sq "$_map")"

# The prelude. Single-quoted trap body: it must survive into the shell that
# runs the command with its variables intact. The bounded wait polls the
# filter's pid rather than calling `wait` unbounded.
# `$!` after a process substitution is set by bash 5.0 and later. On an
# older bash it is empty or a stale job's pid, so the trap only polls when
# it holds something and otherwise settles for a moment.
_prelude="exec > >(bash $_stream_q"
[ -n "$_map_q" ] && _prelude="$_prelude --map $_map_q"
_prelude="$_prelude) 2>&1  # nexus-redact
_nexus_redact_pid=\$!; trap 'exec 1>&- 2>&-; if [ -n \"\$_nexus_redact_pid\" ]; then _i=0; while kill -0 \"\$_nexus_redact_pid\" 2>/dev/null && [ \$_i -lt 50 ]; do sleep 0.1; _i=\$((_i+1)); done; else sleep 0.3; fi' EXIT"

# Already wrapped: the command's FIRST LINE is exactly the prelude this run
# would emit — the filter by its quoted absolute path, the map, the 2>&1,
# nothing missing and nothing added. A prefix match let a hand-built
# prelude that dropped the `2>&1` pass unwrapped with stderr in clear;
# anything that is not the exact line — a stray "# nexus-redact" comment,
# a partial prelude — is wrapped. The skip is announced so a re-run is
# visible in the transcript.
if [ "${_cmd%%$'\n'*}" = "${_prelude%%$'\n'*}" ]; then
    echo "redact-output: command already carries the redaction prelude; not wrapping twice." >&2
    exit 0
fi

_new="$_prelude
$_cmd"

jq -nc --arg c "$_new" --arg x "$_context" '
    {hookSpecificOutput: ({hookEventName: "PreToolUse", updatedInput: {command: $c}}
        + (if $x == "" then {} else {additionalContext: $x} end))}'
exit 0
