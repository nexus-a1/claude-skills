#!/bin/bash
# Hook: Send desktop notification when Claude finishes a task

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → disable advisory hooks; keep safety hooks
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="notify"; _nexus_class="advisory"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && exit 0
[ "${NEXUS_HOOK_PROFILE:-full}" = "minimal" ] && [ "$_nexus_class" = "advisory" ] && exit 0
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

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
