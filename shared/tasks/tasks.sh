#!/usr/bin/env bash
# plugin/shared/tasks/tasks.sh
#
# The task store behind /todo, /todo-work, /rebuild-index tasks and the task
# promotion step of /create-requirements. Every read and every write of task
# files goes through this script; no skill scans the store or edits it with jq
# itself, because the status rules and the write order live here and nowhere
# else. Layout, statuses and transitions: shared/manifest-schema.md, "Tasks".
#
# Run, never sourced, flag-first:
#
#   tasks.sh --op resolve
#
# Run rather than sourced because that is the only shape a scoped Bash grant
# can match (the same reason jira.sh is run with --op). Flag-first because
# plugin/settings.json matches on the resolved command line, and a bare
# subcommand word after the script name matches no glob.
#
# Conventions (mirrors jira.sh; deliberately not sourced from it — there is no
# shared import path across shared/*/ directories):
#   - Exit codes: 0 ok, 10 written but the index cache is stale, 20 refused or
#     user error, 30 system error.
#   - Diagnostics go to stderr. Structured JSON on stdout stays clean.
#   - Positional parameters are always written braced. This file is never read
#     through the skill runtime, but its idioms get copied into skills, where a
#     bare dollar-digit is replaced with a word of the user's arguments.
#
# Dependencies: bash, jq, and — whenever a configuration file exists — yq
# (mikefarah v4), both already required by /jira.
set -euo pipefail

readonly EXIT_OK=0
readonly EXIT_REFUSED=20
readonly EXIT_SYSTEM=30
# The change is in the source-of-truth file; only the manifest.json cache is
# stale. Callers treat it as success and suggest a rebuild.
readonly EXIT_INDEX_STALE=10

# Self-located by parameter expansion, not dirname: dirname is an external
# binary, and a restricted PATH would print "command not found" ahead of the
# real message.
case "${BASH_SOURCE[0]}" in
  */*) TASKS_SELF_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   TASKS_SELF_DIR="." ;;
esac
readonly TASKS_SELF_DIR

_tasks_log() { printf 'tasks: %s\n' "${1}" >&2; }

# Every refusal and error goes through _tasks_die, which says why. Anything
# else that ends the script non-zero — `set -e` tripping on a command nobody
# thought could fail — would otherwise exit silently, and a silent non-zero
# exit is exactly what a skill cannot explain to its user. The EXIT trap is the
# structural catch-all: it does not depend on having guarded every command.
TASKS_REPORTED=0
_tasks_die() {
  local code="${1}"
  shift
  printf 'tasks: %s\n' "${*}" >&2
  TASKS_REPORTED=1
  exit "$code"
}
# An input directory holds text a person typed. Once one has been validated it
# is removed however the op ends — a refusal must not leave the title or the
# arguments sitting in ~/.claude/tmp. Only a directory _tasks_check_input_dir
# accepted is ever recorded here.
TASKS_INPUT_DIR=""
_tasks_remove_input_dir() {
  [ -n "$TASKS_INPUT_DIR" ] || return 0
  rm -rf -- "$TASKS_INPUT_DIR" 2>/dev/null \
    || _tasks_log "could not remove the input directory $TASKS_INPUT_DIR"
  TASKS_INPUT_DIR=""
}
# shellcheck disable=SC2317  # invoked only by the EXIT trap below
_tasks_on_exit() {
  local rc="${1}"
  # Never fatal: under `set -e` a failed rm here would end the trap with rm's
  # status and hide the op's real exit code.
  if [ -n "$TASKS_INPUT_DIR" ] && [ -d "$TASKS_INPUT_DIR" ] && [ ! -L "$TASKS_INPUT_DIR" ]; then
    rm -rf -- "$TASKS_INPUT_DIR" 2>/dev/null \
      || printf 'tasks: could not remove the input directory %s\n' "$TASKS_INPUT_DIR" >&2
  fi
  if [ "$rc" -ne 0 ] && [ "$TASKS_REPORTED" -eq 0 ]; then
    printf 'tasks: failed unexpectedly (exit %s) — nothing was reported, so treat the store as unchanged only after checking it\n' "$rc" >&2
    exit "$EXIT_SYSTEM"
  fi
}
trap '_tasks_on_exit "$?"' EXIT

# ---------------------------------------------------------------------------
# Libraries
# ---------------------------------------------------------------------------

# Source a file that lives in plugin/shared/ itself (not a sibling directory):
# this script's parent first, then the plugin root, then a local/dev copy.
_tasks_source_shared() {
  local name="${1}" candidate
  for candidate in \
    "$TASKS_SELF_DIR/../$name" \
    "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/shared/$name" \
    "$HOME/.claude/shared/$name"; do
    if [ -f "$candidate" ]; then
      # resolve-config.sh reads unset variables at file scope, and runs yq there
      # with its failure ignored — under -e a malformed configuration would end
      # this script at the source line with nothing said. Its answers are
      # re-checked by the preflight below instead.
      set +eu
      # shellcheck source=/dev/null
      . "$candidate"
      set -eu
      return 0
    fi
  done
  _tasks_die "$EXIT_SYSTEM" "$name not found — reinstall the nexus plugin: /plugin install nexus@claude-skills"
}

_tasks_preflight() {
  command -v jq >/dev/null 2>&1 \
    || _tasks_die "$EXIT_SYSTEM" "jq is required and was not found on PATH"
  _tasks_source_shared resolve-config.sh
  _tasks_source_shared artifact-containment.sh
  # With a configuration file present, every answer below comes from yq. Check
  # it runs here, rather than trusting anything resolve-config.sh computed while
  # being sourced: that file calls yq at file scope and swallows its failure.
  if [ -n "${CONFIG:-}" ]; then
    [ -r "$CONFIG" ] \
      || _tasks_die "$EXIT_REFUSED" "cannot read $CONFIG — refusing rather than guessing where tasks belong"
    command -v yq >/dev/null 2>&1 \
      || _tasks_die "$EXIT_REFUSED" "yq is required to read $CONFIG and was not found on PATH — refusing rather than using the default location"
    yq --version >/dev/null 2>&1 \
      || _tasks_die "$EXIT_REFUSED" "yq is on PATH but does not run — refusing rather than using the default location"
  fi
}

# ---------------------------------------------------------------------------
# Location resolution and write gating
# ---------------------------------------------------------------------------

# The shipped template: the catalog of artifact names and their default subdirs.
_tasks_template_path() {
  local candidate
  for candidate in \
    "$TASKS_SELF_DIR/../../templates/configuration.yml" \
    "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/templates/configuration.yml" \
    "$HOME/.claude/templates/configuration.yml"; do
    if [ -r "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Artifact names defined in a config-shaped file, one per line.
#
# Unlike artifacts.sh's reader of the same template, a failed read is an error
# here, never an empty list: this list decides which directories the task store
# must not collide with, and an empty one would quietly allow every collision.
# The name filter keeps a key from reaching a yq path expression as syntax.
_tasks_artifact_names() {
  local file="${1}" out rc=0
  out="$(yq -r 'select(document_index == 0) | .storage.artifacts // {} | keys | .[]' "$file" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | LC_ALL=C grep -xE '[A-Za-z0-9_-]+' || true
}

# One artifact's default subdir from the template; the artifact name if unset.
_tasks_template_subdir() {
  local tmpl="${1}" name="${2}" sub
  sub="$(k="$name" yq -r 'select(document_index == 0) | .storage.artifacts[strenv(k)].subdir // ""' "$tmpl" 2>/dev/null)" || sub=""
  printf '%s\n' "${sub:-$name}"
}

# Is `storage.artifacts.tasks` present in the configuration?
# Prints `present` or `absent`; returns 1 when the question could not be
# answered. Three answers, not two: `artifact_config_has` reports a yq failure
# as "absent", and "absent" is the one answer that routes writes to the default
# location — so a broken read must never produce it.
_tasks_config_key_state() {
  local out rc=0
  out="$(yq -r 'select(document_index == 0) | .storage.artifacts // {} | has("tasks")' "$CONFIG" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  case "$out" in
    true)  printf 'present\n' ;;
    false) printf 'absent\n' ;;
    *)     return 1 ;;
  esac
}

# Resolve and gate the store. Sets TASKS_DIR, or exits refusing with the reason.
# Every op that finds the store itself calls this before touching anything;
# nothing is created here. The exception is an explicitly named store
# (`--store`, used only for promotion): see _tasks_use_store for what it checks
# and what it relies on instead.
TASKS_DIR=""
# `local` (the default: the store travels with the repository) or `global` (one
# store outside every repository, shared by every project configured the same
# way — CL-122). Only _tasks_resolve sets it; a store named with --store is
# never in global mode, because nothing here re-reads its configuration.
TASKS_MODE="local"
# In global mode, the project every task written here belongs to, and the
# directory that project's TODO.md and per-repository store sit in. Empty in
# local mode, where a store holds one project and tasks carry no tag.
TASKS_PROJECT=""
TASKS_PROJECT_ROOT=""
# 1 when the configuration in use belongs to this project (it sits in the
# repository, or no repository is involved); 0 when it is a parent workspace's.
TASKS_PROJECT_OWNED=0
# Set only by --op init-store: the one path allowed to create a missing global
# store, and whether it did.
TASKS_INIT=0
TASKS_STORE_CREATED=false
_tasks_resolve() {
  local resolved="" rc=0 err="" state="" path="" type=""
  err="$(mktemp)"
  resolved="$(resolve_artifact_strict tasks tasks 2>"$err")" || rc=$?
  case "$rc" in
    0) : ;;
    2)
      # No configuration file: the documented zero-setup default.
      resolved="$(resolve_artifact_typed tasks tasks 2>/dev/null)"
      ;;
    3)
      # Exit 3 means "no location" for BOTH a config that predates the tasks
      # artifact and a tasks entry that is present but broken. Only the first
      # may use the default.
      if ! state="$(_tasks_config_key_state)"; then
        rm -f "$err"
        _tasks_die "$EXIT_REFUSED" "could not read storage.artifacts from $CONFIG — refusing rather than using the default location"
      fi
      if [ "$state" = "present" ]; then
        rm -f "$err"
        _tasks_die "$EXIT_REFUSED" "storage.artifacts.tasks in $CONFIG has no usable location — fix the entry or remove it; it is not redirected to the default"
      fi
      resolved="$(resolve_artifact_typed tasks tasks 2>/dev/null)"
      ;;
    *)
      local why
      why="$(cat "$err" 2>/dev/null || true)"
      rm -f "$err"
      _tasks_die "$EXIT_REFUSED" "storage.artifacts.tasks is misconfigured: ${why:-resolver exit $rc}"
      ;;
  esac
  rm -f "$err"

  IFS='|' read -r path type <<< "$resolved"
  [ -n "$path" ] || _tasks_die "$EXIT_SYSTEM" "resolved an empty tasks path"
  case "$type" in
    directory) : ;;
    git)
      _tasks_die "$EXIT_REFUSED" "tasks resolve to a git-backed location ($path). Shared locations are not supported for tasks yet: task files would sit uncommitted in a shared repository. Map tasks to a local directory location."
      ;;
    *)
      _tasks_die "$EXIT_REFUSED" "tasks resolve to a location of unknown type '$type' ($path)"
      ;;
  esac

  _tasks_read_mode
  _tasks_gate_overlap "$path"
  TASKS_DIR="$path"
  _tasks_refuse_symlinked_store
  if [ "$TASKS_MODE" = "global" ]; then
    _tasks_gate_global "$path"
    _tasks_project
  elif [ -e "$path/store.json" ] || [ -L "$path/store.json" ]; then
    # A project that forgot `mode: global` must not write untagged tasks into
    # the shared list: they would carry no project and show in nobody's view.
    _tasks_die "$EXIT_REFUSED" "$path is set up as a shared task store (it has store.json), but storage.artifacts.tasks does not say mode: global — add it, or map tasks somewhere else"
  fi
}

# Reads storage.artifacts.tasks.mode into TASKS_MODE. A value that could not be
# read is a refusal, never "local": local is the answer that routes writes into
# the repository, which is exactly what a project asking for global mode is
# trying to stop.
_tasks_read_mode() {
  TASKS_MODE="local"
  [ -n "${CONFIG:-}" ] || return 0
  local out rc=0
  out="$(yq -r 'select(document_index == 0) | .storage.artifacts.tasks.mode // "local"' "$CONFIG" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] \
    || _tasks_die "$EXIT_REFUSED" "could not read storage.artifacts.tasks.mode from $CONFIG — refusing rather than guessing the mode"
  case "$out" in
    local|global) TASKS_MODE="$out" ;;
    *) _tasks_die "$EXIT_REFUSED" "storage.artifacts.tasks.mode must be local or global, got '$out'" ;;
  esac
}

# The global store: one directory outside every repository that several
# projects write into. Every check here refuses; none of them falls back to the
# per-repository store, because a silent fallback puts tasks back into the
# repository — the commit-and-push overhead global mode exists to remove.
# SC2088 is disabled for the whole function on purpose: '~' and '~/' below are
# matched as text in the raw configured path (is it written home-relative?),
# not paths to expand.
# shellcheck disable=SC2088
_tasks_gate_global() {
  local path="${1}" loc raw parent top
  loc="$(yq -r 'select(document_index == 0) | .storage.artifacts.tasks.location // ""' "$CONFIG" 2>/dev/null)" \
    || _tasks_die "$EXIT_REFUSED" "could not read storage.artifacts.tasks.location from $CONFIG"
  raw="$(l="$loc" yq -r 'select(document_index == 0) | .storage.locations[strenv(l)].path // ""' "$CONFIG" 2>/dev/null)" \
    || _tasks_die "$EXIT_REFUSED" "could not read storage.locations.$loc.path from $CONFIG"
  # A relative path would anchor to this repository, and so resolve somewhere
  # different for every project — a shared store that is not shared.
  case "$raw" in
    /*|'~'|'~/'*) : ;;
    *) _tasks_die "$EXIT_REFUSED" "mode: global needs a home-relative or absolute location path, and storage.locations.$loc.path is '$raw' — write it as ~/something (for example ~/.nexus), so every user resolves it under their own home directory" ;;
  esac

  [ ! -L "$path" ] || _tasks_die "$EXIT_REFUSED" "the shared task store $path is a symlink; it must be a real directory"
  # Never created here. A missing store usually means a moved or unmounted
  # directory, and creating a fresh one would split the list in two. The one
  # exception is setup (--op init-store), which is asked to create it.
  if [ ! -e "$path" ]; then
    [ "$TASKS_INIT" -eq 1 ] \
      || _tasks_die "$EXIT_REFUSED" "the shared task store $path does not exist, and nothing was created — set it up with /configuration-init, or create it yourself, private at every level: (umask 077 && mkdir -p '$path')"
    _tasks_create_private_dirs "$path"
  fi
  [ -d "$path" ] || _tasks_die "$EXIT_REFUSED" "the shared task store $path exists and is not a directory"

  _tasks_gate_private_dir "$path"
  parent="${path%/*}"
  [ -n "$parent" ] || parent="/"
  # The location root (~/.nexus) matters too: whoever can write there can swap
  # tasks/ for a directory of their own. The home directory itself is the
  # user's own and is not second-guessed.
  if [ "$parent" != "/" ] && [ "$parent" != "${HOME%/}" ]; then
    _tasks_gate_private_dir "$parent"
  fi

  _tasks_gate_outside_git "$path" "$path"

  # The store is a directory of its own. Anything else in it means the path
  # points at a directory that holds something else, and writing there would
  # mix task files into it.
  local entry name has_store=0
  for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    case "$name" in
      items|archive|migration|manifest.json) has_store=1 ;;
      store.json|.tmp.*|.DS_Store) : ;;
      *) _tasks_die "$EXIT_REFUSED" "the shared task store $path holds '$name', which is not part of a task store — point tasks at a directory of their own; nothing was written" ;;
    esac
  done
  if [ -e "$path/store.json" ] || [ -L "$path/store.json" ]; then
    { [ -f "$path/store.json" ] && [ ! -L "$path/store.json" ] \
        && jq -e '.mode == "global"' "$path/store.json" >/dev/null 2>&1; } \
      || _tasks_die "$EXIT_REFUSED" "$path/store.json is not a shared task store marker"
  elif [ "$has_store" -eq 1 ]; then
    _tasks_die "$EXIT_REFUSED" "$path holds a task store that was not set up as a shared one (it has no store.json) — point global mode at an empty directory and move tasks in with /todo migrate"
  fi
}

# The project name a shared store tags tasks with. A letter or digit, then
# letters, digits, dot, underscore or dash — so it can never carry a space, a
# marker or a shell metacharacter into a list, a prompt or a command line.
_tasks_valid_project() {
  local LC_ALL=C
  [[ "${1}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# Sets TASKS_PROJECT and TASKS_PROJECT_ROOT. Global mode only.
#
# The name must come out the same from a repository's root, a subdirectory and
# each of its linked worktrees, so it is never the basename of the current
# directory, and never WORKSPACE_ROOT alone — that moves with wherever the
# configuration was found:
#   - in a repository whose configuration is its own (at or below the checkout
#     top, or in the main checkout): project.name, else the main checkout's
#     folder name; the root is the top of this checkout;
#   - in a repository below a parent configuration (one config above several
#     repositories): that repository's own main checkout name — the parent's
#     project.name names the workspace, not this repository;
#   - outside every repository: project.name, else the configuration
#     directory's folder name; the root is that directory.
_tasks_project() {
  local top="" main="" rc=0 configured="" ws owned=0 name=""
  command -v git >/dev/null 2>&1 \
    || _tasks_die "$EXIT_REFUSED" "git is required in global mode, to name the project a task belongs to"
  configured="$(yq -r 'select(document_index == 0) | .project.name // ""' "$CONFIG" 2>/dev/null)" \
    || _tasks_die "$EXIT_REFUSED" "could not read project.name from $CONFIG"
  top="$(env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --show-toplevel 2>/dev/null)" || top=""

  if [ -z "$top" ]; then
    name="$configured"
    if [ -z "$name" ]; then
      name="${WORKSPACE_ROOT%/}"
      name="${name##*/}"
    fi
    _tasks_valid_project "$name" \
      || _tasks_die "$EXIT_REFUSED" "cannot tag tasks with the project name '$name' (letters, digits, dot, underscore and dash only) — set project.name in $CONFIG"
    TASKS_PROJECT="$name"
    TASKS_PROJECT_ROOT="$WORKSPACE_ROOT"
    TASKS_PROJECT_OWNED=1
    return 0
  fi

  _tasks_source_shared session-map-path.sh
  # shellcheck disable=SC2030,SC2031  # the unset is meant to stay in the subshell
  main="$(unset GIT_DIR GIT_WORK_TREE; nexus_main_checkout .)" || rc=$?
  [ "$rc" -eq 0 ] || main=""
  ws="$(cd "$WORKSPACE_ROOT" 2>/dev/null && pwd -P)" || ws="$WORKSPACE_ROOT"
  case "$ws/" in
    "$top"/*) owned=1 ;;
  esac
  if [ -n "$main" ]; then
    case "$ws/" in
      "$main"/*) owned=1 ;;
    esac
  fi

  if [ "$owned" -eq 1 ] && [ -n "$configured" ]; then
    name="$configured"
  elif [ -n "$main" ]; then
    name="${main%/}"
    name="${name##*/}"
  elif [ "$owned" -eq 1 ]; then
    _tasks_die "$EXIT_REFUSED" "cannot confirm the main checkout of the repository at $top, so its project name is not known — set project.name in $CONFIG"
  else
    _tasks_die "$EXIT_REFUSED" "cannot confirm the main checkout of the repository at $top (a submodule, or a separate git directory), and the parent configuration's project.name names the whole workspace, not this repository — add a .claude/configuration.yml inside this repository that sets project.name"
  fi
  if ! _tasks_valid_project "$name"; then
    if [ "$owned" -eq 1 ]; then
      _tasks_die "$EXIT_REFUSED" "cannot tag tasks with the project name '$name' (letters, digits, dot, underscore and dash only) — set project.name in $CONFIG"
    fi
    _tasks_die "$EXIT_REFUSED" "cannot tag tasks with the project name '$name' (letters, digits, dot, underscore and dash only) — add a .claude/configuration.yml inside this repository that sets project.name"
  fi
  TASKS_PROJECT="$name"
  TASKS_PROJECT_ROOT="$top"
  TASKS_PROJECT_OWNED="$owned"
}

# The shared store must not sit in a git work tree: adding a task would change
# a tracked file again. <dir> is where to ask git (the store, or during setup
# its nearest existing ancestor); <store> is what the message names.
_tasks_gate_outside_git() {
  local dir="${1}" store="${2}" top
  command -v git >/dev/null 2>&1 \
    || _tasks_die "$EXIT_REFUSED" "git is required in global mode, to prove the shared task store is outside every repository"
  top="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
  [ -n "$top" ] || return 0
  if [ -n "${HOME:-}" ] && [ "$top" -ef "$HOME" ]; then
    _tasks_die "$EXIT_REFUSED" "the shared task store $store is inside a git repository rooted at your home directory ($top) — a dotfiles repository, most likely. Everything under your home directory is inside that work tree, ignored or not, so no ~/ path can be used: give the shared list an absolute path outside your home directory"
  fi
  _tasks_die "$EXIT_REFUSED" "the shared task store $store is inside the git repository $top — it must live outside every repository, or adding a task would change a tracked file again"
}

# Setup only: create a missing store and every missing directory above it,
# each private to the user. `mkdir -p -m 700` sets the mode on the last
# directory alone — the location root above it would come out group-writable
# under a umask of 002 — so each level is made separately. The repository check
# runs on the nearest existing ancestor first, so nothing is created inside a
# repository and then refused.
_tasks_create_private_dirs() {
  local path="${1}" probe="${1}" d
  local -a missing=()
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    missing=("$probe" "${missing[@]}")
    probe="${probe%/*}"
    [ -n "$probe" ] || probe="/"
  done
  if [ ! -d "$probe" ] || [ -L "$probe" ]; then
    _tasks_die "$EXIT_REFUSED" "cannot create the shared task store at $path: $probe is not a directory"
  fi
  _tasks_gate_outside_git "$probe" "$path"
  for d in "${missing[@]}"; do
    ( umask 077 && mkdir -- "$d" ) 2>/dev/null \
      || _tasks_die "$EXIT_SYSTEM" "could not create $d for the shared task store"
  done
  TASKS_STORE_CREATED=true
}

# Owned by this user, not writable by anyone else.
_tasks_gate_private_dir() {
  local d="${1}" loose
  [ -O "$d" ] || _tasks_die "$EXIT_REFUSED" "$d is owned by another user; the shared task store must be your own"
  loose="$(find "$d" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) -print 2>/dev/null)" \
    || _tasks_die "$EXIT_REFUSED" "could not read the permissions of $d"
  [ -z "$loose" ] || _tasks_die "$EXIT_REFUSED" "$d can be written by other users — run chmod go-w $d; nothing was written"
}

# Before any write in global mode. A store someone else's permissions make
# read-only must refuse up front, not fail halfway through a migration.
_tasks_require_writable() {
  [ "$TASKS_MODE" = "global" ] || return 0
  local d
  for d in "$TASKS_DIR" "$TASKS_DIR/items" "$TASKS_DIR/archive" "$TASKS_DIR/migration"; do
    [ -e "$d" ] || continue
    [ -w "$d" ] || _tasks_die "$EXIT_REFUSED" "cannot write to the shared task store at $d — nothing was written"
  done
}

# The store must not swallow the configuration directory or another artifact.
#
# Refused: at or above the configuration directory; the location root itself
# (`subdir: .`); the same directory as another artifact; a directory containing
# another artifact. Allowed: a directory INSIDE another artifact — nesting is
# normal (refactoring lives in work), and the default .claude/tasks sits inside
# product-knowledge's default `.claude`.
_tasks_gate_overlap() {
  local path="${1}" cfg tmpl names name sub other
  cfg="${CONFIG:-$WORKSPACE_ROOT/.claude/configuration.yml}"
  if nexus_path_holds_config_dir "$path" "$cfg"; then
    _tasks_die "$EXIT_REFUSED" "tasks resolve to $path, which is or contains the configuration directory"
  fi

  if [ -n "${CONFIG:-}" ]; then
    local configured_sub
    configured_sub="$(yq -r 'select(document_index == 0) | .storage.artifacts.tasks.subdir // "tasks"' "$CONFIG" 2>/dev/null)" \
      || _tasks_die "$EXIT_REFUSED" "could not read storage.artifacts.tasks.subdir from $CONFIG"
    if [ "$(normalize_artifact_path "/x/$configured_sub")" = "/x" ]; then
      _tasks_die "$EXIT_REFUSED" "storage.artifacts.tasks.subdir resolves to its location root ($path) — give tasks their own subdirectory"
    fi
  fi

  tmpl="$(_tasks_template_path)" \
    || _tasks_die "$EXIT_SYSTEM" "the plugin's configuration template is unreadable, so the artifact catalog cannot be checked for collisions — reinstall the nexus plugin"
  names="$(_tasks_artifact_names "$tmpl")" \
    || _tasks_die "$EXIT_SYSTEM" "could not read the artifact catalog from $tmpl"
  if [ -n "${CONFIG:-}" ]; then
    local configured
    configured="$(_tasks_artifact_names "$CONFIG")" \
      || _tasks_die "$EXIT_REFUSED" "could not read storage.artifacts from $CONFIG"
    names="$(printf '%s\n%s\n' "$names" "$configured" | LC_ALL=C sort -u)"
  fi
  [ -n "$names" ] || _tasks_die "$EXIT_SYSTEM" "the artifact catalog in $tmpl is empty"

  while IFS= read -r name; do
    { [ -n "$name" ] && [ "$name" != "tasks" ]; } || continue
    sub="$(_tasks_template_subdir "$tmpl" "$name")"
    other="$(resolve_artifact_typed "$name" "$sub" 2>/dev/null)" || continue
    other="${other%%|*}"
    [ -n "$other" ] || continue
    if [ "$other" = "$path" ]; then
      _tasks_die "$EXIT_REFUSED" "tasks resolve to $path, the same directory as the '$name' artifact"
    fi
    case "$other/" in
      "$path"/*)
        _tasks_die "$EXIT_REFUSED" "tasks resolve to $path, which contains the '$name' artifact ($other)"
        ;;
    esac
  done <<< "$names"
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

# Task ids are generated, never derived from a title, and checked before any
# path is built from one.
_tasks_valid_id() {
  local LC_ALL=C
  [[ "${1}" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]]
}

_tasks_require_id() {
  _tasks_valid_id "${1}" || _tasks_die "$EXIT_REFUSED" "not a task id: '${1}' (expected YYYYMMDD-HHMMSS-xxxx)"
}

readonly TASKS_PENDING_STATUSES="proposed not_started needs_discussion"
readonly TASKS_PRIORITIES="emergency high medium low"

_tasks_word_in() {
  local word="${1}" list="${2}" item
  for item in $list; do
    [ "$item" = "$word" ] && return 0
  done
  return 1
}

_tasks_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# A requirements identifier as /create-requirements composes it.
_tasks_valid_identifier() {
  local LC_ALL=C
  [[ "${1}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$ ]]
}

# ---------------------------------------------------------------------------
# Store access
# ---------------------------------------------------------------------------
#
# Layout under TASKS_DIR:
#   manifest.json      live index of open tasks — a rebuildable cache
#   items/{id}.json    one file per open task — the source of truth
#   archive/{id}.json  done tasks, outside the index
#   migration/         the one TODO.md backup
#
# Archive wins: a task is archived if archive/{id}.json is a regular file, whatever
# items/ or the index say. That is what keeps an interrupted `done` to exactly
# one copy.

# Every write goes to a temp file in the same directory and is renamed into
# place, so a reader sees the old file or the new one, never half of either.
#
# The target must be absent or a regular file. `mv` onto an existing directory
# moves the temp file INTO it and reports success, which would leave a
# directory named like a task file and a write that never happened.
_tasks_write_json() {
  local target="${1}" json="${2}" tmp
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
  fi
  tmp="$(mktemp "${target%/*}/.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$json" > "$tmp" || ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

# The overlap check compares path strings. A store directory that is a symlink
# (a cloned repository shipping `.claude/tasks -> .claude/work`, say) would pass
# it and send every write into another artifact's files, so none of the store's
# own directories may be one.
_tasks_refuse_symlinked_store() {
  local d
  for d in "$TASKS_DIR" "$TASKS_DIR/items" "$TASKS_DIR/archive" "$TASKS_DIR/migration"; do
    [ ! -L "$d" ] || _tasks_die "$EXIT_REFUSED" "$d is a symlink; the task store must be a real directory"
  done
}

_tasks_ensure_store() {
  _tasks_refuse_symlinked_store
  # The marker comes first: it is what lets a later run tell a shared store
  # from a per-repository one, and what the store-shape gate asks for.
  if [ "$TASKS_MODE" = "global" ] && [ ! -e "$TASKS_DIR/store.json" ]; then
    _tasks_write_json "$TASKS_DIR/store.json" '{"mode":"global","version":1}' \
      || _tasks_die "$EXIT_SYSTEM" "could not write $TASKS_DIR/store.json"
  fi
  mkdir -p "$TASKS_DIR/items" "$TASKS_DIR/archive" \
    || _tasks_die "$EXIT_SYSTEM" "could not create the task store at $TASKS_DIR"
}

# The open tasks, as a JSON array of detail objects, read from items/ with
# archive-wins applied. A detail file that is not valid JSON is reported and
# left out; it is never silently counted as a task or deleted.
#
# Task JSON never travels as a command-line argument anywhere in this script:
# one argument is capped at 128 KiB on Linux, and a store with long descriptions
# passes that. Files are named on the command line; contents go through files
# or stdin.
_tasks_read_open() {
  local f id
  local -a valid=()
  [ -d "$TASKS_DIR/items" ] || { printf '[]\n'; return 0; }
  for f in "$TASKS_DIR"/items/*.json; do
    [ -f "$f" ] || continue
    id="${f##*/}"
    id="${id%.json}"
    _tasks_valid_id "$id" || { _tasks_log "ignoring $f: not a task id"; continue; }
    [ ! -f "$TASKS_DIR/archive/$id.json" ] || continue
    # Exactly one JSON value, an object with this id. `jq -e` alone judges only
    # the last value in a file, and the slurp below reads all of them.
    if ! jq -se --arg id "$id" 'length == 1 and (.[0] | type == "object" and .id == $id)' "$f" >/dev/null 2>&1; then
      _tasks_log "ignoring $f: not a valid task file"
      continue
    fi
    valid+=("$f")
  done
  if [ "${#valid[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  jq -cs '.' "${valid[@]}"
}

# The one rule for a task's ticket key: the first ABC-123 shaped word in the title.
readonly TASKS_TICKET_KEY_DEF='def ticket_key: (capture("(?<k>\\b[A-Z]+-[0-9]+\\b)").k) // null;'

# A task's project as a list shows it: the stored name when it is a valid one,
# null when none was recorded (local mode, or a task from before CL-122), and
# "invalid" for anything else — a hand-edited value is never printed as a name.
# shellcheck disable=SC2016  # a jq program
readonly TASKS_PROJECT_SHOWN='def shown_project:
  if (.project // null) == null then null
  elif (.project | type) == "string" and (.project | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) then .project
  else "invalid" end;'

readonly TASKS_SORT='
  def rank: {"emergency": 4, "high": 3, "medium": 2, "low": 1}[.priority] // 0;
  sort_by([-rank, .created_at, .id])'

# Rewrite manifest.json from items/. Returns non-zero when the write fails;
# the detail files are untouched either way.
_tasks_write_index() {
  local open index
  open="$(_tasks_read_open)" || return 1
  index="$(jq -c --arg ts "$(_tasks_now)" "
    ($TASKS_SORT) as \$sorted
    | {version: \"1.0\", last_updated: \$ts, artifact_type: \"tasks\"}
    + {items: [\$sorted[] | {id, title, status, priority, category, project: (.project // null), created_at, updated_at, promoted_to, path: (\"items/\" + .id + \".json\")}]}
    | .total_items = (.items | length)
    | {version, last_updated, artifact_type, total_items, items}" <<< "$open")" || return 1
  _tasks_write_json "$TASKS_DIR/manifest.json" "$index"
}

# The ordered list a user numbers from. `open` is every open task (/todo list);
# `pending` is every task nobody has started; `workable` is what /todo-work
# offers — pending plus in progress, so a task whose handoff went nowhere stays
# visible instead of dropping out of the pick list. Promoted tasks are left out
# of `workable`: they already have a requirements session, and /resume-work
# continues it. A number always names a position in the list the caller states,
# so the same N never means two different tasks.
#
# In global mode a second filter applies first: `current` (the default there)
# keeps the current project's tasks, `all` keeps every project's. Numbers are
# positions in the filtered list, so a number read against the current
# project's list names a task of the current project. In local mode a store
# holds one project and the filter is always `all`.
_tasks_list_json() {
  local scope="${1}" filter="${2:-}" open statuses
  case "$scope" in
    pending) statuses="$TASKS_PENDING_STATUSES" ;;
    workable) statuses="$TASKS_PENDING_STATUSES in_progress" ;;
    *) statuses="" ;;
  esac
  filter="$(_tasks_effective_filter "$filter")"
  open="$(_tasks_read_open)"
  jq -c --arg scope "$scope" --arg statuses "$statuses" --arg filter "$filter" --arg project "$TASKS_PROJECT" "
    ($TASKS_SORT)
    | map(select(\$filter == \"all\" or .project == \$project))
    | map(select(\$scope == \"open\" or (.status as \$s | (\$statuses | split(\" \")) | index(\$s))))
    | to_entries | map(.value + {n: (.key + 1)})" <<< "$open"
}

# The project filter a caller asked for, or the mode's default. Anything but
# current or all is refused by the op that parsed it, never here.
_tasks_effective_filter() {
  if [ "$TASKS_MODE" != "global" ]; then
    printf 'all\n'
  elif [ -n "${1}" ]; then
    printf '%s\n' "${1}"
  else
    printf 'current\n'
  fi
}

_tasks_require_filter() {
  case "${1}" in
    ''|current|all) : ;;
    *) _tasks_die "$EXIT_REFUSED" "--project must be current or all" ;;
  esac
}

# A reference the user typed — a number or a task id — read from the ref file
# of an input directory, never from a shell word. Sets TASKS_REF_ID or
# TASKS_REF_N.
TASKS_REF_ID=""
TASKS_REF_N=""
_tasks_read_ref() {
  local input="${1}" ref
  TASKS_REF_ID=""
  TASKS_REF_N=""
  _tasks_check_input_dir "$input"
  ref="$(jq -r '.' <<< "$(_tasks_field "$input" ref)")"
  ref="${ref//[[:space:]]/}"
  if [[ "$ref" =~ ^[0-9]+$ ]]; then TASKS_REF_N="$ref"; else TASKS_REF_ID="$ref"; fi
}

# Resolve --id or --n (against a scope) to one open task id, or refuse.
# The answer is left in TASKS_PICKED rather than printed: a refusal raised inside
# a command substitution exits only the subshell, and the parent would then
# report it as an unexpected failure instead of the refusal it is.
TASKS_PICKED=""
_tasks_pick() {
  local id="${1}" n="${2}" scope="${3}" filter="${4:-}" list
  TASKS_PICKED=""
  if [ -n "$id" ]; then
    _tasks_require_id "$id"
    if [ -f "$TASKS_DIR/archive/$id.json" ]; then
      _tasks_die "$EXIT_REFUSED" "task $id is already done"
    fi
    [ -f "$TASKS_DIR/items/$id.json" ] || _tasks_die "$EXIT_REFUSED" "no open task with id $id"
    jq -se --arg id "$id" 'length == 1 and (.[0] | type == "object" and .id == $id)' "$TASKS_DIR/items/$id.json" >/dev/null 2>&1 \
      || _tasks_die "$EXIT_REFUSED" "items/$id.json is not a valid task file — it is left out of every list; repair or remove it"
    TASKS_PICKED="$id"
    return 0
  fi
  [[ "$n" =~ ^[1-9][0-9]{0,5}$ ]] || _tasks_die "$EXIT_REFUSED" "not a task number: '$n'"
  list="$(_tasks_list_json "$scope" "$filter")"
  id="$(jq -r --argjson n "$n" '.[] | select(.n == $n) | .id' <<< "$list")"
  if [ -z "$id" ]; then
    if [ "$(_tasks_effective_filter "$filter")" = "current" ]; then
      _tasks_die "$EXIT_REFUSED" "no task #$n in the $scope list for project $TASKS_PROJECT ($(jq length <<< "$list") tasks)"
    fi
    _tasks_die "$EXIT_REFUSED" "no task #$n in the $scope list ($(jq length <<< "$list") tasks)"
  fi
  TASKS_PICKED="$id"
}

# Read a Write-tool input directory, created by `--op input-dir`. Only a
# directory with exactly that shape is accepted, because its path reaches this
# script as an argument the model substituted.
_tasks_check_input_dir() {
  local dir="${1}" base="$HOME/.claude/tmp"
  local LC_ALL=C
  { [[ "$dir" =~ ^.*/tasks-input\.[A-Za-z0-9]{6}$ ]] && [ "${dir%/*}" = "$base" ]; } \
    || _tasks_die "$EXIT_REFUSED" "not a task input directory: '$dir' (create one with --op input-dir)"
  { [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]; } \
    || _tasks_die "$EXIT_REFUSED" "task input directory $dir is missing, a symlink, or not owned by you"
  TASKS_INPUT_DIR="$dir"
}

# One field of an input directory as a JSON string; "" when the file is absent.
# Exactly one trailing newline is removed — the Write tool may or may not add
# one, and a title must not differ by that.
_tasks_field() {
  local dir="${1}" name="${2}"
  if [ -f "$dir/$name" ] && [ ! -L "$dir/$name" ]; then
    jq -n --rawfile v "$dir/$name" '$v | sub("\n$"; "")'
  else
    printf '""\n'
  fi
}

# ---------------------------------------------------------------------------
# Ops
# ---------------------------------------------------------------------------

_tasks_op_resolve() {
  _tasks_resolve
  jq -cn --arg dir "$TASKS_DIR" --arg mode "$TASKS_MODE" --arg project "$TASKS_PROJECT" --arg root "$TASKS_PROJECT_ROOT" \
    '{ok: true, dir: $dir, mode: $mode}
     + (if $mode == "global" then {project: $project, project_root: $root} else {} end)'
}

# A private directory for the Write tool to put field files in. Text reaches
# the store only as file contents read with --rawfile — never as a shell word,
# never through a heredoc whose body could end it early.
_tasks_op_input_dir() {
  local base="$HOME/.claude/tmp" dir
  { ( umask 077 && mkdir -p "$base" ) && chmod 700 "$base"; } \
    || _tasks_die "$EXIT_SYSTEM" "could not create $base"
  dir="$(mktemp -d "$base/tasks-input.XXXXXX")" \
    || _tasks_die "$EXIT_SYSTEM" "could not create an input directory under $base"
  jq -cn --arg dir "$dir" '{ok: true, input_dir: $dir}'
}

# The one place a task id is made: timestamp plus two random bytes, retried
# while it collides with an open or archived task, and given up after twenty
# tries rather than spun forever. Only _tasks_publish_new calls this; a second
# copy of the loop once lost the cap.
_tasks_new_id() {
  local id tries=0
  while :; do
    id="$(date -u +%Y%m%d-%H%M%S)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
    [ -e "$TASKS_DIR/items/$id.json" ] || [ -e "$TASKS_DIR/archive/$id.json" ] || break
    tries=$((tries + 1))
    [ "$tries" -lt 20 ] || return 1
  done
  printf '%s\n' "$id"
}

# Write a NEW task file under a fresh id, exclusively (CL-122). The template is
# the complete task document; its id is set here.
#
# The id check in _tasks_new_id and the write are two steps, and in a shared
# store two projects can take the same id between them — the same second and
# the same two random bytes is unlikely, not impossible. `mv`, the rename every
# update uses, would then replace the other project's task without a word. So a
# new file is published with `ln`, which fails when the name exists: a
# collision regenerates the id and tries again, under the same cap of twenty.
# An `ln` that fails for any other reason — a filesystem without hard links —
# is refused, never retried with `mv`, because that is the overwrite this
# exists to prevent.
#
# Sets TASKS_PUBLISHED_ID. Returns 1 when no free id was found or the file
# could not be written, 2 when the filesystem cannot publish exclusively.
TASKS_PUBLISHED_ID=""
_tasks_publish_new() {
  local sub="${1}" template="${2}" dir="$TASKS_DIR/${1}" tries=0 id tmp
  TASKS_PUBLISHED_ID=""
  case "$sub" in items|archive) : ;; *) return 1 ;; esac
  while :; do
    id="$(_tasks_new_id)" || return 1
    _tasks_valid_id "$id" || return 1
    tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 1
    if ! jq -c --arg id "$id" '.id = $id' <<< "$template" > "$tmp" || ! jq -e . "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      return 1
    fi
    if ln "$tmp" "$dir/$id.json" 2>/dev/null; then
      rm -f "$tmp"
      TASKS_PUBLISHED_ID="$id"
      return 0
    fi
    if [ ! -e "$dir/$id.json" ] && [ ! -L "$dir/$id.json" ]; then
      # No hard links here. A per-repository store has one writer at a time,
      # so a rename is what it always used and is still safe — local mode must
      # not start failing on a filesystem it worked on (exFAT, some mounts).
      # A shared store has no such guarantee and refuses instead.
      if [ "$TASKS_MODE" != "global" ] && mv -f "$tmp" "$dir/$id.json" 2>/dev/null; then
        TASKS_PUBLISHED_ID="$id"
        return 0
      fi
      rm -f "$tmp"
      return 2
    fi
    rm -f "$tmp"
    tries=$((tries + 1))
    [ "$tries" -lt 20 ] || return 1
  done
}

# Publish a new task file under a CHOSEN id, exclusively — used to keep a
# migrated task's original id. Returns 0 when published, 3 when the name is
# taken (the caller falls back to a fresh id), and 1 or 2 as _tasks_publish_new.
_tasks_publish_as() {
  local sub="${1}" id="${2}" template="${3}" dir="$TASKS_DIR/${1}" tmp
  TASKS_PUBLISHED_ID=""
  case "$sub" in items|archive) : ;; *) return 1 ;; esac
  _tasks_valid_id "$id" || return 1
  [ ! -e "$TASKS_DIR/items/$id.json" ] && [ ! -e "$TASKS_DIR/archive/$id.json" ] || return 3
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 1
  if ! jq -c --arg id "$id" '.id = $id' <<< "$template" > "$tmp" || ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  if ln "$tmp" "$dir/$id.json" 2>/dev/null; then
    rm -f "$tmp"
    TASKS_PUBLISHED_ID="$id"
    return 0
  fi
  rm -f "$tmp"
  if [ -e "$dir/$id.json" ] || [ -L "$dir/$id.json" ]; then
    return 3
  fi
  return 2
}

_tasks_op_add() {
  local input=""
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --input) input="${2:-}"; shift 2 ;;
      *) _tasks_die "$EXIT_REFUSED" "add: unknown option '${1}'" ;;
    esac
  done
  _tasks_check_input_dir "$input"
  _tasks_resolve
  _tasks_require_writable

  # Every field is read from its file by jq, never captured into an argument.
  local field
  for field in title description priority category scope related status; do
    if [ -L "$input/$field" ] || { [ -e "$input/$field" ] && [ ! -f "$input/$field" ]; }; then
      _tasks_die "$EXIT_REFUSED" "add: $field in the input directory is not a regular file"
    fi
    [ -e "$input/$field" ] || : > "$input/$field"
  done

  jq -e -n --rawfile v "$input/title" '$v | sub("\n$"; "") | length > 0' >/dev/null \
    || _tasks_die "$EXIT_REFUSED" "add: a title is required"
  jq -e -n --rawfile v "$input/title" '$v | sub("\n$"; "") | test("\n") | not' >/dev/null \
    || _tasks_die "$EXIT_REFUSED" "add: a title must be a single line"
  # Membership is decided inside jq on the whole value: capturing it into the
  # shell first would strip trailing newlines and accept "low" followed by junk.
  # jq exits 5 for the error() below and 2 when it cannot read the file; only
  # the first is a verdict on the value.
  local p s jrc=0
  p="$(jq -r -n --rawfile v "$input/priority" \
    '($v | sub("\n$"; "") | ascii_downcase) as $p
     | if $p == "" then "medium" elif ($p | IN("emergency", "high", "medium", "low")) then $p else error("bad") end' 2>/dev/null)" || jrc=$?
  case "$jrc" in
    0) : ;;
    5) _tasks_die "$EXIT_REFUSED" "add: priority must be one of: $TASKS_PRIORITIES" ;;
    *) _tasks_die "$EXIT_SYSTEM" "add: could not read the priority field (jq exit $jrc)" ;;
  esac
  jrc=0
  s="$(jq -r -n --rawfile v "$input/status" \
    '($v | sub("\n$"; "")) as $s
     | if $s == "" then "proposed" elif ($s | IN("proposed", "not_started", "needs_discussion")) then $s else error("bad") end' 2>/dev/null)" || jrc=$?
  case "$jrc" in
    0) : ;;
    5) _tasks_die "$EXIT_REFUSED" "add: a new task's status must be one of: $TASKS_PENDING_STATUSES" ;;
    *) _tasks_die "$EXIT_SYSTEM" "add: could not read the status field (jq exit $jrc)" ;;
  esac

  _tasks_ensure_store
  local id="" now
  now="$(_tasks_now)"

  # ticket_key is derived here, by the same rule migrate uses — the first
  # ABC-123 shaped key in the title — so no caller has its own version of it.
  local doc
  doc="$(jq -cn \
    --arg id "$id" --arg now "$now" --arg priority "$p" --arg status "$s" --arg project "$TASKS_PROJECT" \
    --rawfile title "$input/title" --rawfile description "$input/description" \
    --rawfile category "$input/category" --rawfile scope "$input/scope" --rawfile related "$input/related" \
    "$TASKS_TICKET_KEY_DEF"'
    def one: sub("\n$"; "");
    ($title | one) as $t
    | {id: $id, title: $t, status: $status, priority: $priority,
       category: ($category | one), scope: ($scope | one), description: ($description | one), related: ($related | one),
       ticket_key: ($t | ticket_key),
       project: (if $project == "" then null else $project end),
       created_at: $now, updated_at: $now, promoted_to: null, migrated_from: null}')" \
    || _tasks_die "$EXIT_SYSTEM" "add: could not assemble the task"
  local prc=0
  _tasks_publish_new items "$doc" || prc=$?
  case "$prc" in
    0) id="$TASKS_PUBLISHED_ID" ;;
    2) _tasks_die "$EXIT_SYSTEM" "FAILED at item-write: this filesystem cannot create a task file exclusively (hard links unsupported), and a plain rename could overwrite another project's task — nothing was added" ;;
    *) _tasks_die "$EXIT_SYSTEM" "FAILED at item-write: could not write a new task file — nothing was added" ;;
  esac
  _tasks_remove_input_dir
  if ! _tasks_write_index; then
    _tasks_log "FAILED at index-write: task $id was added, but manifest.json could not be rewritten — run /rebuild-index tasks"
    jq -cn --arg id "$id" '{ok: true, id: $id, index: "stale"}'
    TASKS_REPORTED=1
    exit "$EXIT_INDEX_STALE"
  fi
  jq -cn --arg id "$id" '{ok: true, id: $id}'
}

# Does the store hold any task of the current project, open or archived?
_tasks_project_has_any() {
  local f
  for f in "$TASKS_DIR"/items/*.json "$TASKS_DIR"/archive/*.json; do
    [ -f "$f" ] || continue
    if jq -e --arg p "$TASKS_PROJECT" '.project == $p' "$f" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

_tasks_op_list() {
  local scope="open" filter=""
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --scope) scope="${2:-}"; shift 2 ;;
      --project) filter="${2:-}"; shift 2 ;;
      *) _tasks_die "$EXIT_REFUSED" "list: unknown option '${1}'" ;;
    esac
  done
  case "$scope" in open|pending|workable) : ;; *) _tasks_die "$EXIT_REFUSED" "list: --scope must be open, pending or workable" ;; esac
  _tasks_require_filter "$filter"
  _tasks_resolve
  filter="$(_tasks_effective_filter "$filter")"
  local list migrate=false
  list="$(_tasks_list_json "$scope" "$filter")"
  # The hint for AC-3.7: a TODO.md sits at the project root and the store holds
  # nothing at all, open or archived. In a shared store "nothing" means nothing
  # of THIS project's: other projects' tasks say nothing about whether this
  # one's TODO.md was imported. Nothing is imported here.
  if [ "$TASKS_MODE" = "global" ]; then
    if [ -f "$TASKS_PROJECT_ROOT/TODO.md" ] && ! _tasks_project_has_any; then
      migrate=true
    fi
  else
    local archived=0 f
    for f in "$TASKS_DIR"/archive/*.json; do
      [ -f "$f" ] && { archived=1; break; }
    done
    if [ "$(_tasks_list_json open | jq length)" -eq 0 ] && [ "$archived" -eq 0 ] \
       && [ -f "$WORKSPACE_ROOT/TODO.md" ]; then
      migrate=true
    fi
  fi
  jq -c --arg scope "$scope" --argjson migrate "$migrate" --arg mode "$TASKS_MODE" --arg project "$TASKS_PROJECT" --arg filter "$filter" \
    "$TASKS_PROJECT_SHOWN"'
    {ok: true, scope: $scope, mode: $mode, filter: $filter, total: length, migrate_available: $migrate}
    + (if $mode == "global" then {project: $project} else {} end)
    + {tasks: [.[] | {n, id, title, status, priority, category, project: shown_project, created_at, promoted_to}]}' <<< "$list"
}

_tasks_op_show() {
  local id="" n="" scope="open" handoff=0 filter="" input=""
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --id) id="${2:-}"; shift 2 ;;
      --n) n="${2:-}"; shift 2 ;;
      --scope) scope="${2:-}"; shift 2 ;;
      --project) filter="${2:-}"; shift 2 ;;
      --input) input="${2:-}"; shift 2 ;;
      --for-handoff) handoff=1; shift ;;
      *) _tasks_die "$EXIT_REFUSED" "show: unknown option '${1}'" ;;
    esac
  done
  case "$scope" in open|pending|workable) : ;; *) _tasks_die "$EXIT_REFUSED" "show: --scope must be open, pending or workable" ;; esac
  _tasks_require_filter "$filter"
  if [ -n "$input" ]; then
    # So /todo can show a typed reference back for confirmation before acting
    # on it, without the reference ever reaching a command line.
    _tasks_read_ref "$input"
    id="$TASKS_REF_ID"
    n="$TASKS_REF_N"
  fi
  [ -n "$id" ] || [ -n "$n" ] || _tasks_die "$EXIT_REFUSED" "show: give --id, --n or --input"
  _tasks_resolve
  _tasks_pick "$id" "$n" "$scope" "$filter"
  id="$TASKS_PICKED"
  local doc
  doc="$(jq -c . "$TASKS_DIR/items/$id.json")" || _tasks_die "$EXIT_SYSTEM" "could not read items/$id.json"
  if [ "$handoff" -eq 0 ]; then
    jq -c --arg dir "$TASKS_DIR" '{ok: true, store: $dir, task: .}' <<< "$doc"
    return 0
  fi
  # Task text goes to /create-requirements wrapped in untrusted-content markers.
  # Text carrying its own closing marker would end that fence early, so the
  # handoff stops on a forged marker, and on a scan that could not run. The
  # project value is scanned too: it is stored text like the rest.
  _tasks_source_shared forged-marker-scan.sh
  # The text is read before it is scanned. In a pipeline under pipefail a
  # failed jq is masked by the scanner's own "none found" (1), so a scan that
  # saw no bytes reported clean. A read that fails is a scan that failed.
  local scan_rc=0 verdict text
  if text="$(jq -r '.title + "\n" + .description + "\n" + ((.project // "") | tostring)' <<< "$doc")"; then
    nexus_scan_forged_markers <<< "$text" >/dev/null || scan_rc=$?
    case "$scan_rc" in
      1) verdict="clean" ;;
      0) verdict="found" ;;
      *) verdict="failed" ;;
    esac
  else
    verdict="failed"
  fi
  # Whose task this is (CL-122). A handoff starts a requirements session — a
  # branch and a work directory — in the CURRENT repository, so in a shared
  # store only the current project's tasks may go. An invalid stored value is
  # refused in either mode: it is never a name and never reaches a prompt.
  local project_check allowed=1
  project_check="$(jq -r --arg p "$TASKS_PROJECT" "$TASKS_PROJECT_SHOWN"'
    shown_project as $s
    | if $s == null then "null" elif $s == "invalid" then "invalid" elif $s == $p then "current" else "other" end' <<< "$doc")" \
    || _tasks_die "$EXIT_SYSTEM" "could not read the project of task $id"
  case "$project_check" in
    current) : ;;
    invalid) allowed=0 ;;
    *) [ "$TASKS_MODE" != "global" ] || allowed=0 ;;
  esac
  jq -c --arg dir "$TASKS_DIR" --arg verdict "$verdict" --arg check "$project_check" --argjson allowed "$allowed" \
    '{ok: ($verdict == "clean" and $allowed == 1), store: $dir, marker_scan: $verdict, project_check: $check, task: .}' <<< "$doc"
  case "$verdict" in
    clean) : ;;
    found) _tasks_die "$EXIT_REFUSED" "task $id contains a content-boundary marker — refusing to hand it off" ;;
    *) _tasks_die "$EXIT_SYSTEM" "the content-boundary marker scan failed on task $id — refusing to hand it off" ;;
  esac
  [ "$allowed" -eq 1 ] && return 0
  case "$project_check" in
    other)
      _tasks_die "$EXIT_REFUSED" "task $id belongs to project $(jq -r .project <<< "$doc"), not $TASKS_PROJECT — hand it off from that project, where its requirements session and branch belong"
      ;;
    null)
      _tasks_die "$EXIT_REFUSED" "task $id has no project recorded, so it cannot be handed off from a shared store — re-add it from the project it belongs to, or close it"
      ;;
    *)
      _tasks_die "$EXIT_REFUSED" "task $id has an invalid project value — repair or remove items/$id.json; it is never handed off as it stands"
      ;;
  esac
}

# The only way a status changes. Transitions:
#   pending -> in_progress -> promoted, and any open status -> done (see `done`).
# A promoted task stays promoted, with its link, until it is done.
_tasks_op_set_status() {
  local id="" to="" promoted_to="" store=""
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --id) id="${2:-}"; shift 2 ;;
      --status) to="${2:-}"; shift 2 ;;
      --promoted-to) promoted_to="${2:-}"; shift 2 ;;
      --store) store="${2:-}"; shift 2 ;;
      *) _tasks_die "$EXIT_REFUSED" "set-status: unknown option '${1}'" ;;
    esac
  done
  _tasks_require_id "$id"
  if [ -n "$store" ]; then
    _tasks_use_store "$store"
  else
    _tasks_resolve
    _tasks_require_writable
  fi
  _tasks_pick "$id" "" open
  id="$TASKS_PICKED"
  local from
  from="$(jq -r '.status' "$TASKS_DIR/items/$id.json")" || _tasks_die "$EXIT_SYSTEM" "could not read items/$id.json"
  case "$to" in
    in_progress)
      _tasks_word_in "$from" "$TASKS_PENDING_STATUSES" \
        || _tasks_die "$EXIT_REFUSED" "task $id is '$from'; only a pending task can be started"
      [ -z "$promoted_to" ] || _tasks_die "$EXIT_REFUSED" "set-status: --promoted-to only applies to promoted"
      ;;
    promoted)
      [ "$from" = "in_progress" ] \
        || _tasks_die "$EXIT_REFUSED" "task $id is '$from'; only an in-progress task can be promoted, and a promoted task keeps its link"
      _tasks_valid_identifier "$promoted_to" \
        || _tasks_die "$EXIT_REFUSED" "set-status: promoted needs --promoted-to <requirements identifier>"
      ;;
    done)
      _tasks_die "$EXIT_REFUSED" "set-status: use --op done to close a task"
      ;;
    *)
      _tasks_die "$EXIT_REFUSED" "set-status: --status must be in_progress or promoted"
      ;;
  esac
  local doc
  doc="$(jq -c --arg to "$to" --arg link "$promoted_to" --arg now "$(_tasks_now)" \
    '.status = $to | .updated_at = $now | (if $to == "promoted" then .promoted_to = $link else . end)' \
    "$TASKS_DIR/items/$id.json")" || _tasks_die "$EXIT_SYSTEM" "could not read items/$id.json"
  _tasks_write_json "$TASKS_DIR/items/$id.json" "$doc" \
    || _tasks_die "$EXIT_SYSTEM" "FAILED at item-write: task $id is unchanged"
  if ! _tasks_write_index; then
    _tasks_log "FAILED at index-write: task $id is now '$to' in its own file, but manifest.json could not be rewritten — run /rebuild-index tasks"
    jq -cn --arg id "$id" --arg to "$to" '{ok: true, id: $id, status: $to, index: "stale"}'
    TASKS_REPORTED=1
    exit "$EXIT_INDEX_STALE"
  fi
  jq -cn --arg id "$id" --arg to "$to" '{ok: true, id: $id, status: $to}'
}

# Close any open task. Order: archive file, then remove the item, then the
# index. Each step that fails says which, and archive-wins keeps one copy.
_tasks_op_done() {
  local id="" n="" input="" filter=""
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --id) id="${2:-}"; shift 2 ;;
      --n) n="${2:-}"; shift 2 ;;
      --input) input="${2:-}"; shift 2 ;;
      --project) filter="${2:-}"; shift 2 ;;
      *) _tasks_die "$EXIT_REFUSED" "done: unknown option '${1}'" ;;
    esac
  done
  _tasks_require_filter "$filter"
  if [ -n "$input" ]; then
    # A reference the user typed arrives as a file, never as a shell word.
    _tasks_read_ref "$input"
    id="$TASKS_REF_ID"
    n="$TASKS_REF_N"
  fi
  [ -n "$id" ] || [ -n "$n" ] || _tasks_die "$EXIT_REFUSED" "done: give --id, --n or --input"
  _tasks_resolve
  _tasks_require_writable
  _tasks_pick "$id" "$n" open "$filter"
  id="$TASKS_PICKED"
  local doc
  doc="$(jq -c --arg now "$(_tasks_now)" '.status = "done" | .updated_at = $now' "$TASKS_DIR/items/$id.json")" \
    || _tasks_die "$EXIT_SYSTEM" "FAILED at item-read: task $id is unchanged"
  _tasks_ensure_store
  _tasks_write_json "$TASKS_DIR/archive/$id.json" "$doc" \
    || _tasks_die "$EXIT_SYSTEM" "FAILED at archive-write: task $id is unchanged and still open"
  [ -z "$input" ] || _tasks_remove_input_dir
  if ! rm -f "$TASKS_DIR/items/$id.json" || [ -e "$TASKS_DIR/items/$id.json" ]; then
    _tasks_die "$EXIT_SYSTEM" "FAILED at item-remove: task $id is archived, and its open copy could not be removed — it is listed once, as done; run /rebuild-index tasks"
  fi
  if ! _tasks_write_index; then
    _tasks_log "FAILED at index-write: task $id is done and archived, but manifest.json could not be rewritten — run /rebuild-index tasks"
    jq -cn --arg id "$id" '{ok: true, id: $id, status: "done", index: "stale"}'
    TASKS_REPORTED=1
    exit "$EXIT_INDEX_STALE"
  fi
  jq -cn --arg id "$id" '{ok: true, id: $id, status: "done"}'
}

# Rebuild the index from items/, applying archive-wins, and remove the open
# copy of any task that is also archived.
_tasks_op_rebuild() {
  [ "$#" -eq 0 ] || _tasks_die "$EXIT_REFUSED" "rebuild takes no options"
  _tasks_resolve
  _tasks_require_writable
  if [ ! -d "$TASKS_DIR" ]; then
    jq -cn --arg dir "$TASKS_DIR" '{ok: true, dir: $dir, open: 0, repaired: 0, note: "no task store yet"}'
    return 0
  fi
  _tasks_ensure_store
  local f id repaired=0
  for f in "$TASKS_DIR"/items/*.json; do
    [ -f "$f" ] || continue
    id="${f##*/}"
    id="${id%.json}"
    _tasks_valid_id "$id" || continue
    if [ -f "$TASKS_DIR/archive/$id.json" ]; then
      rm -f "$f" || _tasks_die "$EXIT_SYSTEM" "could not remove the leftover open copy of archived task $id"
      _tasks_log "task $id is archived; removed its leftover open copy"
      repaired=$((repaired + 1))
    fi
  done
  _tasks_write_index || _tasks_die "$EXIT_SYSTEM" "FAILED at index-write: could not write $TASKS_DIR/manifest.json"
  jq -c --arg dir "$TASKS_DIR" --argjson repaired "$repaired" \
    '{ok: true, dir: $dir, open: .total_items, repaired: $repaired}' "$TASKS_DIR/manifest.json"
}

# A store named explicitly — by /create-requirements, which runs where the
# session's own resolution could find a different store (inside a worktree).
# It must be a task store already: nothing is created through this path.
#
# The location gates (git refusal, overlap) are NOT re-run here, and cannot be:
# they need the configuration the store was resolved against, which a worktree
# session may not see. They ran when /todo-work resolved this same path with
# `show --for-handoff`, which is where the path comes from. What is checked here
# is that the path is safe to use and is a task store.
_tasks_use_store() {
  local store="${1}"
  case "$store" in
    /*) : ;;
    *) _tasks_die "$EXIT_REFUSED" "task store path must be absolute" ;;
  esac
  case "/$store/" in
    */../*|*/./*) _tasks_die "$EXIT_REFUSED" "task store path must not contain . or .. segments" ;;
  esac
  if [[ "$store" == *[\'\"\`\$\\\;\|\&\<\>\*\?\(\)]* || "$store" == *$'\n'* ]]; then
    _tasks_die "$EXIT_REFUSED" "task store path contains shell metacharacters"
  fi
  { [ -d "$store" ] && [ ! -L "$store" ]; } || _tasks_die "$EXIT_REFUSED" "no task store at $store"
  # A task store is its items/ directory. The index is a rebuildable cache, so
  # a missing or broken manifest.json must not make the store unreachable — but
  # one that says it indexes a different artifact means this is not a task store.
  { [ -d "$store/items" ] && [ ! -L "$store/items" ] && [ ! -L "$store/archive" ]; } \
    || _tasks_die "$EXIT_REFUSED" "$store is not a task store (no items/ directory)"
  if [ -f "$store/manifest.json" ]; then
    local kind
    kind="$(jq -r '.artifact_type // ""' "$store/manifest.json" 2>/dev/null)" || kind=""
    [ -z "$kind" ] || [ "$kind" = "tasks" ] \
      || _tasks_die "$EXIT_REFUSED" "$store holds a '$kind' manifest, not a task store"
  fi
  TASKS_DIR="$store"
}

_tasks_op_validate_ref() {
  local store="" id=""
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --store) store="${2:-}"; shift 2 ;;
      --id) id="${2:-}"; shift 2 ;;
      *) _tasks_die "$EXIT_REFUSED" "validate-ref: unknown option '${1}'" ;;
    esac
  done
  _tasks_require_id "$id"
  _tasks_use_store "$store"
  [ ! -f "$TASKS_DIR/archive/$id.json" ] || _tasks_die "$EXIT_REFUSED" "task $id is already done"
  { [ -f "$TASKS_DIR/items/$id.json" ] && [ ! -L "$TASKS_DIR/items/$id.json" ]; } \
    || _tasks_die "$EXIT_REFUSED" "no open task $id in $TASKS_DIR"
  jq -cn --arg dir "$TASKS_DIR" --arg id "$id" '{ok: true, store: $dir, id: $id}'
}

# Read the header of a /todo-work handoff to /create-requirements.
#
# The arguments are written to `{input_dir}/arguments` with the Write tool. They
# are header lines, a blank line, then the task text inside untrusted-content
# markers. Only the header is read for options, and only three whole-line shapes
# are accepted there — a task's own text can therefore never set the task, the
# store, the ticket, or any other option, whatever it contains. Every other
# requirements option stays create-requirements' own business: in task mode it
# simply has none to read.
_tasks_op_parse_handoff() {
  local input=""
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --input) input="${2:-}"; shift 2 ;;
      *) _tasks_die "$EXIT_REFUSED" "parse-handoff: unknown option '${1}'" ;;
    esac
  done
  _tasks_check_input_dir "$input"
  { [ -f "$input/arguments" ] && [ ! -L "$input/arguments" ]; } \
    || _tasks_die "$EXIT_REFUSED" "parse-handoff: $input/arguments is missing"
  local parsed
  parsed="$(jq -Rsc '
    split("\n") as $l
    | ($l | map(test("^\\s*$")) | index(true)) as $blank
    | if $blank == null then {error: "no blank line after the header lines"}
      else
        ($l[0:$blank]) as $head
        | ($l[$blank + 1:] | map(select(test("^\\s*$") | not))) as $body
        | [$head | to_entries[] | select(.value | test("^--from-task [0-9]{8}-[0-9]{6}-[0-9a-f]{4}$|^--task-store /.*$|^--ticket [A-Z]+-[0-9]+$") | not) | .key + 1] as $bad
        | [$head[] | select(startswith("--from-task "))] as $ft
        | [$head[] | select(startswith("--task-store "))] as $ts
        | [$head[] | select(startswith("--ticket "))] as $tk
        | if ($bad | length) > 0 then {error: ("header line " + ($bad | map(tostring) | join(", ")) + " is not --from-task, --task-store or --ticket")}
          elif ($ft | length) != 1 then {error: "exactly one --from-task header line is required"}
          elif ($ts | length) != 1 then {error: "exactly one --task-store header line is required"}
          elif ($tk | length) > 1 then {error: "at most one --ticket header line is allowed"}
          elif ($body | length) < 2 or $body[0] != "<!-- UNTRUSTED-CONTENT:START task -->" or $body[-1] != "<!-- UNTRUSTED-CONTENT:END task -->" then {error: "the task text must follow the header inside UNTRUSTED-CONTENT task markers"}
          else {task_id: ($ft[0] | ltrimstr("--from-task ")), task_store: ($ts[0] | ltrimstr("--task-store ")), ticket: (if ($tk | length) == 1 then ($tk[0] | ltrimstr("--ticket ")) else null end)}
          end
      end' "$input/arguments")" || _tasks_die "$EXIT_SYSTEM" "parse-handoff: could not read $input/arguments"
  local why
  why="$(jq -r '.error // empty' <<< "$parsed")"
  [ -z "$why" ] || _tasks_die "$EXIT_REFUSED" "parse-handoff: $why"
  local id store
  id="$(jq -r .task_id <<< "$parsed")"
  store="$(jq -r .task_store <<< "$parsed")"
  _tasks_require_id "$id"
  _tasks_use_store "$store"
  [ ! -f "$TASKS_DIR/archive/$id.json" ] || _tasks_die "$EXIT_REFUSED" "task $id is already done"
  { [ -f "$TASKS_DIR/items/$id.json" ] && [ ! -L "$TASKS_DIR/items/$id.json" ]; } \
    || _tasks_die "$EXIT_REFUSED" "no open task $id in $TASKS_DIR"
  _tasks_remove_input_dir
  jq -c '{ok: true} + .' <<< "$parsed"
}

# ---------------------------------------------------------------------------
# Migrate: a one-time, re-runnable import of the project's TODO.md
# ---------------------------------------------------------------------------
#
# Order, and it matters: location checks, read TODO.md, back it up once, import.
# A refused location or an unreadable TODO.md stops before the backup, so a run
# that did nothing leaves nothing behind. TODO.md itself is never written; its
# checksum is taken before and after, and a difference aborts.
#
# Parsing happens inside jq, so the file's text is only ever data. Entries are
# `### ` headings; their `**Label:** value` lines give the fields; everything
# else in the block is the description. Anything outside a `### ` block that is
# not a `#`/`##` heading or a `---` rule is reported by line, never dropped
# silently. Entries under a Completed or Done section, or whose status says so,
# go straight to the archive.

_tasks_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    return 1
  fi
}

# The key a shared store dedupes a TODO.md entry on: the entry's fingerprint
# composed with the project it came from. Every path that brings a TODO.md
# entry into a shared store — /todo migrate directly, or migrate-store copying
# a task that migrate once imported into a per-repository store — computes this
# same key, so the entry lands once whichever path runs first.
_tasks_todo_key() {
  printf '%s\n%s' "${1}" "${2}" | _tasks_sha256
}

# shellcheck disable=SC2016  # a jq program: $lines, $i and friends are jq variables
readonly TASKS_TODO_PARSER='
  def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
  def flush: if .cur != null then .entries += [.cur] | .cur = null else . end;
  def strip_blank_edges:
    (map(test("^\\s*$") | not) | index(true)) as $first
    | if $first == null then [] else .[$first:] | reverse
        | (map(test("^\\s*$") | not) | index(true)) as $last | .[$last:] | reverse end;
  # A fenced block is description text: a `# comment`, `---` or `### ` inside it
  # is not structure. A fence opens on 3+ backticks or tildes (backticks only
  # when no backtick follows on the line, so inline code is not a fence) and
  # closes only on the same character, at least as long, with nothing after.
  # If a fence never closes, the file is parsed again without fence tracking
  # and a note says so: one stray marker must not swallow every later entry.
  def fence_open:
    (capture("^ {0,3}(?<m>`{3,}|~{3,})(?<rest>.*)$") // null) as $c
    | if $c == null then null
      elif ($c.m | startswith("`")) and ($c.rest | test("`")) then null
      else {c: ($c.m[0:1]), n: ($c.m | length)} end;
  def fence_closes($f):
    test("^ {0,3}" + (if $f.c == "`" then "`" else "~" end) + "{" + ($f.n | tostring) + ",}\\s*$");
  def body_or_stray($l; $i; $f):
    if .cur != null then .cur.body += [$l] | .cur.fenced += [$f] else .stray += [{line: ($i + 1), section: .section}] end;
  def parse($lines; $plain):
    reduce range(0; $lines | length) as $i ({section: "", cur: null, entries: [], stray: [], fence: null, fence_line: null};
      ($lines[$i] | sub("\r$"; "")) as $l
      | .fence as $open
      | if $open != null then
          (if ($l | fence_closes($open)) then .fence = null else . end) | body_or_stray($l; $i; true)
        elif (($plain | index($i + 1)) == null) and ($l | fence_open) != null then
          .fence = ($l | fence_open) | .fence_line = ($i + 1) | body_or_stray($l; $i; true)
        elif ($l | test("^### ")) then flush | .cur = {title: ($l | sub("^### +"; "") | trim), line: ($i + 1), section: .section, body: [], fenced: []}
        elif ($l | test("^## ")) then flush | .section = ($l | sub("^## +"; "") | trim | ascii_downcase)
        elif ($l | test("^# ")) then flush
        elif ($l | test("^---+\\s*$")) then flush
        elif .cur != null then .cur.body += [$l] | .cur.fenced += [false]
        elif ($l | test("^\\s*$")) then .
        else .stray += [{line: ($i + 1), section: .section}]
        end)
    | flush;
  # An opener that never closes is read as plain text and the file parsed again,
  # so one stray marker neither swallows the entries after it nor changes how
  # the closed fences elsewhere in the file are read.
  def parse_all($lines; $plain):
    parse($lines; $plain) as $r
    | if $r.fence != null then parse_all($lines; $plain + [$r.fence_line]) else $r + {plain: $plain} end;
  split("\n") as $lines
  | parse_all($lines; []) as $r
  | $r + {fence_note: (if ($r.plain | length) > 0
      then "a code fence opened at line " + ($r.plain | map(tostring) | join(", ")) + " never closes; that line was read as plain text"
      else null end)}
  | .entries |= map(
      . as $e
      | ([$e.body, $e.fenced] | transpose
         | map({t: .[0], f: (if .[1] == null then true else .[1] end)})
         | map(.k = ((.t | capture("^\\*\\*(?<k>[A-Za-z ]+):\\*\\*") // {k: ""}) | .k | ascii_downcase | trim))
         | map(.field = ((.f | not) and (.k | IN("status", "priority", "category", "scope", "related"))))) as $lines
      | ($lines | map(select(.field)) | map({key: .k, value: (.t | capture("^\\*\\*[A-Za-z ]+:\\*\\*\\s*(?<v>.*)$") | .v | trim)}) | from_entries) as $f
      | ($lines | map(select(.field | not) | .t) | strip_blank_edges) as $desc
      | ($f.status // "" | ascii_downcase | trim) as $s
      | ($f.priority // "" | ascii_downcase | gsub("[^a-z]"; "")) as $p
      | {
          line: $e.line,
          title: $e.title,
          raw_status: $s,
          status: (if $s == "" then (if ($e.section | test("complete|done|archive")) then "done" else "proposed" end)
                   elif $s == "proposed" then "proposed"
                   elif $s == "not started" then "not_started"
                   elif $s == "needs discussion" then "needs_discussion"
                   elif $s == "in progress" then "in_progress"
                   elif ($s | test("^(done|completed?|archived)$")) then "done"
                   else $s end),
          priority: (if ($p | IN("emergency", "high", "medium", "low")) then $p else "unknown" end),
          category: ($f.category // ""),
          scope: ($f.scope // ""),
          related: ($f.related // ""),
          description: ($desc | join("\n")),
          norm: ([$e.title] + ($e.body | map(sub("\\s+$"; "")) | strip_blank_edges) | join("\n"))
        })
  | .entries |= map(select(.title != ""))
'

# Keys of TODO.md entries already in the store, open or archived, into
# TASKS_KNOWN_KEYS. A per-repository store keys an entry on its fingerprint. A
# shared store keys it on todo_key — the fingerprint composed with the project —
# because two projects' TODO.md files can hold the very same entry, and each
# project must still get its own copy.
TASKS_KNOWN_KEYS=""
_tasks_known_todo_keys() {
  local f k keyfield=".migrated_from.fingerprint"
  [ "$TASKS_MODE" != "global" ] || keyfield=".migrated_from.todo_key"
  TASKS_KNOWN_KEYS=""
  for f in "$TASKS_DIR"/items/*.json "$TASKS_DIR"/archive/*.json; do
    [ -f "$f" ] || continue
    k="$(jq -r "$keyfield // empty" "$f" 2>/dev/null)" || k=""
    [ -z "$k" ] || TASKS_KNOWN_KEYS="$TASKS_KNOWN_KEYS $k"
  done
}

# The key an entry with fingerprint <fp> is deduplicated on, in this mode.
_tasks_entry_key() {
  if [ "$TASKS_MODE" = "global" ]; then
    _tasks_todo_key "$TASKS_PROJECT" "${1}"
  else
    printf '%s\n' "${1}"
  fi
}

_tasks_op_migrate() {
  local count_only=0
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      # Read-only: how many entries an import would read. Nothing is created,
      # backed up or written — setup asks this before offering the migration.
      --count) count_only=1; shift ;;
      *) _tasks_die "$EXIT_REFUSED" "migrate: unknown option '${1}'" ;;
    esac
  done
  _tasks_resolve
  # In a shared store, the TODO.md of THIS project: the repository's own, not
  # the one at a parent workspace's root (CL-122). In a per-repository store,
  # the one beside the configuration, exactly as before.
  local todo="$WORKSPACE_ROOT/TODO.md"
  [ "$TASKS_MODE" != "global" ] || todo="$TASKS_PROJECT_ROOT/TODO.md"
  if [ "$count_only" -eq 1 ]; then
    if [ ! -f "$todo" ] || [ -L "$todo" ] || [ ! -r "$todo" ]; then
      jq -cn --arg todo "$todo" '{ok: true, todo: $todo, exists: false, entries: 0}'
      return 0
    fi
    local counted entry norm fp key total=0 new=0
    counted="$(jq -Rsc "$TASKS_TODO_PARSER" "$todo")" \
      || _tasks_die "$EXIT_REFUSED" "could not parse $todo"
    # The same keys the import skips on, so a re-run of setup is not offered
    # to move entries that are already in the store.
    _tasks_known_todo_keys
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      total=$((total + 1))
      norm="$(jq -r '.norm' <<< "$entry")"
      fp="$(printf '%s' "$norm" | _tasks_sha256)" || _tasks_die "$EXIT_SYSTEM" "could not fingerprint an entry"
      key="$(_tasks_entry_key "$fp")" || _tasks_die "$EXIT_SYSTEM" "could not key an entry"
      case " $TASKS_KNOWN_KEYS " in
        *" $key "*) : ;;
        *) new=$((new + 1)) ;;
      esac
    done < <(jq -c '.entries[]' <<< "$counted")
    jq -cn --arg todo "$todo" --argjson total "$total" --argjson new "$new" \
      '{ok: true, todo: $todo, exists: true, entries: $total, new: $new, already_imported: ($total - $new)}'
    return 0
  fi
  _tasks_require_writable
  { [ -f "$todo" ] && [ ! -L "$todo" ]; } || _tasks_die "$EXIT_REFUSED" "no TODO.md at $todo — nothing to migrate"
  [ -r "$todo" ] || _tasks_die "$EXIT_REFUSED" "cannot read $todo — nothing was backed up or imported"
  local before
  before="$(_tasks_sha256 < "$todo")" \
    || _tasks_die "$EXIT_REFUSED" "neither sha256sum nor shasum is available, so TODO.md cannot be proven unchanged — nothing was backed up or imported"
  local parsed
  parsed="$(jq -Rsc "$TASKS_TODO_PARSER" "$todo")" \
    || _tasks_die "$EXIT_REFUSED" "could not parse $todo — nothing was backed up or imported"

  _tasks_ensure_store
  mkdir -p "$TASKS_DIR/migration" || _tasks_die "$EXIT_SYSTEM" "could not create $TASKS_DIR/migration"
  # One backup per project in a shared store: several projects each bring a
  # TODO.md, and the first backup must not stop the second being taken.
  local bakdir="$TASKS_DIR/migration"
  if [ "$TASKS_MODE" = "global" ]; then
    bakdir="$TASKS_DIR/migration/$TASKS_PROJECT"
    [ ! -L "$bakdir" ] || _tasks_die "$EXIT_REFUSED" "$bakdir is a symlink; refusing to write through it"
    mkdir -p "$bakdir" || _tasks_die "$EXIT_SYSTEM" "could not create $bakdir"
  fi
  local bak="$bakdir/TODO.md.bak" backup_created=false
  if [ -L "$bak" ]; then
    _tasks_die "$EXIT_REFUSED" "backup path $bak is a symlink; refusing to write through it"
  elif [ -e "$bak" ]; then
    [ -f "$bak" ] || _tasks_die "$EXIT_REFUSED" "backup path $bak exists and is not a regular file"
  else
    cp -p -- "$todo" "$bak" || _tasks_die "$EXIT_SYSTEM" "FAILED at backup: could not copy TODO.md to $bak — nothing was imported"
    backup_created=true
  fi

  _tasks_known_todo_keys
  local known="$TASKS_KNOWN_KEYS" fp key

  local imported=0 archived=0 skipped=0 notes="[]" entry norm now doc target line status raw
  notes="$(jq -c 'if .fence_note then [{line: 0, note: .fence_note}] else [] end' <<< "$parsed")"
  now="$(_tasks_now)"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    norm="$(jq -r '.norm' <<< "$entry")"
    fp="$(printf '%s' "$norm" | _tasks_sha256)" || _tasks_die "$EXIT_SYSTEM" "FAILED at import: could not fingerprint an entry"
    key="$(_tasks_entry_key "$fp")" || _tasks_die "$EXIT_SYSTEM" "FAILED at import: could not key an entry"
    line="$(jq -r '.line' <<< "$entry")"
    case " $known " in
      *" $key "*) skipped=$((skipped + 1)); continue ;;
    esac
    status="$(jq -r '.status' <<< "$entry")"
    raw="$(jq -r '.raw_status' <<< "$entry")"
    if [ -z "$raw" ] && [ "$status" = "proposed" ]; then
      notes="$(jq -c --argjson l "$line" '. + [{line: $l, note: "no status; imported as proposed"}]' <<< "$notes")"
    elif [ "$status" != "done" ] && ! _tasks_word_in "$status" "$TASKS_PENDING_STATUSES in_progress"; then
      notes="$(jq -c --argjson l "$line" '. + [{line: $l, note: "unrecognised status kept as written; the task can only be closed with done"}]' <<< "$notes")"
    fi
    doc="$(jq -c --arg now "$now" --arg fp "$fp" --arg project "$TASKS_PROJECT" --arg key "$key" --arg mode "$TASKS_MODE" "$TASKS_TICKET_KEY_DEF"'
      {id: "", title, status, priority, category, scope, description, related,
       ticket_key: (.title | ticket_key),
       project: (if $project == "" then null else $project end),
       created_at: $now, updated_at: $now, promoted_to: null,
       migrated_from: ({source: "TODO.md", line: .line, fingerprint: $fp}
         + (if $mode == "global" then {todo_key: $key} else {} end))}' <<< "$entry")"
    if [ "$status" = "done" ]; then
      target="archive"
    else
      target="items"
    fi
    _tasks_publish_new "$target" "$doc" \
      || _tasks_die "$EXIT_SYSTEM" "FAILED at import: could not write the entry from TODO.md line $line ($imported imported before it; the backup is at $bak; re-running skips what was imported)"
    known="$known $key"
    if [ "$status" = "done" ]; then archived=$((archived + 1)); else imported=$((imported + 1)); fi
  done < <(jq -c '.entries[]' <<< "$parsed")

  local after
  after="$(_tasks_sha256 < "$todo")" || after=""
  if [ "$after" != "$before" ]; then
    _tasks_die "$EXIT_SYSTEM" "TODO.md changed while migrate ran — stopping; the backup at $bak holds the version that was read"
  fi
  local index_state="fresh"
  if ! _tasks_write_index; then
    _tasks_log "FAILED at index-write: entries were imported, but manifest.json could not be rewritten — run /rebuild-index tasks"
    index_state="stale"
  fi

  jq -cn --arg bak "$bak" --argjson created "$backup_created" --arg index "$index_state" \
    --argjson imported "$imported" --argjson archived "$archived" --argjson skipped "$skipped" \
    --argjson notes "$notes" --argjson unparsed "$(jq -c '.stray' <<< "$parsed")" \
    --arg todo "$todo" --arg project "$TASKS_PROJECT" \
    '{ok: true, imported: $imported, archived: $archived, skipped: $skipped, todo: $todo,
      backup: $bak, backup_created: $created, index: $index, notes: $notes, unparsed: $unparsed}
     + (if $project == "" then {} else {project: $project} end)'
  if [ "$index_state" = "stale" ]; then
    TASKS_REPORTED=1
    exit "$EXIT_INDEX_STALE"
  fi
}

# ---------------------------------------------------------------------------
# Migrate-store: copy a per-repository store into the shared one (CL-122)
# ---------------------------------------------------------------------------
#
# Global mode only. Every open and archived task of the source store is copied
# into the shared store, tagged with the current project, with its status,
# promotion link and timestamps kept. The source is never written: it stays
# exactly as it was, so a project can check the result before removing it.
#
# Re-runnable. Each copy records source_key — the original id and creation time,
# which do not depend on the project — so a store named from two places is
# imported once. A task that the per-repository store itself imported from
# TODO.md also records todo_key, the same key /todo migrate computes, so the
# same entry reaching the shared store both ways lands once, in either order.
_tasks_op_migrate_store() {
  local input="" from="" count_only=0
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --input) input="${2:-}"; shift 2 ;;
      --from) from="${2:-}"; shift 2 ;;
      # Read-only: what a move would copy, by the same rules — archive wins,
      # already-imported tasks skipped. Nothing is created or written.
      --count) count_only=1; shift ;;
      *) _tasks_die "$EXIT_REFUSED" "migrate-store: unknown option '${1}'" ;;
    esac
  done
  if [ -n "$input" ]; then
    # A path the user typed arrives as a file, never as a shell word.
    _tasks_check_input_dir "$input"
    from="$(jq -r '.' <<< "$(_tasks_field "$input" from)")"
    # A count is read-only, its input included: setup counts first and moves
    # later from the same input directory, and the move removes it.
    [ "$count_only" -eq 0 ] || TASKS_INPUT_DIR=""
  fi
  _tasks_resolve
  [ "$TASKS_MODE" = "global" ] \
    || _tasks_die "$EXIT_REFUSED" "migrate-store copies a per-repository store into the shared one, and this configuration is not in global mode"
  [ "$count_only" -eq 1 ] || _tasks_require_writable

  local ws src
  ws="$(cd "$WORKSPACE_ROOT" 2>/dev/null && pwd -P)" || _tasks_die "$EXIT_SYSTEM" "cannot read $WORKSPACE_ROOT"
  if [ -z "$from" ]; then
    if [ "$TASKS_PROJECT_OWNED" -ne 1 ]; then
      # A store beside a parent configuration belongs to every repository under
      # it. Importing it here would tag all of it with this one repository.
      jq -cn --arg store "$WORKSPACE_ROOT/.claude/tasks" --arg project "$TASKS_PROJECT" --arg ws "$WORKSPACE_ROOT" \
        '{ok: true, source: null, project: $project, copied: 0, archived: 0, skipped: 0,
          note: ("the per-repository store at " + $store + " belongs to the whole workspace, not to " + $project + " — migrate it from " + $ws + ", or name it explicitly to claim its tasks for this project")}'
      _tasks_remove_input_dir
      return 0
    fi
    from="$TASKS_PROJECT_ROOT/.claude/tasks"
    # Missing, or present with nothing in it, are the same answer here: setup
    # creates an empty .claude/tasks for every project before switching it to
    # the shared list, so refusing the empty one would fail every fresh
    # install. A store the user NAMES is still refused when it holds nothing:
    # that is a wrong path, not an empty default.
    if [ ! -e "$from" ] || { [ -d "$from" ] && [ ! -L "$from" ] \
         && [ ! -e "$from/items" ] && [ ! -e "$from/archive" ]; }; then
      jq -cn --arg from "$from" --arg project "$TASKS_PROJECT" \
        '{ok: true, source: null, project: $project, copied: 0, archived: 0, skipped: 0, note: ("no per-repository store with tasks at " + $from)}'
      _tasks_remove_input_dir
      return 0
    fi
  fi
  case "$from" in
    /*) : ;;
    *) from="$PWD/$from" ;;
  esac
  [ ! -L "$from" ] || _tasks_die "$EXIT_REFUSED" "migrate-store: $from is a symlink; name the store itself"
  [ -d "$from" ] || _tasks_die "$EXIT_REFUSED" "migrate-store: no directory at $from"
  src="$(cd "$from" && pwd -P)" || _tasks_die "$EXIT_SYSTEM" "migrate-store: cannot read $from"
  case "$src/" in
    "$ws"/*) : ;;
    *) _tasks_die "$EXIT_REFUSED" "migrate-store: $src is outside this workspace ($ws) — only a store of this project's own can be claimed for it" ;;
  esac
  [ ! "$src" -ef "$TASKS_DIR" ] || _tasks_die "$EXIT_REFUSED" "migrate-store: $src is the shared store itself"
  [ ! -e "$src/store.json" ] || _tasks_die "$EXIT_REFUSED" "migrate-store: $src is a shared store, not a per-repository one"
  { [ -d "$src/items" ] || [ -d "$src/archive" ]; } \
    || _tasks_die "$EXIT_REFUSED" "migrate-store: $src is not a task store (no items/ or archive/)"
  local d
  for d in "$src/items" "$src/archive"; do
    [ ! -L "$d" ] || _tasks_die "$EXIT_REFUSED" "migrate-store: $d is a symlink"
  done

  [ "$count_only" -eq 1 ] || _tasks_ensure_store
  # Keys already in the shared store.
  local known_src="" known_todo="" f k
  for f in "$TASKS_DIR"/items/*.json "$TASKS_DIR"/archive/*.json; do
    [ -f "$f" ] || continue
    k="$(jq -r '.migrated_from.source_key // empty' "$f" 2>/dev/null)" || k=""
    [ -z "$k" ] || known_src="$known_src $k"
    k="$(jq -r '.migrated_from.todo_key // empty' "$f" 2>/dev/null)" || k=""
    [ -z "$k" ] || known_todo="$known_todo $k"
  done

  local copied=0 archived=0 skipped=0 ignored=0 id sub doc skey tkey fp prc sub_from
  local now
  now="$(_tasks_now)"
  for sub_from in archive items; do
    for f in "$src/$sub_from"/*.json; do
      if [ ! -f "$f" ] || [ -L "$f" ]; then
        continue
      fi
      id="${f##*/}"
      id="${id%.json}"
      _tasks_valid_id "$id" || { ignored=$((ignored + 1)); continue; }
      # Archive wins, as everywhere else: a task in both is done.
      if [ "$sub_from" = "items" ] && [ -f "$src/archive/$id.json" ]; then
        continue
      fi
      if ! jq -se --arg id "$id" 'length == 1 and (.[0] | type == "object" and .id == $id)' "$f" >/dev/null 2>&1; then
        _tasks_log "migrate-store: ignoring $f: not a valid task file"
        ignored=$((ignored + 1))
        continue
      fi
      skey="$(printf '%s\n%s' "$id" "$(jq -r '.created_at // ""' "$f")" | _tasks_sha256)" \
        || _tasks_die "$EXIT_SYSTEM" "migrate-store: could not key task $id"
      tkey=""
      fp="$(jq -r 'if (.migrated_from.source // "") == "TODO.md" then (.migrated_from.fingerprint // "") else "" end' "$f")" || fp=""
      if [ -n "$fp" ]; then
        tkey="$(_tasks_todo_key "$TASKS_PROJECT" "$fp")" || _tasks_die "$EXIT_SYSTEM" "migrate-store: could not key task $id"
      fi
      case " $known_src " in
        *" $skey "*) skipped=$((skipped + 1)); continue ;;
      esac
      if [ -n "$tkey" ]; then
        case " $known_todo " in
          *" $tkey "*) skipped=$((skipped + 1)); continue ;;
        esac
      fi
      if [ "$count_only" -eq 1 ]; then
        if [ "$sub_from" = "archive" ]; then archived=$((archived + 1)); else copied=$((copied + 1)); fi
        continue
      fi
      doc="$(jq -c --arg project "$TASKS_PROJECT" --arg id "$id" --arg skey "$skey" --arg tkey "$tkey" --arg fp "$fp" --arg now "$now" '
        .project = $project
        | .migrated_from = ({source: "store", original_id: $id, source_key: $skey, migrated_at: $now}
            + (if $fp != "" then {fingerprint: $fp} else {} end)
            + (if $tkey != "" then {todo_key: $tkey} else {} end))' "$f")" \
        || _tasks_die "$EXIT_SYSTEM" "migrate-store: could not read task $id"
      sub="items"
      [ "$sub_from" = "archive" ] && sub="archive"
      prc=0
      _tasks_publish_as "$sub" "$id" "$doc" || prc=$?
      if [ "$prc" -eq 3 ]; then
        prc=0
        _tasks_publish_new "$sub" "$doc" || prc=$?
      fi
      case "$prc" in
        0) : ;;
        2) _tasks_die "$EXIT_SYSTEM" "FAILED at import: this filesystem cannot create a task file exclusively — $copied copied before it; re-running skips what was copied" ;;
        *) _tasks_die "$EXIT_SYSTEM" "FAILED at import: could not copy task $id — $copied copied before it; re-running skips what was copied" ;;
      esac
      known_src="$known_src $skey"
      [ -z "$tkey" ] || known_todo="$known_todo $tkey"
      if [ "$sub" = "archive" ]; then archived=$((archived + 1)); else copied=$((copied + 1)); fi
    done
  done
  _tasks_remove_input_dir
  if [ "$count_only" -eq 1 ]; then
    jq -cn --arg src "$src" --arg project "$TASKS_PROJECT" \
      --argjson copied "$copied" --argjson archived "$archived" --argjson skipped "$skipped" --argjson ignored "$ignored" \
      '{ok: true, count_only: true, source: $src, project: $project, copied: $copied, archived: $archived, skipped: $skipped, ignored: $ignored}'
    return 0
  fi

  local index_state="fresh"
  if ! _tasks_write_index; then
    _tasks_log "FAILED at index-write: tasks were copied, but manifest.json could not be rewritten — run /rebuild-index tasks"
    index_state="stale"
  fi
  jq -cn --arg src "$src" --arg project "$TASKS_PROJECT" --arg index "$index_state" \
    --argjson copied "$copied" --argjson archived "$archived" --argjson skipped "$skipped" --argjson ignored "$ignored" \
    '{ok: true, source: $src, project: $project, copied: $copied, archived: $archived, skipped: $skipped,
      ignored: $ignored, index: $index, note: "the source store was not changed"}'
  if [ "$index_state" = "stale" ]; then
    TASKS_REPORTED=1
    exit "$EXIT_INDEX_STALE"
  fi
}

# Set up the shared store (CL-122), for /configuration-init. The only op that
# may create a missing global store; every gate still runs, and it runs them
# before a directory is made where it can (the repository check) and after
# where it cannot (ownership, permissions). Writes the store.json marker.
_tasks_op_init_store() {
  [ "$#" -eq 0 ] || _tasks_die "$EXIT_REFUSED" "init-store takes no options"
  TASKS_INIT=1
  _tasks_resolve
  [ "$TASKS_MODE" = "global" ] \
    || _tasks_die "$EXIT_REFUSED" "init-store sets up a shared task store, and storage.artifacts.tasks does not say mode: global"
  _tasks_require_writable
  _tasks_ensure_store
  local in_repo=false named=false
  [ -z "$(env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --show-toplevel 2>/dev/null)" ] || in_repo=true
  [ -z "$(yq -r 'select(document_index == 0) | .project.name // ""' "$CONFIG" 2>/dev/null)" ] || named=true
  # in_repository and project_named let setup show the name the store will use
  # and offer to change it — the name itself is decided here, never by setup.
  jq -cn --arg dir "$TASKS_DIR" --arg project "$TASKS_PROJECT" --argjson created "$TASKS_STORE_CREATED" \
    --argjson in_repo "$in_repo" --argjson named "$named" --argjson owned "$TASKS_PROJECT_OWNED" \
    '{ok: true, dir: $dir, project: $project, created: $created,
      in_repository: $in_repo, project_named: $named, config_owned: ($owned == 1)}'
}

_tasks_usage() {
  _tasks_die "$EXIT_REFUSED" "usage: tasks.sh --op <resolve|input-dir|add|list|show|set-status|done|rebuild|validate-ref|migrate|migrate-store|init-store|parse-handoff> [options]"
}

main() {
  { [ "${1:-}" = "--op" ] && [ -n "${2:-}" ]; } || _tasks_usage
  local op="${2}"
  shift 2
  _tasks_preflight
  case "$op" in
    resolve)      _tasks_op_resolve "$@" ;;
    input-dir)    _tasks_op_input_dir "$@" ;;
    add)          _tasks_op_add "$@" ;;
    list)         _tasks_op_list "$@" ;;
    show)         _tasks_op_show "$@" ;;
    set-status)   _tasks_op_set_status "$@" ;;
    done)         _tasks_op_done "$@" ;;
    rebuild)      _tasks_op_rebuild "$@" ;;
    validate-ref) _tasks_op_validate_ref "$@" ;;
    migrate)      _tasks_op_migrate "$@" ;;
    migrate-store) _tasks_op_migrate_store "$@" ;;
    init-store)   _tasks_op_init_store "$@" ;;
    parse-handoff) _tasks_op_parse_handoff "$@" ;;
    *) _tasks_die "$EXIT_REFUSED" "unknown op '$op'" ;;
  esac
}

main "$@"
exit "$EXIT_OK"
