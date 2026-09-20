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

  _tasks_gate_overlap "$path"
  TASKS_DIR="$path"
  _tasks_refuse_symlinked_store
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
    + {items: [\$sorted[] | {id, title, status, priority, category, created_at, updated_at, promoted_to, path: (\"items/\" + .id + \".json\")}]}
    | .total_items = (.items | length)
    | {version, last_updated, artifact_type, total_items, items}" <<< "$open")" || return 1
  _tasks_write_json "$TASKS_DIR/manifest.json" "$index"
}

# The ordered list a user numbers from. `open` is every open task (/todo list);
# `pending` is what /todo-work offers. A number always names a position in the
# list the caller states, so the same N never means two different tasks.
_tasks_list_json() {
  local scope="${1}" open
  open="$(_tasks_read_open)"
  jq -c --arg scope "$scope" --arg pending "$TASKS_PENDING_STATUSES" "
    ($TASKS_SORT)
    | map(select(\$scope == \"open\" or (.status as \$s | (\$pending | split(\" \")) | index(\$s))))
    | to_entries | map(.value + {n: (.key + 1)})" <<< "$open"
}

# Resolve --id or --n (against a scope) to one open task id, or refuse.
# The answer is left in TASKS_PICKED rather than printed: a refusal raised inside
# a command substitution exits only the subshell, and the parent would then
# report it as an unexpected failure instead of the refusal it is.
TASKS_PICKED=""
_tasks_pick() {
  local id="${1}" n="${2}" scope="${3}" list
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
  list="$(_tasks_list_json "$scope")"
  id="$(jq -r --argjson n "$n" '.[] | select(.n == $n) | .id' <<< "$list")"
  [ -n "$id" ] || _tasks_die "$EXIT_REFUSED" "no task #$n in the $scope list ($(jq length <<< "$list") tasks)"
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
  jq -cn --arg dir "$TASKS_DIR" '{ok: true, dir: $dir}'
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
# tries rather than spun forever. add and migrate both call this; a second
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
  local id now
  now="$(_tasks_now)"
  id="$(_tasks_new_id)" || _tasks_die "$EXIT_SYSTEM" "add: could not generate an unused task id"
  _tasks_require_id "$id"

  # ticket_key is derived here, by the same rule migrate uses — the first
  # ABC-123 shaped key in the title — so no caller has its own version of it.
  local doc
  doc="$(jq -cn \
    --arg id "$id" --arg now "$now" --arg priority "$p" --arg status "$s" \
    --rawfile title "$input/title" --rawfile description "$input/description" \
    --rawfile category "$input/category" --rawfile scope "$input/scope" --rawfile related "$input/related" \
    "$TASKS_TICKET_KEY_DEF"'
    def one: sub("\n$"; "");
    ($title | one) as $t
    | {id: $id, title: $t, status: $status, priority: $priority,
       category: ($category | one), scope: ($scope | one), description: ($description | one), related: ($related | one),
       ticket_key: ($t | ticket_key),
       created_at: $now, updated_at: $now, promoted_to: null, migrated_from: null}')" \
    || _tasks_die "$EXIT_SYSTEM" "add: could not assemble the task"
  _tasks_write_json "$TASKS_DIR/items/$id.json" "$doc" \
    || _tasks_die "$EXIT_SYSTEM" "FAILED at item-write: could not write items/$id.json — nothing was added"
  _tasks_remove_input_dir
  if ! _tasks_write_index; then
    _tasks_log "FAILED at index-write: task $id was added, but manifest.json could not be rewritten — run /rebuild-index tasks"
    jq -cn --arg id "$id" '{ok: true, id: $id, index: "stale"}'
    TASKS_REPORTED=1
    exit "$EXIT_INDEX_STALE"
  fi
  jq -cn --arg id "$id" '{ok: true, id: $id}'
}

_tasks_op_list() {
  local scope="open"
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --scope) scope="${2:-}"; shift 2 ;;
      *) _tasks_die "$EXIT_REFUSED" "list: unknown option '${1}'" ;;
    esac
  done
  case "$scope" in open|pending) : ;; *) _tasks_die "$EXIT_REFUSED" "list: --scope must be open or pending" ;; esac
  _tasks_resolve
  local list migrate=false archived=0 f
  list="$(_tasks_list_json "$scope")"
  for f in "$TASKS_DIR"/archive/*.json; do
    [ -f "$f" ] && { archived=1; break; }
  done
  # The hint for AC-3.7: a TODO.md sits at the project root and the store holds
  # nothing at all, open or archived. Nothing is imported here.
  if [ "$(_tasks_list_json open | jq length)" -eq 0 ] && [ "$archived" -eq 0 ] \
     && [ -f "$WORKSPACE_ROOT/TODO.md" ]; then
    migrate=true
  fi
  jq -c --arg scope "$scope" --argjson migrate "$migrate" \
    '{ok: true, scope: $scope, total: length, migrate_available: $migrate,
      tasks: [.[] | {n, id, title, status, priority, category, created_at, promoted_to}]}' <<< "$list"
}

_tasks_op_show() {
  local id="" n="" scope="open" handoff=0
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --id) id="${2:-}"; shift 2 ;;
      --n) n="${2:-}"; shift 2 ;;
      --scope) scope="${2:-}"; shift 2 ;;
      --for-handoff) handoff=1; shift ;;
      *) _tasks_die "$EXIT_REFUSED" "show: unknown option '${1}'" ;;
    esac
  done
  case "$scope" in open|pending) : ;; *) _tasks_die "$EXIT_REFUSED" "show: --scope must be open or pending" ;; esac
  _tasks_resolve
  _tasks_pick "$id" "$n" "$scope"
  id="$TASKS_PICKED"
  local doc
  doc="$(jq -c . "$TASKS_DIR/items/$id.json")" || _tasks_die "$EXIT_SYSTEM" "could not read items/$id.json"
  if [ "$handoff" -eq 0 ]; then
    jq -c --arg dir "$TASKS_DIR" '{ok: true, store: $dir, task: .}' <<< "$doc"
    return 0
  fi
  # Task text goes to /create-requirements wrapped in untrusted-content markers.
  # Text carrying its own closing marker would end that fence early, so the
  # handoff stops on a forged marker, and on a scan that could not run.
  _tasks_source_shared forged-marker-scan.sh
  # The text is read before it is scanned. In a pipeline under pipefail a
  # failed jq is masked by the scanner's own "none found" (1), so a scan that
  # saw no bytes reported clean. A read that fails is a scan that failed.
  local scan_rc=0 verdict text
  if text="$(jq -r '.title + "\n" + .description' <<< "$doc")"; then
    nexus_scan_forged_markers <<< "$text" >/dev/null || scan_rc=$?
    case "$scan_rc" in
      1) verdict="clean" ;;
      0) verdict="found" ;;
      *) verdict="failed" ;;
    esac
  else
    verdict="failed"
  fi
  jq -c --arg dir "$TASKS_DIR" --arg verdict "$verdict" '{ok: ($verdict == "clean"), store: $dir, marker_scan: $verdict, task: .}' <<< "$doc"
  case "$verdict" in
    clean) return 0 ;;
    found) _tasks_die "$EXIT_REFUSED" "task $id contains a content-boundary marker — refusing to hand it off" ;;
    *) _tasks_die "$EXIT_SYSTEM" "the content-boundary marker scan failed on task $id — refusing to hand it off" ;;
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
  local id="" n="" input=""
  while [ "$#" -gt 0 ]; do
    case "${1}" in
      --id) id="${2:-}"; shift 2 ;;
      --n) n="${2:-}"; shift 2 ;;
      --input) input="${2:-}"; shift 2 ;;
      *) _tasks_die "$EXIT_REFUSED" "done: unknown option '${1}'" ;;
    esac
  done
  if [ -n "$input" ]; then
    # A reference the user typed arrives as a file, never as a shell word.
    _tasks_check_input_dir "$input"
    local ref
    ref="$(jq -r '.' <<< "$(_tasks_field "$input" ref)")"
    ref="${ref//[[:space:]]/}"
    if [[ "$ref" =~ ^[0-9]+$ ]]; then n="$ref"; else id="$ref"; fi
  fi
  [ -n "$id" ] || [ -n "$n" ] || _tasks_die "$EXIT_REFUSED" "done: give --id, --n or --input"
  _tasks_resolve
  _tasks_pick "$id" "$n" open
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

_tasks_op_migrate() {
  [ "$#" -eq 0 ] || _tasks_die "$EXIT_REFUSED" "migrate takes no options"
  _tasks_resolve
  local todo="$WORKSPACE_ROOT/TODO.md"
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
  local bak="$TASKS_DIR/migration/TODO.md.bak" backup_created=false
  if [ -L "$bak" ]; then
    _tasks_die "$EXIT_REFUSED" "backup path $bak is a symlink; refusing to write through it"
  elif [ -e "$bak" ]; then
    [ -f "$bak" ] || _tasks_die "$EXIT_REFUSED" "backup path $bak exists and is not a regular file"
  else
    cp -p -- "$todo" "$bak" || _tasks_die "$EXIT_SYSTEM" "FAILED at backup: could not copy TODO.md to $bak — nothing was imported"
    backup_created=true
  fi

  # Fingerprints already in the store, open or archived.
  local known="" f fp
  for f in "$TASKS_DIR"/items/*.json "$TASKS_DIR"/archive/*.json; do
    [ -f "$f" ] || continue
    fp="$(jq -r '.migrated_from.fingerprint // empty' "$f" 2>/dev/null)" || fp=""
    [ -z "$fp" ] || known="$known $fp"
  done

  local imported=0 archived=0 skipped=0 notes="[]" entry norm id now doc target line status raw
  notes="$(jq -c 'if .fence_note then [{line: 0, note: .fence_note}] else [] end' <<< "$parsed")"
  now="$(_tasks_now)"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    norm="$(jq -r '.norm' <<< "$entry")"
    fp="$(printf '%s' "$norm" | _tasks_sha256)" || _tasks_die "$EXIT_SYSTEM" "FAILED at import: could not fingerprint an entry"
    line="$(jq -r '.line' <<< "$entry")"
    case " $known " in
      *" $fp "*) skipped=$((skipped + 1)); continue ;;
    esac
    status="$(jq -r '.status' <<< "$entry")"
    raw="$(jq -r '.raw_status' <<< "$entry")"
    if [ -z "$raw" ] && [ "$status" = "proposed" ]; then
      notes="$(jq -c --argjson l "$line" '. + [{line: $l, note: "no status; imported as proposed"}]' <<< "$notes")"
    elif [ "$status" != "done" ] && ! _tasks_word_in "$status" "$TASKS_PENDING_STATUSES in_progress"; then
      notes="$(jq -c --argjson l "$line" '. + [{line: $l, note: "unrecognised status kept as written; the task can only be closed with done"}]' <<< "$notes")"
    fi
    id="$(_tasks_new_id)" || _tasks_die "$EXIT_SYSTEM" "FAILED at import: could not generate an unused task id"
    _tasks_require_id "$id"
    doc="$(jq -c --arg id "$id" --arg now "$now" --arg fp "$fp" "$TASKS_TICKET_KEY_DEF"'
      {id: $id, title, status, priority, category, scope, description, related,
       ticket_key: (.title | ticket_key),
       created_at: $now, updated_at: $now, promoted_to: null,
       migrated_from: {source: "TODO.md", line: .line, fingerprint: $fp}}' <<< "$entry")"
    if [ "$status" = "done" ]; then
      target="$TASKS_DIR/archive/$id.json"
    else
      target="$TASKS_DIR/items/$id.json"
    fi
    _tasks_write_json "$target" "$doc" \
      || _tasks_die "$EXIT_SYSTEM" "FAILED at import: could not write the entry from TODO.md line $line ($imported imported before it; the backup is at $bak; re-running skips what was imported)"
    known="$known $fp"
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
    '{ok: true, imported: $imported, archived: $archived, skipped: $skipped,
      backup: $bak, backup_created: $created, index: $index, notes: $notes, unparsed: $unparsed}'
  if [ "$index_state" = "stale" ]; then
    TASKS_REPORTED=1
    exit "$EXIT_INDEX_STALE"
  fi
}

_tasks_usage() {
  _tasks_die "$EXIT_REFUSED" "usage: tasks.sh --op <resolve|input-dir|add|list|show|set-status|done|rebuild|validate-ref|migrate|parse-handoff> [options]"
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
    parse-handoff) _tasks_op_parse_handoff "$@" ;;
    *) _tasks_die "$EXIT_REFUSED" "unknown op '$op'" ;;
  esac
}

main "$@"
exit "$EXIT_OK"
