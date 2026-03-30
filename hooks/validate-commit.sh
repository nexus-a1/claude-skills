#!/bin/bash
# Hook: Validate git commit messages contain a ticket number
# Pattern: PROJ-123, ABC-1, etc.

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
