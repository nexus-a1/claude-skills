#!/bin/bash
# Hook: PreToolUse SendMessage — refuse a message to ANOTHER SESSION that breaks
# the messaging contract (plugin/shared/agent-messaging.md): a bad or missing
# header, or more than 5 lines. The reason goes back to the model so it can
# rewrite the message.
#
# Advisory, but it blocks on content — a new kind of hook; see hook-profiles.md.
# It only checks a target it can POSITIVELY identify as another session, and it
# lets the message through whenever the check itself cannot run. Teammates,
# subagents, "main", broadcasts and unknown names are never checked.

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → disable advisory hooks; keep safety hooks
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="message-guard"; _nexus_class="advisory"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && exit 0
[ "${NEXUS_HOOK_PROFILE:-full}" = "minimal" ] && [ "$_nexus_class" = "advisory" ] && exit 0
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

set -u
export LC_ALL=C

_note() { echo "message-guard: $1 — message sent unchecked" >&2; }

command -v jq >/dev/null 2>&1 || { _note "jq not found"; exit 0; }

# Read the fields here rather than through hook_read_input: that reader is
# fail-closed and expects a Bash `command`, which a SendMessage payload lacks.
_raw="$(cat)"
_tool="$(printf '%s' "$_raw" | jq -r '.tool_name // empty' 2>/dev/null)" || { _note "unreadable payload"; exit 0; }
[ "$_tool" = "SendMessage" ] || exit 0

# One jq call per field: `read` with a tab IFS merges empty fields (tab is
# whitespace to IFS), which shifted an empty `to` onto the next value.
_to="$(printf '%s' "$_raw" | jq -r '.tool_input.to | if type == "string" then . else "" end' 2>/dev/null)" || { _note "unexpected payload shape"; exit 0; }
_msg_type="$(printf '%s' "$_raw" | jq -r '.tool_input.message | type' 2>/dev/null)" || { _note "unexpected payload shape"; exit 0; }
_sid="$(printf '%s' "$_raw" | jq -r '.session_id // ""' 2>/dev/null)"

# Protocol messages (shutdown, plan approval) are objects; an empty message is a
# pure idle subscription. Neither carries text to check.
[ "$_msg_type" = "string" ] || exit 0
_msg="$(printf '%s' "$_raw" | jq -r '.tool_input.message' 2>/dev/null)" || { _note "unreadable message"; exit 0; }
[ -n "$_msg" ] || exit 0
[ -n "$_to" ] || { _note "no string 'to' in the payload"; exit 0; }

# ── Is the target another session? ───────────────────────────────────────────
# `to` may carry a " [ref]" disambiguator after the name.
_target="${_to% \[*\]}"
# shellcheck source=session-registry.sh
. "${BASH_SOURCE[0]%/*}/session-registry.sh" 2>/dev/null || { _note "cannot load session-registry.sh"; exit 0; }
_is_session=false
# "main" is a background subagent's parent conversation, never a peer session,
# even when a live session happens to carry that name.
[ "$_target" = "main" ] && exit 0
case "$_target" in uds:*) _is_session=true ;; *) nexus_is_session_name "$_target" && _is_session=true ;; esac
$_is_session || exit 0

# A name that is also a member of any team is treated as a teammate. This can
# only let more messages through, so stale team configs are harmless.
case "$_target" in uds:*) ;; *)
    for _f in "$HOME"/.claude/teams/*/config.json; do
        [ -f "$_f" ] || continue
        jq -e --arg t "$_target" 'any(.members[]?; .name == $t)' "$_f" >/dev/null 2>&1 && exit 0
    done
;; esac

# The sending session's name, cleaned by the same function that told the
# session what to sign with (messaging-context.sh).
_sender_name="$(nexus_clean_session_name "$(nexus_session_name_for "$_sid")")"

# ── Check the message ────────────────────────────────────────────────────────
_problems=()
_header="${_msg%%$'\n'*}"
_header="${_header%$'\r'}"

_types="REQUEST, ACK, DONE, BLOCKED, INFO"
_re_type='^\[([A-Za-z]+) '
_re_full='^\[(REQUEST|ACK|DONE|BLOCKED|INFO) +#([A-Za-z0-9][A-Za-z0-9._-]{0,63})-([0-9]{17})\] +from: +([A-Za-z0-9][A-Za-z0-9._-]{0,63}) +(->|→) +to: +(.+)$'

_t=""
[[ "$_header" =~ $_re_type ]] && _t="${BASH_REMATCH[1]}"
if [ -z "$_t" ]; then
    _problems+=("The first line is not a contract header.")
elif case " $_types," in *" $_t,"*) false ;; *) true ;; esac; then
    _problems+=("TYPE '$_t' is not valid. Use one of: $_types (in capitals).")
elif [[ ! "$_header" =~ $_re_full ]]; then
    # Name the first part that broke, not a catch-all.
    _name_re='[A-Za-z0-9][A-Za-z0-9._-]{0,63}'
    if [[ ! "$_header" =~ ^\[[A-Z]+\ +#${_name_re}-[0-9]{17}\]\  ]]; then
        _problems+=("The ID must be ORIGIN-<17 digits of UTC time> (\`date -u +%Y%m%d%H%M%S%3N\`), ORIGIN 1-64 of [A-Za-z0-9._-] starting with a letter or digit, then \`]\` and a space.")
    elif [[ ! "$_header" =~ \]\ +from:\ +${_name_re}\  ]]; then
        _problems+=("'from: SENDER' is missing or SENDER is not 1-64 of [A-Za-z0-9._-] starting with a letter or digit.")
    elif [[ ! "$_header" =~ \ +from:\ +${_name_re}\ +(->|→)\  ]]; then
        _problems+=("The arrow after SENDER must be → or -> with a space on each side.")
    else
        _problems+=("'to: RECEIVER' is missing.")
    fi
else
    _type="${BASH_REMATCH[1]}"; _origin="${BASH_REMATCH[2]}"; _from="${BASH_REMATCH[4]}"
    _recv="${BASH_REMATCH[6]}"; _recv="${_recv%"${_recv##*[! ]}"}"
    [ -n "$_recv" ] || _problems+=("RECEIVER after 'to:' is empty.")
    # Characters, not bytes: a session title in Polish or with an emoji is fine.
    _recv_len="$( { LC_ALL=C.UTF-8; } 2>/dev/null; printf '%s' "${#_recv}" )"
    [ "${_recv_len:-0}" -le 200 ] || _problems+=("RECEIVER is longer than 200 characters.")
    if [ "$_type" = "REQUEST" ] || [ "$_type" = "INFO" ]; then
        [ "$_origin" = "$_from" ] || _problems+=("On a $_type the ID must start with your own name: '$_origin' is not '$_from'.")
    fi
    if [ -n "$_sender_name" ] && [ "$_from" != "$_sender_name" ]; then
        _problems+=("'from:' must be this session's registered name, '$_sender_name', not '$_from'.")
    fi
fi

# Lines, header included, with trailing newlines ignored.
_body="${_msg%"${_msg##*[!$'\n']}"}"
_nl="${_body//[!$'\n']/}"
_lines=$(( ${#_nl} + 1 ))
[ "$_lines" -le 5 ] || _problems+=("The message has $_lines lines; the limit is 5, header included. Put the details in a file and send its path.")

[ "${#_problems[@]}" -eq 0 ] && exit 0

# The reason never echoes the message body.
{
    echo "BLOCKED: this SendMessage goes to another session and breaks the messaging contract (agent-messaging.md in the nexus plugin's shared/):"
    printf -- '- %s\n' "${_problems[@]}"
    _me="${_sender_name:-<your-session-name>}"
    echo "Expected first line, e.g.: [REQUEST #${_me}-<YYYYMMDDHHMMSSmmm>] from: ${_me} -> to: <receiver>"
    echo "Rewrite the message and send it again."
} >&2
exit 2
