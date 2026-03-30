#!/bin/bash
# Hook: Log all tool usage for audit trail

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
SESSION="${CLAUDE_SESSION_ID:-unknown}"
TOOL="${CLAUDE_TOOL_NAME:-unknown}"

echo "${TIMESTAMP} | ${SESSION} | ${TOOL}" >> "$LOG_FILE"

exit 0
