#!/bin/bash
# Hook: PostToolUse — auto-append context entries to the active work session's state.json
# Registered in hooks.json under PostToolUse with matcher Edit|Write|MultiEdit|Task|NotebookEdit.
# Contract: never write to stdout, never block a tool — exit 0 on every path.

LOG_FILE="${HOME}/.claude/auto-context-errors.log"
LOG_DIR=$(dirname "$LOG_FILE")
MAX_LOG_SIZE=$((1 * 1024 * 1024))  # 1MB

log_err() {
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    if [[ -f "$LOG_FILE" ]]; then
        local sz
        sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$sz" -gt "$MAX_LOG_SIZE" ]]; then
            tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || rm -f "${LOG_FILE}.tmp"
        fi
    fi
    printf '%s auto-context: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

command -v jq >/dev/null 2>&1 || exit 0

STDIN=$(cat 2>/dev/null)
[[ -n "$STDIN" ]] || exit 0

SESSION_ID=$(jq -r '.session_id // empty' <<<"$STDIN" 2>/dev/null)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$STDIN" 2>/dev/null)
[[ -n "$SESSION_ID" && -n "$TOOL_NAME" ]] || exit 0

if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" || { log_err "source resolve-config failed"; exit 0; }
elif [[ -f "$HOME/.claude/shared/resolve-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.claude/shared/resolve-config.sh" || { log_err "source resolve-config failed"; exit 0; }
else
    exit 0
fi

WORK_DIR=$(resolve_artifact work work 2>/dev/null) || exit 0
[[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] || exit 0

CONFIG_FILE=""
if [[ -n "${WORKSPACE_ROOT:-}" && -f "${WORKSPACE_ROOT}/.claude/configuration.yml" ]]; then
    CONFIG_FILE="${WORKSPACE_ROOT}/.claude/configuration.yml"
fi
[[ -n "$CONFIG_FILE" ]] || exit 0

command -v yq >/dev/null 2>&1 || exit 0

ENABLED=$(yq -r '.hooks.auto_context.enabled // false' "$CONFIG_FILE" 2>/dev/null)
[[ "$ENABLED" == "true" ]] || exit 0

THROTTLE_SECONDS=$(yq -r '.hooks.auto_context.throttle_seconds // 300' "$CONFIG_FILE" 2>/dev/null)
[[ "$THROTTLE_SECONDS" =~ ^[0-9]+$ ]] || THROTTLE_SECONDS=300

MILESTONE_TOOLS=$(yq -r '.hooks.auto_context.milestone_tools // ["Edit","Write","MultiEdit","Task","NotebookEdit"] | join(" ")' "$CONFIG_FILE" 2>/dev/null)
[[ -n "$MILESTONE_TOOLS" ]] || MILESTONE_TOOLS="Edit Write MultiEdit Task NotebookEdit"

TOOL_MATCH=0
for t in $MILESTONE_TOOLS; do
    if [[ "$t" == "$TOOL_NAME" ]]; then
        TOOL_MATCH=1
        break
    fi
done
[[ "$TOOL_MATCH" == "1" ]] || exit 0

SENTINEL="$WORK_DIR/.active-sessions"
SENTINEL_LOCK="$WORK_DIR/.active-sessions.lock"
mkdir -p "$WORK_DIR" 2>/dev/null || exit 0
touch "$SENTINEL_LOCK" 2>/dev/null || exit 0

WORK_ID=$(
    exec 200>"$SENTINEL_LOCK"
    flock -s -w 1 200 2>/dev/null || exit 0
    if [[ -s "$SENTINEL" ]]; then
        jq -r --arg s "$SESSION_ID" '.[$s] // empty' "$SENTINEL" 2>/dev/null
    fi
)

[[ -n "$WORK_ID" ]] || exit 0
[[ "$WORK_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { log_err "rejected work-id: $WORK_ID"; exit 0; }

STATE_FILE="$WORK_DIR/$WORK_ID/state.json"
[[ -f "$STATE_FILE" ]] || exit 0

STATUS=$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null)
if [[ "$STATUS" == "completed" ]]; then
    (
        flock -x -w 2 200 2>/dev/null || exit 1
        if [[ -s "$SENTINEL" ]]; then
            jq --arg s "$SESSION_ID" 'del(.[$s])' "$SENTINEL" > "${SENTINEL}.tmp.$$" 2>/dev/null \
                && mv "${SENTINEL}.tmp.$$" "$SENTINEL"
        fi
    ) 200>"$SENTINEL_LOCK"
    exit 0
fi

LAST=$(jq -r '.auto_context_last_at // empty' "$STATE_FILE" 2>/dev/null)
if [[ -n "$LAST" ]]; then
    LAST_EPOCH=$(date -u -d "$LAST" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST" +%s 2>/dev/null || echo 0)
    if [[ "$LAST_EPOCH" -gt 0 ]]; then
        NOW_EPOCH=$(date -u +%s)
        AGE=$(( NOW_EPOCH - LAST_EPOCH ))
        if [[ "$AGE" -lt "$THROTTLE_SECONDS" ]]; then
            exit 0
        fi
    fi
fi

TARGET=""
case "$TOOL_NAME" in
    Edit|Write|MultiEdit|NotebookEdit)
        TARGET=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$STDIN" 2>/dev/null)
        ;;
    Task)
        TARGET=$(jq -r '.tool_input.subagent_type // empty' <<<"$STDIN" 2>/dev/null)
        ;;
esac
[[ "${#TARGET}" -gt 120 ]] && TARGET="${TARGET:0:117}..."

NOTE="[auto] ${TOOL_NAME}"
[[ -n "$TARGET" ]] && NOTE="[auto] ${TOOL_NAME}: ${TARGET}"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE_LOCK="${STATE_FILE}.lock"
touch "$STATE_LOCK" 2>/dev/null || exit 0

(
    flock -x -w 2 200 2>/dev/null || exit 1
    jq --arg ts "$TS" --arg n "$NOTE" \
        '.updates = ((.updates // []) + [{timestamp: $ts, note: $n, auto: true}]) | .auto_context_last_at = $ts | .updated_at = $ts' \
        "$STATE_FILE" > "${STATE_FILE}.tmp.$$" 2>/dev/null \
        && mv "${STATE_FILE}.tmp.$$" "$STATE_FILE" \
        || { log_err "state write failed for $WORK_ID"; rm -f "${STATE_FILE}.tmp.$$"; exit 1; }

    MANIFEST="$WORK_DIR/manifest.json"
    if [[ -f "$MANIFEST" ]]; then
        jq --arg id "$WORK_ID" --arg ts "$TS" \
            '(.items[] | select(.identifier == $id)) |= (.updated_at = $ts) | .last_updated = $ts' \
            "$MANIFEST" > "${MANIFEST}.tmp.$$" 2>/dev/null \
            && mv "${MANIFEST}.tmp.$$" "$MANIFEST" \
            || rm -f "${MANIFEST}.tmp.$$"
    fi
) 200>"$STATE_LOCK"

exit 0
