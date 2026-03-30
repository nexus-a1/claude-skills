#!/bin/bash
# Hook: Send desktop notification when Claude finishes a task

TITLE="Claude Code"
MESSAGE="Task completed"

# Linux (notify-send)
if command -v notify-send &>/dev/null; then
    notify-send "$TITLE" "$MESSAGE" --icon=dialog-information 2>/dev/null
# macOS (osascript)
elif command -v osascript &>/dev/null; then
    osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" 2>/dev/null
fi

exit 0
