#!/bin/bash
# Hook: Validate git commit messages contain a ticket number
# Pattern: PROJ-123, ABC-1, etc.

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → keep safety hooks (validate-commit is safety)
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="validate-commit"; _nexus_class="safety"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && { echo "WARN: safety hook $_nexus_name disabled via NEXUS_HOOK_PROFILE=off — commit validation inactive" >&2; exit 0; }
# safety hooks are NOT disabled by "minimal" — only "off" reaches them
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) echo "WARN: safety hook $_nexus_name disabled via NEXUS_DISABLED_HOOKS — commit validation inactive" >&2; exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

# Only validate if this is a git commit command
if [[ "$CLAUDE_TOOL_INPUT" =~ git[[:space:]]+commit ]]; then
    # Store HEREDOC pattern in variable for portable newline matching across bash versions
    HEREDOC_PATTERN=$'cat[[:space:]]+<<.*\n([^\n]+)'

    # Extract commit message from -m flag (simple format)
    if [[ "$CLAUDE_TOOL_INPUT" =~ -m[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
        MESSAGE="${BASH_REMATCH[1]}"
    elif [[ "$CLAUDE_TOOL_INPUT" =~ -m[[:space:]]+([^[:space:]]+) ]]; then
        MESSAGE="${BASH_REMATCH[1]}"
    # Extract first line from HEREDOC format: -m "$(cat <<'EOF' ... EOF )"
    elif [[ "$CLAUDE_TOOL_INPUT" =~ $HEREDOC_PATTERN ]]; then
        MESSAGE="${BASH_REMATCH[1]}"
    else
        # No -m flag found, allow (might be interactive or amend)
        exit 0
    fi

    # Trim leading whitespace from message
    MESSAGE="${MESSAGE#"${MESSAGE%%[![:space:]]*}"}"

    # Check for ticket pattern (e.g., PROJ-123, ABC-1)
    if [[ ! "$MESSAGE" =~ [A-Z]+-[0-9]+ ]]; then
        echo "BLOCKED: Commit message must contain a ticket number (e.g., PROJ-123)"
        echo "Message: $MESSAGE"
        exit 2
    fi
fi

exit 0
