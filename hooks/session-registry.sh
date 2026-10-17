#!/bin/bash
# Library: read Claude Code's live session registry ($HOME/.claude/sessions/*.json)
# and apply the messaging contract's name rule. Sourced by messaging-context.sh
# and message-guard.sh, so the name a session is told to sign with and the name
# the send check expects are cleaned by one function from the same bytes.
#
# Undocumented Claude Code state, recorded against 2.1.302 (see hook-profiles.md).
# Only *.json is read: the *.key files beside them are private and never opened.
# Every reader degrades to "nothing found"; none of them fails a hook.

# Print the registered name of session $1, raw, or nothing.
nexus_session_name_for() {
    local sid="${1:-}" f n
    [ -n "$sid" ] && [ -d "$HOME/.claude/sessions" ] || return 0
    for f in "$HOME"/.claude/sessions/*.json; do
        [ -f "$f" ] || continue
        n="$(jq -r --arg s "$sid" 'select(.sessionId == $s) | .name // empty' "$f" 2>/dev/null)"
        [ -n "$n" ] && { printf '%s' "$n"; return 0; }
    done
    return 0
}

# Succeed when $1 is exactly the name of a live session.
nexus_is_session_name() {
    local target="${1:-}" f
    [ -n "$target" ] && [ -d "$HOME/.claude/sessions" ] || return 1
    for f in "$HOME"/.claude/sessions/*.json; do
        [ -f "$f" ] || continue
        jq -e --arg t "$target" '.name == $t' "$f" >/dev/null 2>&1 && return 0
    done
    return 1
}

# The contract's name rule: only [A-Za-z0-9._-] (anything else becomes -),
# starting with a letter or digit, at most 64 characters. Prints the cleaned
# name, which may be empty.
nexus_clean_session_name() {
    local n
    n="$(printf '%s' "${1:-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
    n="${n#"${n%%[A-Za-z0-9]*}"}"
    printf '%s' "${n:0:64}"
}
