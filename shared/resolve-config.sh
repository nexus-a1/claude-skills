#!/usr/bin/env bash
# Shared configuration resolution for Claude Code skills.
# Source this script to get config discovery and artifact resolution functions.
#
# Usage in SKILL.md bash blocks (marketplace installs get ${CLAUDE_PLUGIN_ROOT}
# substituted inline; ~/.claude fallback is for local/dev copies only):
#   source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
#   WORK_DIR=$(resolve_artifact work work)
#   EXEC_MODE=$(resolve_exec_mode qa_review team)

# --- Config discovery ---
# Walks up from CWD to find .claude/configuration.yml
CONFIG=""
_d="$PWD"
while [[ "$_d" != "/" ]]; do
  if [[ -f "$_d/.claude/configuration.yml" ]]; then
    CONFIG="$_d/.claude/configuration.yml"
    break
  fi
  _d="$(dirname "$_d")"
done

# --- Workspace root ---
# The directory where .claude/configuration.yml lives.
# All relative paths anchor here. Works from worktrees, subdirs, anywhere.
WORKSPACE_ROOT=""
if [[ -n "$CONFIG" ]]; then
  WORKSPACE_ROOT="$(cd "$(dirname "$CONFIG")/.." && pwd)"
fi
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$PWD}"

# --- Workspace mode (auto-detect) ---
# "single" = inside a git repo; "multi" = aggregate directory with git repos as subdirs
WORKSPACE_MODE="single"
DISCOVERED_SERVICES=()

if git -C "$WORKSPACE_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
  WORKSPACE_MODE="single"
else
  # Scan immediate subdirs for git repos
  for dir in "${WORKSPACE_ROOT}"/*/; do
    if [[ -d "${dir}.git" ]]; then
      DISCOVERED_SERVICES+=("$(basename "$dir")")
    fi
  done
  [[ ${#DISCOVERED_SERVICES[@]} -gt 0 ]] && WORKSPACE_MODE="multi"
fi

# Config override: if workspace.services defined, use that instead of auto-discovery
if [[ -f "$CONFIG" ]]; then
  _svc_count=$(yq -r '.workspace.services | length // 0' "$CONFIG" 2>/dev/null)
  if [[ "$_svc_count" -gt 0 ]]; then
    WORKSPACE_MODE="multi"
    DISCOVERED_SERVICES=()  # config takes precedence
  fi
fi

# --- Artifact resolution ---
# Resolves an artifact path from configuration, with fallback defaults.
# Usage: resolve_artifact <artifact_name> <default_subdir> [default_base]
# Returns: absolute path anchored to WORKSPACE_ROOT
resolve_artifact() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  local result_path
  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    result_path="${_BASE}/${_SUB}"
  else
    result_path="${default_base}/${default_subdir}"
  fi

  # Anchor relative paths to WORKSPACE_ROOT so they survive CWD changes (worktrees)
  if [[ "$result_path" != /* ]]; then
    echo "${WORKSPACE_ROOT}/${result_path}"
  else
    echo "$result_path"
  fi
}

# --- Artifact resolution with type ---
# Like resolve_artifact but also returns the storage type (git|directory).
# Usage: IFS='|' read -r PATH TYPE <<< "$(resolve_artifact_typed work work)"
resolve_artifact_typed() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  local result_path _TYPE
  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    _TYPE=$(yq -r ".storage.locations.${_LOC}.type // \"directory\"" "$CONFIG")
    result_path="${_BASE}/${_SUB}"
  else
    result_path="${default_base}/${default_subdir}"
    _TYPE="directory"
  fi

  # Anchor relative paths to WORKSPACE_ROOT
  if [[ "$result_path" != /* ]]; then
    echo "${WORKSPACE_ROOT}/${result_path}|${_TYPE}"
  else
    echo "${result_path}|${_TYPE}"
  fi
}

# --- Execution mode resolution ---
# Resolves execution mode for a specific phase from configuration.
# Usage: resolve_exec_mode <phase_name> [default_mode]
# Returns: "team" or "subagent"
resolve_exec_mode() {
  local phase="$1"
  local default="${2:-team}"

  if [[ -f "$CONFIG" ]]; then
    local _raw=$(yq -r '.execution_mode' "$CONFIG" 2>/dev/null)
    if [[ "$_raw" == "subagent" || "$_raw" == "team" ]]; then
      echo "$_raw"
    elif [[ "$_raw" != "null" && -n "$_raw" ]]; then
      yq -r ".execution_mode.overrides.${phase} // .execution_mode.default // \"${default}\"" "$CONFIG"
    else
      echo "$default"
    fi
  else
    echo "$default"
  fi
}

# --- Worktree helpers ---
# Returns "true" or "false"
resolve_worktree_enabled() {
  if [[ -f "$CONFIG" ]]; then
    yq -r '.worktree.enabled // "false"' "$CONFIG"
  else
    echo "false"
  fi
}

# --- Deviation checkpoint helper ---
# /implement Phase 3.2b gate. Default true (opt-out, not opt-in) — unlike
# worktree/jira write, this check is meant to run unless a project finds it
# too noisy and turns it off.
# Returns "true" or "false". Note: `//` can't supply this default — jq/yq
# treat a literal `false` value as falsy, so `enabled // "true"` would
# silently discard an explicit `enabled: false`. Test the raw value instead.
resolve_deviation_checkpoint_enabled() {
  if [[ -f "$CONFIG" ]]; then
    local _raw
    _raw=$(yq -r '.implement.deviation_checkpoint.enabled' "$CONFIG" 2>/dev/null)
    if [[ "$_raw" == "false" ]]; then
      echo "false"
    else
      echo "true"
    fi
  else
    echo "true"
  fi
}

# --- Playwright scoping question helper ---
# /implement Phase 4.0 gate. Default true (opt-out, not opt-in) — like the
# deviation checkpoint, this question is meant to run unless a project finds
# it too noisy and turns it off (reverting to silent mechanical detection).
# Returns "true" or "false". Same `//`-with-literal-false pitfall as
# resolve_deviation_checkpoint_enabled applies here — test the raw value.
resolve_playwright_scoping_enabled() {
  if [[ -f "$CONFIG" ]]; then
    local _raw
    _raw=$(yq -r '.implement.playwright_scoping.enabled' "$CONFIG" 2>/dev/null)
    if [[ "$_raw" == "false" ]]; then
      echo "false"
    else
      echo "true"
    fi
  else
    echo "true"
  fi
}

# --- Playwright scoping decision override (CL-23) ---
# Only consulted when resolve_playwright_scoping_enabled returns "false" —
# i.e. the project opted out of being asked every run. Lets it also state
# the fixed decision instead of falling back to mechanical file-extension
# detection:
#   "heuristic" (default) — unchanged prior behavior: detect from touched
#                            files, may still run playwright-engineer.
#   "skip"                — never run playwright-engineer for this project,
#                            regardless of what files were touched.
# Any other value falls back to "heuristic" rather than erroring, since a
# typo here should degrade to the safe prior behavior, not silently disable
# or silently enable E2E generation.
resolve_playwright_scoping_default() {
  if [[ -f "$CONFIG" ]]; then
    local _raw
    _raw=$(yq -r '.implement.playwright_scoping.default' "$CONFIG" 2>/dev/null)
    if [[ "$_raw" == "skip" ]]; then
      echo "skip"
    else
      echo "heuristic"
    fi
  else
    echo "heuristic"
  fi
}

# Returns absolute path to worktree root directory
resolve_worktree_root() {
  local default=".worktrees"
  local root
  if [[ -f "$CONFIG" ]]; then
    root=$(yq -r ".worktree.root // \"${default}\"" "$CONFIG")
  else
    root="$default"
  fi
  [[ "$root" != /* ]] && echo "${WORKSPACE_ROOT}/${root}" || echo "$root"
}

# --- Service helpers (multi-mode) ---
# Returns service names: from config if defined, otherwise auto-discovered
resolve_services() {
  if [[ -f "$CONFIG" ]]; then
    local _count=$(yq -r '.workspace.services | length // 0' "$CONFIG" 2>/dev/null)
    if [[ "$_count" -gt 0 ]]; then
      yq -r '.workspace.services[].name' "$CONFIG"
      return
    fi
  fi
  # Fallback: auto-discovered services
  printf '%s\n' "${DISCOVERED_SERVICES[@]}"
}

# Returns absolute path for a service (from config or convention: name = dir name)
resolve_service_path() {
  local svc="$1"
  # Try config first
  if [[ -f "$CONFIG" ]]; then
    local rel
    rel=$(yq -r ".workspace.services[] | select(.name == \"${svc}\") | .path // empty" "$CONFIG" 2>/dev/null)
    if [[ -n "$rel" ]]; then
      [[ "$rel" != /* ]] && echo "${WORKSPACE_ROOT}/${rel}" || echo "$rel"
      return
    fi
  fi
  # Fallback: convention — service name = directory name
  echo "${WORKSPACE_ROOT}/${svc}"
}
