#!/bin/bash
# Hook: SessionStart / SubagentStart — put the cross-session messaging contract
# summary (plugin/shared/agent-messaging.md) into every session and subagent,
# plus three generated lines: where the full contract is, where this project's
# request log is, and the name to sign messages with.
#
# Advisory. It never blocks a start: anything it cannot work out is a one-line
# note on stderr, and the session starts with less context, never with none.

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → disable advisory hooks; keep safety hooks
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="messaging-context"; _nexus_class="advisory"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && exit 0
[ "${NEXUS_HOOK_PROFILE:-full}" = "minimal" ] && [ "$_nexus_class" = "advisory" ] && exit 0
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

set -u
export LC_ALL=C

_hook_dir="${BASH_SOURCE[0]%/*}"
_note() { echo "messaging-context: $1" >&2; }

command -v jq >/dev/null 2>&1 || { _note "jq not found, so no messaging contract summary was added"; exit 0; }

_raw="$(cat)"
_event="$(printf '%s' "$_raw" | jq -r '.hook_event_name // empty' 2>/dev/null)"
case "$_event" in
    SessionStart|SubagentStart) ;;
    *) _note "unexpected hook event '${_event}', so no messaging contract summary was added"; exit 0 ;;
esac
_sid="$(printf '%s' "$_raw" | jq -r '.session_id // empty' 2>/dev/null)"

# ── The summary: the marked section of the shipped contract, and nothing else ─
_shared="$(cd "$_hook_dir/../shared" 2>/dev/null && pwd)"
_contract="$_shared/agent-messaging.md"
[ -n "$_shared" ] && [ -r "$_contract" ] || { _note "cannot read agent-messaging.md, so no summary was added"; exit 0; }
_summary="$(awk '/^<!-- session-summary:end -->$/ { f = 0 } f { print } /^<!-- session-summary:start -->$/ { f = 1 }' "$_contract")"
_lines="$(printf '%s\n' "$_summary" | wc -l)"
if [ -z "$_summary" ] || [ "$_lines" -gt 12 ]; then
    _note "the summary section in agent-messaging.md is empty or longer than 12 lines, so no summary was added"
    exit 0
fi

# ── The request log path ─────────────────────────────────────────────────────
# Resolved here, once, because an ordinary session cannot reach
# resolve-config.sh: CLAUDE_PLUGIN_ROOT is never exported to its Bash calls.
_project="${CLAUDE_PROJECT_DIR:-$PWD}"
_log_dir="$_project/.claude/messages"

# Prints the configured directory, or nothing. Runs in a subshell so the
# resolver's globals and its `cd` stay out of this script.
_configured_log_dir() (
    cd "$_project" 2>/dev/null || exit 0
    # shellcheck source=../shared/resolve-config.sh
    . "$_shared/resolve-config.sh" >/dev/null 2>&1 || { _note "cannot load resolve-config.sh; using the default request log"; exit 0; }
    [ -n "$CONFIG" ] || exit 0
    command -v yq >/dev/null 2>&1 || { _note "yq not found; using the default request log"; exit 0; }
    # Trust the SAME file the resolver reads. CONFIG may be a parent
    # directory's config (a worktree reaches its main checkout's), so testing
    # anything else would vet one file and read another. Same rule as
    # pii-patterns.sh: owned by the current user and not world-writable.
    if [ ! -O "$CONFIG" ] || [ -n "$(find -L "$CONFIG" -perm -002 2>/dev/null)" ]; then
        _note "ignoring $CONFIG (not owned by you, or writable by anyone); using the default request log"
        exit 0
    fi
    _err="$(resolve_artifact_typed messages messages 2>&1 >/dev/null)"
    [ -z "$_err" ] || { _note "storage.artifacts.messages rejected (${_err%%$'\n'*}); using the default request log"; exit 0; }
    _typed="$(resolve_artifact_typed messages messages 2>/dev/null)"
    # A per-machine log, like the task store: a git-typed location is refused.
    [ "${_typed##*|}" != "git" ] || { _note "storage.artifacts.messages points at a git location; using the default request log"; exit 0; }
    printf '%s' "${_typed%|*}"
)
_r="$(_configured_log_dir)"
if [ -n "$_r" ]; then
    # The value lands in every session's context, so only a plain absolute
    # path gets through: an allowlist, not a list of bad characters.
    _re_path='^/[A-Za-z0-9._/~+ -]{0,1023}$'
    if [[ "$_r" =~ $_re_path ]]; then
        _log_dir="$_r"
    else
        _note "the configured request log path is not a plain absolute path; using the default"
    fi
fi

# ── This session's name ──────────────────────────────────────────────────────
_name=""
# shellcheck source=session-registry.sh
if . "$_hook_dir/session-registry.sh" 2>/dev/null; then
    _name="$(nexus_clean_session_name "$(nexus_session_name_for "$_sid")")"
else
    _note "cannot load session-registry.sh, so the session name is unknown"
fi
if [ -n "$_name" ]; then
    _name_line="Your session name: $_name"
else
    _name_line="Your session name: unknown. Ask the user what name to sign messages with before sending one."
fi

_text="$_summary
Full contract: \`$_contract\`
Request log: \`$_log_dir/requests.md\`
$_name_line"

jq -n --arg e "$_event" --arg t "$_text" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $t}}'
exit 0
