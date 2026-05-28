#!/bin/bash
# Hook: Log all tool usage for audit trail

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → disable advisory hooks; keep safety hooks
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="audit"; _nexus_class="advisory"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && exit 0
[ "${NEXUS_HOOK_PROFILE:-full}" = "minimal" ] && [ "$_nexus_class" = "advisory" ] && exit 0
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

LOG_FILE="${HOME}/.claude/tool-audit.log"
LOG_DIR=$(dirname "$LOG_FILE")
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Rotate log if it exceeds max size (truncate to last 10000 lines)
if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$LOG_SIZE" -gt "$MAX_LOG_SIZE" ]]; then
        tail -n 10000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "$LOG_FILE" || rm -f "${LOG_FILE}.tmp"
    fi
fi

# Format: timestamp | session | tool | status
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SESSION="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-unknown}}"
TOOL="${CLAUDE_TOOL_NAME:-unknown}"

echo "${TIMESTAMP} | ${SESSION} | ${TOOL}" >> "$LOG_FILE"

exit 0
