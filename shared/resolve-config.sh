#!/usr/bin/env bash
# Shared configuration resolution for Claude Code skills.
# Source this script to get config discovery and artifact resolution functions.
#
# Usage in SKILL.md bash blocks (marketplace installs get ${CLAUDE_PLUGIN_ROOT}
# substituted inline; ~/.claude fallback is for local/dev copies only):
#   source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
#   WORK_DIR=$(resolve_artifact work work)
#   EXEC_MODE=$(resolve_exec_mode qa_review team)
#
# Two artifact resolvers, and the difference decides correctness, not style:
#   resolve_artifact / resolve_artifact_typed — advisory; always return a
#     path, fabricating one from defaults for an unconfigured artifact.
#   resolve_artifact_strict — authoritative; refuses instead of fabricating.
#     Anything that WRITES into a shared knowledge base must gate on this one.
# See the block above resolve_artifact_strict, and
# docs/decisions/014-artifact-resolution-strictness.md.

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

# Shell metacharacters, checked SEPARATELY from the traversal rules because an
# absolute location path is exempt from those and must not be exempt from this.
# That exemption is documented ("Git locations should use absolute paths"), so
# the value most likely to be hostile was the one going unchecked.
#
# Every resolver returns a path that callers go on to put on a command line, and
# a configured path is not typed by the person running the command — it comes
# from a file that may be shared, checked in, or written by another tool. A
# value containing $( ) or a backtick stops being a path the moment it is
# substituted; it becomes the next command.
#
# This is a floor, not a licence to stop quoting: it removes the forms that
# execute or redirect, and call sites still quote their expansions.
_reject_shell_metacharacters() {
  local value="$1" keyname="$2"

  # `>` and `<` redirect, `*` and `?` glob, `(` `)` subshell, and the rest
  # execute or separate. A space is deliberately NOT here: a directory named
  # "team docs" is ordinary, and refusing it would send people around the check
  # rather than through it.
  if [[ "$value" == *[\'\"\`\$\\\;\|\&\<\>\*\?\(\)]* || "$value" == *$'\n'* ]]; then
    echo "resolve-config: ${keyname} must not contain shell metacharacters (quote, backtick, \$, backslash, ; | & < > * ? ( ) or newline), got '${value}'" >&2
    return 1
  fi
  return 0
}

# --- Containment of configured path fragments (CL-52) ---
#
# `configuration.yml` is project-controlled input. In a plugin environment it is
# authored by whoever set the project up, which is not necessarily the person
# running the skill — and since CL-32 put a resolver on the archivist's WRITE
# path, a `subdir` of `../../somewhere` no longer just misdirects a read, it
# directs a commit outside the knowledge base. Every resolver rejects an
# escaping fragment; they differ only in what they do afterwards (see each).
#
# Rejects:
#   * an absolute fragment (`/etc`), which ignores its location entirely;
#   * a `..` PATH SEGMENT anywhere (`..`, `../x`, `x/..`, `x/../y`).
#
# Accepts a segment that merely contains dots — `a..b`, `...`, `..hidden` are
# ordinary directory names and always were legal here. The `/$value/` wrapping
# is what makes that distinction exact: the pattern matches only a literal
# `/../`, so `a..b` (no slash-dot-dot-slash) passes and `x/../y` does not.
#
# Deliberately lexical, not `realpath`. The path routinely does not exist yet
# (that is the "configured but not yet created" state the strict resolver is
# careful to distinguish), so a filesystem-resolving check would either fail on
# a legitimate not-yet-created KB or need a fallback that reintroduces the gap.
# A symlink INSIDE the location that points outside is therefore not covered —
# that is a property of the filesystem, not of the configuration, and creating
# it already requires write access to the location.
_reject_escaping_fragment() {
  local value="$1" keyname="$2"

  case "$value" in
    /*)
      echo "resolve-config: ${keyname} must be relative to its storage location, got '${value}'" >&2
      return 1
      ;;
  esac

  case "/$value/" in
    */../*)
      echo "resolve-config: ${keyname} must not contain a '..' path segment, got '${value}' — it would resolve outside the storage location" >&2
      return 1
      ;;
  esac

  _reject_shell_metacharacters "$value" "$keyname" || return 1


  return 0
}

# A location NAME is interpolated into the yq expression that looks it up, so
# it must be a plain key and nothing else. A value like `kb | {"path":"/tmp"}`
# turns the lookup into a different query that returns an attacker-chosen path
# — no shell injection (the expression is a single quoted argv element), but it
# defeats "the location must actually be declared", which is the whole point of
# the indirection. yq also exposes `load()`/`env()` in that position.
_valid_location_name() {
  # At least one non-dot character. An all-dot name is not a key: `..` is yq's
  # recursive-descent operator, so `.storage.locations...path` walks the whole
  # document and can return paths belonging to locations the artifact never
  # named — which defeats "the artifact must name a DECLARED location", the
  # exact property this check exists to enforce.
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" =~ [^.] ]]
}

# Collapses the several ways a configuration can spell the same directory into
# one answer: a trailing `/.` (from the documented `subdir: .`), a trailing `/`
# (from `subdir: ""`, which does NOT reach yq's `// default` because an empty
# string is a value, not an absence), and repeated slashes.
#
# Looped until stable, because the strips feed each other and a single ordered
# pass leaves shapes behind: `subdir: "./"` composes to `<base>/./`, where
# stripping `/.` first does nothing (it ends in `/`) and stripping `/` first
# exposes a `/.` that no longer gets removed — landing on `<base>/.`, the exact
# bogus shape recorded as CL-39 item 4. Fixed-point iteration is
# order-independent by construction.
#
# Applied by ALL THREE resolvers (CL-51). It was strict-only when introduced,
# on the reasoning that the advisory resolvers' exact output was depended on —
# but the thing depending on it was a test asserting the bogus shape, and
# a plausible-looking but empty path reaching a caller is the defect, not a contract.
_normalize_artifact_path() {
  local p="$1" prev=""
  while [[ "$p" != "$prev" ]]; do
    prev="$p"
    while [[ "$p" == *//* ]]; do
      p="${p//\/\///}"
    done
    # Interior `/./` too, not just a trailing `/.` — `a/./b` names `a/b`, and
    # leaving it uncollapsed means two spellings of one directory survive and
    # any caller comparing paths as strings sees them as different.
    while [[ "$p" == */./* ]]; do
      p="${p//\/.\///}"
    done
    p="${p%/.}"
    # Never strip the root itself down to the empty string.
    [[ "$p" == "/" ]] || p="${p%/}"
  done

  # The root guard above is checked BEFORE the `%/.` strip on the next
  # iteration, so it does not catch every route to empty: `path: "/"` with
  # `subdir: .` composes to `//.`, collapses to `/.`, and `%/.` takes it to ""
  # without the guard ever seeing "/". An empty path then reads as relative and
  # gets anchored to WORKSPACE_ROOT — returning the user's own project root
  # from a function whose job is to answer, not invent. Restore it explicitly.
  [[ -n "$p" ]] || p="/"
  printf '%s' "$p"
}

# --- Artifact resolution ---
# Resolves an artifact path from configuration, with fallback defaults.
# Usage: resolve_artifact <artifact_name> <default_subdir> [default_base]
# Returns: absolute path anchored to WORKSPACE_ROOT
#
# ADVISORY (see the strict resolver below). On an escaping `subdir` it does not
# refuse — its contract is to always return a path — it falls back to the
# caller-supplied default and warns on stderr. A read landing on the default
# subdir returns nothing useful, which is a safe and legible failure; a read
# landing outside the storage location is not.
resolve_artifact() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  local result_path
  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG" 2>/dev/null)
    _valid_location_name "$_LOC" || {
      echo "resolve-config: storage.artifacts.${artifact}.location is not a plain location name, got '${_LOC}' — using defaults" >&2
      _LOC="__invalid__"
    }
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG" 2>/dev/null)
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG" 2>/dev/null)

    # yq's `// default` fires on null, NOT on an empty string — and it cannot
    # fire at all when the expression itself errors, which leaves stdout empty.
    # An empty _BASE then composes to "/${_SUB}", which the anchoring below
    # reads as ABSOLUTE and returns unanchored: `path: ""` with
    # `subdir: tmp/pwn` resolves to /tmp/pwn, outside any location, with no
    # `..` involved at all. Never let either half be empty.
    [[ -n "$_BASE" && "$_BASE" != "null" ]] || _BASE="$default_base"
    [[ -n "$_SUB"  && "$_SUB"  != "null" ]] || _SUB="$default_subdir"

    # Containment (CL-52). An absolute LOCATION path is legitimate and
    # documented ("Git locations should use absolute paths"), so only the
    # relative case is checked for escape; the subdir is always relative to
    # its location and is checked outright.
    _reject_escaping_fragment "$_SUB" "storage.artifacts.${artifact}.subdir" || _SUB="$default_subdir"
    # Runs for an ABSOLUTE path too: that value is exempt from the traversal
    # rule, never from this one.
    _reject_shell_metacharacters "$_BASE" "storage.locations.${_LOC}.path" || _BASE="$default_base"
    case "$_BASE" in
      /*) : ;;
      *)  _reject_escaping_fragment "$_BASE" "storage.locations.${_LOC}.path" || _BASE="$default_base" ;;
    esac

    result_path="${_BASE}/${_SUB}"
  else
    result_path="${default_base}/${default_subdir}"
  fi

  # Anchor FIRST, then normalise. Normalising a relative result and anchoring
  # afterwards re-creates the very shape this removes: `path: .` with
  # `subdir: .` normalises to "." and then composes to "${WORKSPACE_ROOT}/.".
  # Anchoring keeps paths stable across CWD changes (worktrees).
  [[ "$result_path" == /* ]] || result_path="${WORKSPACE_ROOT}/${result_path}"
  _normalize_artifact_path "$result_path"
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
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG" 2>/dev/null)
    _valid_location_name "$_LOC" || {
      echo "resolve-config: storage.artifacts.${artifact}.location is not a plain location name, got '${_LOC}' — using defaults" >&2
      _LOC="__invalid__"
    }
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG" 2>/dev/null)
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG" 2>/dev/null)
    _TYPE=$(yq -r ".storage.locations.${_LOC}.type // \"directory\"" "$CONFIG" 2>/dev/null)

    # yq's `// default` fires on null, NOT on an empty string — and it cannot
    # fire at all when the expression itself errors, which leaves stdout empty.
    # An empty _BASE then composes to "/${_SUB}", which the anchoring below
    # reads as ABSOLUTE and returns unanchored: `path: ""` with
    # `subdir: tmp/pwn` resolves to /tmp/pwn, outside any location, with no
    # `..` involved at all. Never let either half be empty.
    [[ -n "$_BASE" && "$_BASE" != "null" ]] || _BASE="$default_base"
    [[ -n "$_SUB"  && "$_SUB"  != "null" ]] || _SUB="$default_subdir"
    [[ -n "$_TYPE" && "$_TYPE" != "null" ]] || _TYPE="directory"

    # Containment (CL-52) — same advisory fallback as resolve_artifact.
    _reject_escaping_fragment "$_SUB" "storage.artifacts.${artifact}.subdir" || _SUB="$default_subdir"
    # Runs for an ABSOLUTE path too: that value is exempt from the traversal
    # rule, never from this one.
    _reject_shell_metacharacters "$_BASE" "storage.locations.${_LOC}.path" || _BASE="$default_base"
    case "$_BASE" in
      /*) : ;;
      *)  _reject_escaping_fragment "$_BASE" "storage.locations.${_LOC}.path" || _BASE="$default_base" ;;
    esac

    result_path="${_BASE}/${_SUB}"
  else
    result_path="${default_base}/${default_subdir}"
    _TYPE="directory"
  fi

  # Anchor FIRST, then normalise. Normalising a relative result and anchoring
  # afterwards re-creates the very shape this removes: `path: .` with
  # `subdir: .` normalises to "." and then composes to "${WORKSPACE_ROOT}/.".
  [[ "$result_path" == /* ]] || result_path="${WORKSPACE_ROOT}/${result_path}"
  printf '%s|%s\n' "$(_normalize_artifact_path "$result_path")" "$_TYPE"
}

# --- Artifact resolution, strict (CL-32) ---
#
# The advisory resolvers above ALWAYS return a path. On an install that never
# configured an artifact they fabricate one from the defaults — `.claude/
# requirements` for the requirements KB, `.claude` for product-knowledge (it
# was `.claude/.` until the normalisation became shared) — and report it as
# though it were configured. That is correct for a read: a
# caller listing brainstorms wants a sensible default, and an empty directory
# is a fine answer. It is NOT correct for a write. A write gated on a
# fabricated path lands in a directory nobody set up, in an install whose
# owner never opted into a knowledge base at all.
#
# So the project's rule is:
#
#   * resolve_artifact / resolve_artifact_typed — ADVISORY. Reads, listings,
#     and friendlier messages. Never the thing that decides a write happens.
#   * resolve_artifact_strict — AUTHORITATIVE. Refuses instead of fabricating.
#     Every write into a shared knowledge base gates on this, and on nothing
#     else. See docs/decisions/014-artifact-resolution-strictness.md.
#
# "Configured" means both halves are actually present: the artifact names a
# location, and that location defines a path. Nothing else counts — an
# artifact pointing at a location that does not exist is a misconfiguration,
# not a default, and it is exactly the shape that used to resolve to a
# plausible-looking path anchored at the project root.
#
# Deliberately NOT checked here: whether the directory EXISTS. Resolution
# answers "is this configured"; existence is a separate question the caller
# asks afterwards (`test -d`), because "configured but not yet created" and
# "never configured" need different messages and only the second is a refusal
# to proceed at all.
#
# Usage:
#   if REPO_TYPE=$(resolve_artifact_strict requirements requirements); then
#     IFS='|' read -r REPO _TYPE <<< "$REPO_TYPE"
#   else
#     # refuse — the exit code says which half is missing
#   fi
#
# Exit codes (a caller that only needs "may I write?" can test 0 vs non-zero):
#   0  configured; "PATH|TYPE" on stdout
#   2  no .claude/configuration.yml found at all
#   3  storage.artifacts.<artifact>.location is unset or empty
#   4  the named location defines no path
#   5  a configured fragment would escape its storage location (absolute, or a
#      `..` path segment) — a broken configuration, not a missing one
resolve_artifact_strict() {
  local artifact="$1"
  local default_subdir="${2:-$artifact}"

  if [[ ! -f "$CONFIG" ]]; then
    echo "resolve_artifact_strict: no .claude/configuration.yml found (searched upward from $PWD)" >&2
    return 2
  fi

  local _LOC _BASE _SUB _TYPE
  _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"\"" "$CONFIG" 2>/dev/null)
  if [[ -z "$_LOC" || "$_LOC" == "null" ]]; then
    echo "resolve_artifact_strict: storage.artifacts.${artifact}.location is not set in $CONFIG" >&2
    return 3
  fi
  if ! _valid_location_name "$_LOC"; then
    echo "resolve_artifact_strict: storage.artifacts.${artifact}.location must be a plain location name, got '${_LOC}'" >&2
    return 5
  fi

  _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"\"" "$CONFIG" 2>/dev/null)
  if [[ -z "$_BASE" || "$_BASE" == "null" ]]; then
    echo "resolve_artifact_strict: storage.locations.${_LOC}.path is not set in $CONFIG (referenced by storage.artifacts.${artifact})" >&2
    return 4
  fi

  _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG" 2>/dev/null)
  _TYPE=$(yq -r ".storage.locations.${_LOC}.type // \"directory\"" "$CONFIG" 2>/dev/null)

  # Containment (CL-52). The strict resolver REFUSES rather than falling back:
  # it gates writes, and quietly substituting a default would send a commit
  # somewhere the configuration did not ask for, which is its own surprise. A
  # configuration this rejects is broken and the operator has to fix it.
  #
  # An absolute LOCATION path is legitimate and documented ("Git locations
  # should use absolute paths"); only a relative one is checked for escape.
  # The subdir is always relative to its location, so it is checked outright.
  _reject_escaping_fragment "$_SUB" "storage.artifacts.${artifact}.subdir" || return 5
  # Runs for an ABSOLUTE path too: that value is exempt from the traversal
  # rule, never from this one.
  _reject_shell_metacharacters "$_BASE" "storage.locations.${_LOC}.path" || return 5
  case "$_BASE" in
    /*) : ;;
    *)  _reject_escaping_fragment "$_BASE" "storage.locations.${_LOC}.path" || return 5 ;;
  esac

  local result_path="${_BASE}/${_SUB}"

  # `subdir: .` is a legitimate, documented configuration (product-knowledge
  # uses it in the shipped template) but composes to a trailing "/." that
  # reads like a bug and never string-compares equal to the directory it
  # actually names. `subdir: ""` is the same intent spelled differently and
  # composes to a trailing "/" — and it does NOT hit the `// default` above,
  # since yq treats an empty string as a value. Both mean "the location root"
  # and both normalise to it here.
  #
  # Applied by all three resolvers. This was strict-only when introduced, on
  # the reasoning that the advisory resolvers' exact output was depended on —
  # the only thing depending on it was a test asserting the bogus shape.
  # Anchor FIRST, then normalise. Normalising a relative result and anchoring
  # afterwards re-creates the very shape this removes: `path: .` with
  # `subdir: .` normalises to "." and then composes to "${WORKSPACE_ROOT}/.".
  [[ "$result_path" == /* ]] || result_path="${WORKSPACE_ROOT}/${result_path}"
  printf '%s|%s\n' "$(_normalize_artifact_path "$result_path")" "$_TYPE"
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
    root=$(yq -r ".worktree.root // \"${default}\"" "$CONFIG" 2>/dev/null)
    # Same containment as the artifact resolvers (CL-52), and for the same
    # reason: this path is handed to `git worktree add`, so an escaping value
    # creates a working tree outside the workspace. A relative root that climbs
    # out, or an empty value (which would compose to the workspace root itself),
    # falls back to the default rather than being honoured.
    [[ -n "$root" && "$root" != "null" ]] || root="$default"
    # Unlike storage.locations[].path, an ABSOLUTE worktree root is not
    # documented anywhere as legitimate — docs/configuration.md describes it
    # only as "where ticket workspace directories are created", i.e. inside the
    # workspace. So absolute is rejected here rather than exempted: it would
    # put a `git worktree add` outside the workspace with no `..` required.
    _reject_escaping_fragment "$root" "worktree.root" || root="$default"
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

  # The service name is interpolated into the yq expression below AND is the
  # path component of the name-is-the-directory fallback at the end — so an
  # unvalidated name escapes even when no `path` is configured at all:
  # `services: [{ name: ../../outside }]` yields ${WORKSPACE_ROOT}/../../outside,
  # which is handed to `git worktree add`. Validate once, up front, for both.
  if ! _valid_location_name "$svc"; then
    echo "resolve-config: workspace service name must be a plain name, got '${svc}'" >&2
    return 1
  fi

  # Try config first
  if [[ -f "$CONFIG" ]]; then
    local rel
    # `// ""`, not `// empty`: `empty` is a jq builtin that mikefarah yq (the yq
    # this plugin depends on) rejects outright — "lexer: invalid input text".
    # The expression therefore errored on every call, stderr was swallowed by
    # 2>/dev/null, and `rel` came back empty, so a configured
    # workspace.services[].path was silently ignored and every service fell back
    # to the name-is-the-directory convention. Pre-existing and unrelated to the
    # traversal fix, but found by testing it: the containment check below is
    # unreachable while the lookup never returns anything.
    # head -1: two services sharing a name would otherwise make `rel`
    # multi-line and the absolute branch would echo both.
    rel=$(yq -r ".workspace.services[] | select(.name == \"${svc}\") | .path // \"\"" "$CONFIG" 2>/dev/null | head -1)
    if [[ -n "$rel" ]]; then
      # Containment (CL-52). A service path feeds worktree creation and git
      # operations, so a relative value that climbs out of the workspace is the
      # same defect as an escaping artifact subdir. An ABSOLUTE service path is
      # documented and legitimate ("Relative or absolute path to the git repo").
      # ...but "absolute" exempts it from the CLIMB-OUT rule only. The
      # metacharacter check runs on it either way — the same distinction the
      # artifact resolvers make above, and the one this site originally missed.
      if ! _reject_shell_metacharacters "$rel" "workspace.services[name=${svc}].path"; then
        echo "${WORKSPACE_ROOT}/${svc}"
        return
      fi
      case "$rel" in
        /*) echo "$rel"; return ;;
        *)  if _reject_escaping_fragment "$rel" "workspace.services[name=${svc}].path"; then
              echo "${WORKSPACE_ROOT}/${rel}"
              return
            fi
            # Rejected: fall through to the name-is-the-directory convention.
            ;;
      esac
    fi
  fi
  # Fallback: convention — service name = directory name
  echo "${WORKSPACE_ROOT}/${svc}"
}

# --- pr-review gate helpers ---
# Whether the orchestrated review path is enabled for this project.
# Opt-out default, matching jira.enabled / implement.deviation_checkpoint.enabled.
# Whether /pr-review may take the orchestrated (workflow) path. Default true.
#
# Do NOT write `// true` here. yq treats a literal `false` as empty, so
# `.pr_review.workflow.enabled // true` returns "true" for an explicit
# `enabled: false` and the documented kill switch silently stops working —
# which is precisely what it did until CL-40's T16 manual run caught it. Same
# reasoning already recorded at plugin/skills/implement/SKILL.md:1838. Test the
# raw value instead.
#
# Both spellings are honoured: the nested `workflow: {enabled: false}` that
# matches this repo's `worktree.enabled` convention, and the bare scalar
# `workflow: false` that a user will reach for first. A config that means to
# turn the path off must turn it off; guessing wrong about which shape someone
# wrote is not a reason to keep running.
resolve_pr_review_workflow_enabled() {
  [[ -f "$CONFIG" ]] || { echo "true"; return 0; }
  local _raw
  _raw=$(yq -r '.pr_review.workflow.enabled' "$CONFIG" 2>/dev/null)
  if [[ "$_raw" != "true" && "$_raw" != "false" ]]; then
    _raw=$(yq -r '.pr_review.workflow' "$CONFIG" 2>/dev/null)
  fi
  if [[ "$_raw" == "false" ]]; then echo "false"; else echo "true"; fi
}

# Gate definitions as TSV: name<TAB>template<TAB>args.
#
# Reads the WORKING-TREE config, and is therefore only appropriate for display
# or for a project reviewing itself. The security-relevant read — the one whose
# result is actually executed — lives in plugin/shared/pr-review/gate-runner.sh
# and resolves from the merge base instead, so the branch under review cannot
# define what runs during its own review. Do not substitute this for that.
#
# Empty output means no gates configured, which is the documented default and
# not an error: the deterministic phase is skipped.
resolve_gate_commands() {
  [[ -f "$CONFIG" ]] || return 0
  local _count
  _count=$(yq -r '.pr_review.gates | length // 0' "$CONFIG" 2>/dev/null) || return 0
  [[ "$_count" =~ ^[0-9]+$ ]] || return 0
  [[ "$_count" -gt 0 ]] || return 0
  yq -r '.pr_review.gates[] | [(.name // ""), (.template // ""), (.args // "")] | @tsv' "$CONFIG" 2>/dev/null
}
