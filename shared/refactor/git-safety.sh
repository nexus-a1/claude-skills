#!/usr/bin/env bash
# plugin/shared/refactor/git-safety.sh
#
# Git safety steps for /refactor and the refactorer agent (CL-159): the
# consented checkpoint, the clean-tree check, per-category staging and
# rollback, and the gate diff. Sourced, never executed. Every function works on
# the repository of the CURRENT directory, so the caller runs a guarded `cd`
# first; nothing here carries state between calls, because each fence in a
# skill is its own shell.
#
#   if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/refactor/git-safety.sh" ]; then
#     source "${CLAUDE_PLUGIN_ROOT}/shared/refactor/git-safety.sh"
#   elif [ -f "$HOME/.claude/shared/refactor/git-safety.sh" ]; then
#     source "$HOME/.claude/shared/refactor/git-safety.sh"
#   else
#     echo "ERROR: git-safety.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
#     exit 1
#   fi
#
# No `set -euo pipefail`: it would change the caller's shell. Every function
# returns non-zero on any failure and says why on stderr.
#
# Pathspecs are always repository-root anchored (`:/` plus `:(top,exclude)`),
# so a run from a subdirectory checks and diffs the whole repository.

# Every git command that takes a pathspec goes through this (diff, status,
# ls-files, ls-tree, add, rm, restore, check-ignore). The user's settings
# must not change what those reads see: diff.relative narrowed a diff to the
# current directory, status.showUntrackedFiles=no hid new files from the
# consent list, and GIT_LITERAL_PATHSPECS made `:/` and the exclusions literal
# names, so every check read clean. Empty values are "off" to git, and the
# assignments last for this one command, so the caller's shell keeps its own.
_refactor_git() {
  GIT_LITERAL_PATHSPECS='' GIT_GLOB_PATHSPECS='' GIT_NOGLOB_PATHSPECS='' GIT_ICASE_PATHSPECS='' \
    git -c diff.relative=false -c status.showUntrackedFiles=all "$@"
}

_REFACTOR_LIB_DIR="${BASH_SOURCE[0]%/*}"

# A git object id, SHA-1 or SHA-256. Anything else never reaches a git command.
_refactor_valid_oid() {
  [[ "${1-}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]
}

# Physical path of $1, which need not exist: resolve the nearest existing
# ancestor with `cd -P`/`pwd -P` (portable, no GNU `realpath -m`) and append the
# rest. Prints nothing and fails when no ancestor resolves.
_refactor_phys() {
  local p="$1" rest="" anc phys
  [[ "$p" == /* ]] || p="$PWD/$p"
  anc="$p"
  while [[ ! -d "$anc" ]]; do
    rest="/${anc##*/}$rest"
    anc="${anc%/*}"
    [[ -n "$anc" ]] || anc="/"
  done
  [[ -n "$anc" ]] || return 1
  phys=$(cd -P -- "$anc" 2>/dev/null && pwd -P) || return 1
  [[ "$phys" == "/" ]] && phys=""
  printf '%s%s\n' "$phys" "$rest"
}

# The plugin-owned paths, resolved by resolve-config.sh in a SUBSHELL: it reads
# the current directory when sourced (the caller may have changed directory
# since), and sourcing it here would overwrite the caller's CONFIG,
# WORKSPACE_ROOT and friends on every call. Prints `<kind> <absolute path>`
# lines; kinds: sessions, work, tasks, messages, state, backups.
_refactor_resolve_paths() {
  local rc_lib="$_REFACTOR_LIB_DIR/../resolve-config.sh"
  [[ -f "$rc_lib" ]] || { echo "git-safety: resolve-config.sh not found at $rc_lib" >&2; return 1; }
  (
    # shellcheck source=SCRIPTDIR/../resolve-config.sh
    source "$rc_lib" >/dev/null || exit 1
    root="${WORKSPACE_ROOT:-$PWD}"
    abs() { case "$1" in /*) printf '%s\n' "$1" ;; ?*) printf '%s/%s\n' "$root" "$1" ;; esac; }
    p=$(resolve_artifact refactoring work/refactoring-sessions) || exit 1; printf 'sessions %s\n' "$(abs "$p")"
    p=$(resolve_artifact work work) || exit 1;                          printf 'work %s\n' "$(abs "$p")"
    # tasks and messages may legitimately not resolve (for example a refused
    # git-typed location); that is only an error when the project configured them.
    for a in tasks messages; do
      if p=$(resolve_artifact "$a" "$a" 2>/dev/null) && [ -n "$p" ]; then
        printf '%s %s\n' "$a" "$(abs "$p")"
      elif [ -n "${CONFIG:-}" ] && [ -n "$(yq -r ".storage.artifacts.$a // \"\"" "$CONFIG" 2>/dev/null)" ]; then
        echo "git-safety: storage.artifacts.$a is configured but did not resolve; refusing (fail closed)" >&2
        exit 1
      fi
    done
    printf 'state %s\n' "$root/.claude/session-state"
    [ -n "${CONFIG:-}" ] && printf 'backups %s\n' "${CONFIG%/*}"
    exit 0
  ) || { echo "git-safety: resolving the plugin's paths failed" >&2; return 1; }
}

# Fill _REFACTOR_EX with the exclusion pathspecs for the plugin's own files that
# lie inside this repository (and _REFACTOR_EX_REL with their paths relative to
# the toplevel). The plugin-owned paths
# are the refactoring session records (the same resolve_artifact call refactorer
# makes), the work, tasks and messages artifact directories, the hooks'
# .claude/session-state, and the configuration backups that
# plugin/shared/config/artifacts.sh writes as `<file>.bak-<timestamp>`.
# _REFACTOR_EX_REL holds the bare relative paths (for the protected-path check).
_refactor_load_exclude() {
  _REFACTOR_EX=()
  _REFACTOR_EX_REL=()
  local top top_phys resolved kind p phys rel
  top=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "git-safety: not inside a git work tree: $PWD" >&2; return 1; }
  top_phys=$(_refactor_phys "$top") || { echo "git-safety: cannot resolve $top" >&2; return 1; }
  resolved=$(_refactor_resolve_paths) || return 1

  while IFS=' ' read -r kind p; do
    [[ -n "$p" ]] || continue
    phys=$(_refactor_phys "$p") || {
      echo "git-safety: cannot resolve plugin path $p; refusing (fail closed)" >&2; return 1; }
    if [[ "$phys" == "$top_phys" ]]; then
      echo "git-safety: plugin path $p is the repository root; refusing" >&2; return 1
    fi
    case "$phys" in
      "$top_phys"/*) rel="${phys#"$top_phys"/}" ;;
      *) continue ;;   # outside this repository: git would refuse the pathspec
    esac
    case "$kind" in
      backups)  _REFACTOR_EX+=(":(top,exclude,glob)$rel/configuration.yml.bak-*") ;;
      sessions) _REFACTOR_EX+=(":(top,exclude,literal)$rel"); _REFACTOR_EX_REL+=("$rel") ;;
      *)        _REFACTOR_EX+=(":(top,exclude,literal)$rel"); _REFACTOR_EX_REL+=("$rel") ;;
    esac
  done <<< "$resolved"
  return 0
}

# Print the exclusion pathspecs, one per line. The skill prints them next to
# the gate diff, so a reviewer can see what the diff leaves out.
refactor_exclude() {
  _refactor_load_exclude || return 1
  local e
  for e in ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"}; do printf '%s\n' "$e"; done
}

# Print every change outside the exclusions (tracked and untracked). Empty
# output means clean. Fails, rather than printing nothing, when git fails.
refactor_dirty() {
  _refactor_load_exclude || return 1
  _refactor_git status --porcelain -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"}
}

# Checkpoint step 1: stop before anything is staged.
refactor_precheck() {
  _refactor_load_exclude || return 1
  local gd f flags
  git rev-parse --verify -q HEAD >/dev/null || {
    echo "precheck: HEAD has no commit yet (unborn branch); no start commit can be recorded" >&2; return 1; }
  gd=$(git rev-parse --git-dir) || return 1
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [[ -e "$gd/$f" ]] && { echo "precheck: a merge, rebase, cherry-pick or revert is in progress ($f)" >&2; return 1; }
  done
  [[ -z "$(_refactor_git ls-files -u)" ]] || { echo "precheck: the index has unmerged entries" >&2; return 1; }
  # `S` is skip-worktree, a lowercase tag is assume-unchanged. read-tree clears
  # both, which would surface a developer's hidden local edit.
  flags=$(_refactor_git ls-files -v) || { echo "precheck: git ls-files failed" >&2; return 1; }
  flags=$(grep -E '^([a-z]|S) ' <<< "$flags" | cut -c3- | head -n 5)
  [[ -z "$flags" ]] || {
    printf 'precheck: skip-worktree or assume-unchanged entries present (sparse checkout or update-index flags):\n%s\n' "$flags" >&2
    return 1; }
  # A staged file under ANY exclusion (session records, work, tasks, messages,
  # state, config backups) would reach the checkpoint commit without being in
  # the consent list, and makes the index differ from HEAD's tree.
  local all kept
  all=$(_refactor_git diff --cached --no-renames --name-only -- :/) \
    || { echo "precheck: git diff --cached failed" >&2; return 1; }
  kept=$(_refactor_git diff --cached --no-renames --name-only -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"}) \
    || { echo "precheck: git diff --cached failed" >&2; return 1; }
  if [[ "$all" != "$kept" ]]; then
    echo "precheck: files under plugin-owned directories are staged; they would reach the checkpoint commit unlisted. Unstage them first (git restore --staged <path>)" >&2
    return 1
  fi
  # An index backup left behind by a run that stopped between snapshot and
  # verify: never deleted automatically (it may be the only copy of that
  # staging), only reported so the developer can restore or remove it.
  local idx old
  idx=$(_refactor_index_path) || return 1
  for old in "$idx".nexus-refactor.??????; do
    [[ -f "$old" && ! -L "$old" ]] && echo "precheck: warning: an index backup from an earlier run is still here: $old" >&2
  done
  return 0
}

# One hash over the working-tree diff against the index, the untracked file
# list and the stash list. Used to tell "nothing changed" from "a hook changed
# something" after a refused commit.
refactor_fingerprint() {
  local d u st
  _refactor_load_exclude || return 1
  # Each read checked on its own: in a pipeline a failed git diff would still
  # hash to something, and "nothing changed" would rest on data never read.
  d=$(_refactor_git diff --binary --no-ext-diff --no-textconv --no-color -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"}) \
    || { echo "fingerprint: git diff failed" >&2; return 1; }
  u=$(_refactor_git ls-files --others --exclude-standard -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"}) \
    || { echo "fingerprint: git ls-files failed" >&2; return 1; }
  st=$(git stash list) || { echo "fingerprint: git stash list failed" >&2; return 1; }
  printf '%s\n%s\n%s\n' "$d" "$u" "$st" | git hash-object --stdin
}

# The index file's absolute path.
_refactor_index_path() {
  local idx dir
  idx=$(git rev-parse --git-path index) || return 1
  dir=$(cd -P -- "${idx%/*}" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "${idx##*/}"
}

# Checkpoint step 2. Prints PRE_HEAD=, INDEX_BACKUP= and FINGERPRINT= lines.
# The backup is a byte copy of the index file, next to it inside the git dir,
# so skip-worktree bits and intent-to-add entries survive a restore.
refactor_snapshot() {
  local head idx bak fp
  head=$(git rev-parse --verify -q HEAD) || { echo "snapshot: no HEAD" >&2; return 1; }
  idx=$(_refactor_index_path) || { echo "snapshot: cannot locate the index" >&2; return 1; }
  [[ -f "$idx" ]] || { echo "snapshot: no index file at $idx" >&2; return 1; }
  bak=$(mktemp "$idx.nexus-refactor.XXXXXX") || { echo "snapshot: cannot create index backup" >&2; return 1; }
  cp -p -- "$idx" "$bak" || { rm -f -- "$bak"; echo "snapshot: index copy failed" >&2; return 1; }
  fp=$(refactor_fingerprint) || { rm -f -- "$bak"; return 1; }
  printf 'PRE_HEAD=%s\nINDEX_BACKUP=%s\nFINGERPRINT=%s\n' "$head" "$bak" "$fp"
}

# Only a backup this library made, next to this repository's index.
_refactor_valid_backup() {
  local bak="${1-}" idx
  idx=$(_refactor_index_path) || return 1
  case "$bak" in
    "$idx".nexus-refactor.??????) ;;
    *) echo "git-safety: not an index backup this library made: $bak" >&2; return 1 ;;
  esac
  [[ -f "$bak" && ! -L "$bak" ]] || { echo "git-safety: index backup missing: $bak" >&2; return 1; }
}

# Copy the backup over the index and delete it.
refactor_restore_index() {
  local bak="${1-}" idx
  _refactor_valid_backup "$bak" || return 1
  idx=$(_refactor_index_path) || return 1
  cp -p -- "$bak" "$idx" || { echo "restore: copying the backup over the index failed; backup kept at $bak" >&2; return 1; }
  rm -f -- "$bak"
}

# Checkpoint step 3: stage everything outside the exclusions, then re-check.
# Anything still unstaged (for example modified content inside a submodule)
# restores the index and stops before any commit.
refactor_stage() {
  local bak="${1-}" left
  _refactor_valid_backup "$bak" || return 1
  _refactor_load_exclude || return 1
  _refactor_git add -A -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"} || {
    refactor_restore_index "$bak"; echo "stage: git add failed; index restored" >&2; return 1; }
  # Second column set = still differs from the index after `add -A`. A failed
  # git status is an error, never "nothing left".
  left=$(_refactor_git status --porcelain -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"}) \
    || { refactor_restore_index "$bak"; echo "stage: git status failed; index restored" >&2; return 1; }
  left=$(grep '^.[^ ]' <<< "$left")
  if [[ -n "$left" ]]; then
    refactor_restore_index "$bak"
    printf 'stage: these changes cannot be staged, index restored:\n%s\n' "$left" >&2
    return 1
  fi
  return 0
}

# Checkpoint step 5. Prints one outcome line and returns:
#   0  committed      HEAD moved, tree clean; backup deleted
#   2  refused        HEAD did not move; index restored, fingerprint compared
#   3  hook-changed   HEAD moved, tree dirty; commit kept, index NOT restored
# After a commit attempt: sets _REFACTOR_HEAD (current HEAD) and, when HEAD
# moved off <pre-head>, _REFACTOR_DIRTY (what is still uncommitted). Returns 0
# when HEAD moved, 2 when it did not, 1 on a git failure. Both verify
# functions build their 0/2/3 outcome on this, so the codes cannot drift.
_refactor_after_commit() {
  local pre="$1"
  _REFACTOR_HEAD="" _REFACTOR_DIRTY=""
  _REFACTOR_HEAD=$(git rev-parse --verify -q HEAD) || return 1
  [[ "$_REFACTOR_HEAD" != "$pre" ]] || return 2
  _REFACTOR_DIRTY=$(refactor_dirty) || return 1
  return 0
}

refactor_verify() {
  local pre="${1-}" bak="${2-}" fp="${3-}" head dirty now rc
  _refactor_valid_oid "$pre" || { echo "verify: bad PRE_HEAD: $pre" >&2; return 1; }
  _refactor_after_commit "$pre"; rc=$?
  (( rc == 1 )) && return 1
  head="$_REFACTOR_HEAD" dirty="$_REFACTOR_DIRTY"
  if (( rc == 0 )); then
    [[ -f "$bak" ]] && _refactor_valid_backup "$bak" 2>/dev/null && rm -f -- "$bak"
    if [[ -z "$dirty" ]]; then
      echo "verify: committed $head"
      return 0
    fi
    printf 'verify: hook-changed — commit %s kept; a hook changed these files afterwards:\n%s\n' "$head" "$dirty"
    return 3
  fi
  refactor_restore_index "$bak" || return 1
  now=$(refactor_fingerprint) || return 1
  if [[ "$now" == "$fp" ]]; then
    echo "verify: refused — the commit was not made; index restored, nothing was changed"
  else
    echo "verify: refused — the commit was not made; index restored, but a hook changed files or the stash:"
    refactor_dirty
    git stash list
  fi
  return 2
}

# Undo ONE category: reset exactly its own paths, in the index and the working
# tree, to <prev-tree> (the tree before the category: `git write-tree` before
# the first one, then each staged category's tree). Usage:
#   refactor_rollback <prev-tree> <path>...
# The paths are every file the category edited, created or deleted, with both
# sides of every rename. Nothing else is touched — not a stray file another
# process wrote, not the plugin's own files, not an ignored file — so a repo-wide
# restore/clean can never delete what it did not create.
# Returns 0 when every path is back, 1 on bad input or a git failure, and 3
# when a protected path (ignored, plugin-owned, in a submodule, behind a
# symlink) still holds the category's change: the rollback is incomplete.
refactor_rollback() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "rollback: not inside a git work tree" >&2; return 1; }
  [[ -n "$top" && -d "$top" ]] || return 1
  # Paths are repository-relative: run from the toplevel so `rm` and `-e` mean
  # the same file as the git pathspecs, whatever the caller's directory.
  ( cd "$top" || exit 1; _refactor_rollback_at_top "$@" )
}

# True when <path> (repository-relative, cwd = toplevel) must never be touched
# by a rollback: it is gitignored, lies in a plugin-owned excluded directory, is
# an initialized submodule or lies inside one (superproject commands cannot
# restore submodule content, and `git cat-file -e prev:sub/x` fails there, so
# a tracked submodule file would look "created"), or a parent directory on its
# way is a symlink. Expects _refactor_rollback_prepare to have run.
_refactor_protected_path() {
  local p="$1" prev="${2-}" d r
  # The ignore rule protects only a file the previous tree did not have (a
  # local .env that predates the batch). A file the previous tree HAS is
  # tracked, whatever .gitignore says — a force-added local.cfg, even one the
  # category just `git rm --cached` or `git mv`'d — and must be restored.
  if [[ -z "$prev" ]] || ! git cat-file -e "$prev:$p" 2>/dev/null; then
    # 0 ignored, 1 not ignored; anything else (128 for a name like `:!x`,
    # which check-ignore cannot take literally) protects: fail closed.
    _refactor_git check-ignore -q -- "$p" 2>/dev/null; r=$?
    (( r != 1 )) && return 0
  fi
  (( _REFACTOR_RB_READY )) || return 0   # cannot tell: protect
  for r in ${_REFACTOR_EX_REL[@]+"${_REFACTOR_EX_REL[@]}"}; do
    [[ "$p" == "$r" || "$p" == "$r"/* ]] && return 0
  done
  _refactor_under_gitlink "$p" "$_REFACTOR_RB_LINKS" && return 0
  d="$p"
  while [[ "$d" == */* ]]; do
    d="${d%/*}"
    [[ -L "$d" ]] && return 0
  done
  return 1
}

# Is <path> exactly an initialized submodule (needs _refactor_rollback_prepare)?
_refactor_is_gitlink() {
  local g
  while IFS= read -r g; do
    [[ -n "$g" && "$1" == "$g" ]] && return 0
  done <<< "${_REFACTOR_RB_LINKS-}"
  return 1
}

# Load the exclusions and the gitlinks once per rollback, not once per path.
# Gitlinks come from the index AND from <prev-tree>, so a submodule the
# category removed from the index is still protected. A failing git call
# leaves the ready flag at 0, which protects every path.
_refactor_rollback_prepare() {
  local prev="$1"
  _REFACTOR_RB_READY=0
  _refactor_git ls-files -s >/dev/null 2>&1 || return 1
  _refactor_git ls-tree -r "$prev" >/dev/null 2>&1 || return 1
  _REFACTOR_RB_LINKS="$(_refactor_gitlinks)"$'\n'"$(_refactor_gitlinks "$prev")"
  _refactor_load_exclude >/dev/null 2>&1 || return 1
  _REFACTOR_RB_READY=1
}

# True when <path> names, or lies inside, a directory git keeps its own state
# in. Case-folded (macOS and Windows filesystems are case-insensitive by
# default, so `.GIT/HEAD` is `.git/HEAD` there) and with the trailing dots and
# spaces Windows drops; then, for anything that resolves on disk, compared
# physically against the repository's git dir and common git dir.
_refactor_git_internal_path() {
  local p="$1" low phys gd cd
  # Case-folded, with the characters HFS+ ignores in names removed — git's own
  # list (next_hfs_char): U+200C-200F, U+202A-202E, U+206A-206F, U+FEFF. The
  # bytes are built with printf octal escapes and removed with bash's own
  # replacement, so no GNU-only sed syntax is involved (macOS sed differs).
  local zw
  low="$p"
  for zw in \
    "$(printf '\342\200\214')" \
    "$(printf '\342\200\215')" \
    "$(printf '\342\200\216')" \
    "$(printf '\342\200\217')" \
    "$(printf '\342\200\252')" \
    "$(printf '\342\200\253')" \
    "$(printf '\342\200\254')" \
    "$(printf '\342\200\255')" \
    "$(printf '\342\200\256')" \
    "$(printf '\342\201\252')" \
    "$(printf '\342\201\253')" \
    "$(printf '\342\201\254')" \
    "$(printf '\342\201\255')" \
    "$(printf '\342\201\256')" \
    "$(printf '\342\201\257')" \
    "$(printf '\357\273\277')"; do
    low="${low//"$zw"/}"
  done
  low=$(printf '%s' "$low" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 0   # cannot tell: treat as internal
  [[ -n "$low" ]] || return 0
  # .git, with the trailing dots and spaces Windows drops, or its 8.3 short name;
  # ended by `/`, or by the `\` and `:` NTFS also accepts (`.git::$INDEX_ALLOCATION`).
  [[ "$low" =~ (^|[/\\])(\.git[.\ ]*|git~[0-9]+)([/\\:]|$) ]] && return 0
  phys=$(_refactor_phys "$p") || return 0          # cannot tell: treat as internal
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 0
  gd=$(_refactor_phys "$gd") || return 0
  cd=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  cd=$(_refactor_phys "$cd") || return 0
  [[ "$phys" == "$gd" || "$phys" == "$gd"/* || "$phys" == "$cd" || "$phys" == "$cd"/* ]] && return 0
  return 1
}

_refactor_rollback_at_top() {
  local prev="${1-}"; shift || true
  local p
  _REFACTOR_RB_KEPT=""
  if ! _refactor_valid_oid "$prev" || [[ "$(git cat-file -t "$prev" 2>/dev/null)" != tree ]]; then
    echo "rollback: not a tree: $prev" >&2; return 1
  fi
  (( $# > 0 )) || { echo "rollback: no paths given" >&2; return 1; }
  _refactor_rollback_prepare "$prev" || _REFACTOR_RB_READY=0
  # Every refusal happens here, before anything changes, so a refused call
  # never leaves a half-done rollback behind.
  for p in "$@"; do
    [[ -n "$p" && "$p" != /* && "$p" != *$'\n'* && ! "$p" =~ (^|[/\\])\.\.([/\\]|$) ]] || { echo "rollback: bad path: $p" >&2; return 1; }
    # Never anything git keeps its own state in: .git/index, .git/HEAD, a
    # linked worktree's .git file, a submodule's .git.
    if _refactor_git_internal_path "$p"; then echo "rollback: refusing a .git path: $p" >&2; return 1; fi
    # A real directory on disk: list files, not directories. (A path that was
    # a directory in <prev-tree> but is a FILE now — the category replaced the
    # directory — is fine: it is removed, and its old files restored.)
    # A submodule's own directory is not refused: it is protected below, and
    # reported as kept if it changed.
    if [[ -d "$p" && ! -L "$p" ]] && ! _refactor_is_gitlink "$p"; then
      echo "rollback: $p is a directory; list files, not directories" >&2; return 1
    fi
  done
  # Two passes: first remove what the category created (including a file that
  # replaced a directory), then restore what existed, so restoring dir/a never
  # trips over a file still standing at dir.
  local t
  for p in "$@"; do
    t=$(_refactor_entry_type "$prev" "$p") || return 1
    case "$t" in
      blob|commit) ;;                                         # restored in pass 2
      tree) _refactor_rollback_path "$prev" "$p" replaced || return 1 ;;
      *)    _refactor_rollback_path "$prev" "$p" created || return 1 ;;
    esac
  done
  for p in "$@"; do
    t=$(_refactor_entry_type "$prev" "$p") || return 1
    case "$t" in
      blob|commit|tree) _refactor_rollback_path "$prev" "$p" existed || return 1 ;;
    esac
  done
  if [[ -n "$_REFACTOR_RB_KEPT" ]]; then
    printf 'rollback: INCOMPLETE — these paths still hold the category'"'"'s change and were not touched:\n%s' "$_REFACTOR_RB_KEPT" >&2
    return 3
  fi
}

# The type of <path>'s entry in <tree>: blob, tree, commit (a submodule), or
# nothing. Read from ls-tree, not cat-file: a submodule's commit object is not
# in this repository, so `cat-file -t tree:sub` fails. Run from the toplevel.
_refactor_entry_type() {
  local tree="$1" p="$2" meta e
  # :(literal): a name like `:!x` or `:(glob)y` is pathspec magic otherwise,
  # comes back with no type, and would be treated as created and deleted.
  _refactor_git ls-tree "$tree" -- ":(literal)$p" >/dev/null 2>&1 || { echo "rollback: git ls-tree failed" >&2; return 1; }
  while IFS=$'\t' read -r -d '' meta e; do
    [[ "$e" == "$p" ]] || continue
    read -r _ meta _ <<< "$meta"
    printf '%s\n' "$meta"
    return 0
  done < <(_refactor_git ls-tree -z "$tree" -- ":(literal)$p" 2>/dev/null)
  return 0
}

# One path of a rollback. <kind>:
#   existed   in <prev-tree> (file, submodule or directory): restore it
#   replaced  a directory in <prev-tree> that the category replaced with a
#             file: remove the file (pass 1); the directory is restored in pass 2
#   created   not in <prev-tree>: remove it
# A protected path is never touched; if it still differs from <prev-tree> (in
# the working tree OR the index) it is added to _REFACTOR_RB_KEPT, which makes
# the rollback report INCOMPLETE.
_refactor_rollback_path() {
  local prev="$1" p="$2" kind="$3" spec=":(top,literal)$2"
  if _refactor_protected_path "$p" "$prev"; then
    [[ "$kind" == replaced ]] && return 0                     # reported once, in pass 2
    echo "rollback: kept $p (ignored, plugin-owned, in a submodule, or behind a symlink); not touching it" >&2
    if [[ "$kind" == existed ]]; then
      if ! _refactor_git diff --quiet --no-ext-diff "$prev" -- "$spec" 2>/dev/null \
         || ! _refactor_git diff --cached --quiet --no-ext-diff "$prev" -- "$spec" 2>/dev/null; then
        _REFACTOR_RB_KEPT="$_REFACTOR_RB_KEPT$p"$'\n'
      fi
    elif [[ -e "$p" || -L "$p" ]]; then
      _REFACTOR_RB_KEPT="$_REFACTOR_RB_KEPT$p"$'\n'
    fi
    return 0
  fi
  if [[ "$kind" == replaced ]]; then
    # Only a file (or link) standing where the directory was; nothing on disk
    # means the category just deleted the directory, and pass 2 brings it back.
    [[ -e "$p" || -L "$p" ]] || return 0
    _refactor_git rm -q --cached --ignore-unmatch -- "$spec" >/dev/null \
      || { echo "rollback: unstaging $p failed" >&2; return 1; }
    rm -f -- "$p" || { echo "rollback: removing $p failed" >&2; return 1; }
    return 0
  fi
  if [[ "$kind" == existed ]]; then
    _refactor_git restore --source="$prev" --staged --worktree -- "$spec" \
      || { echo "rollback: restoring $p failed" >&2; return 1; }
    return 0
  fi
  # Created by the category: drop it from the index and the disk. (The
  # protected-path check above already kept anything the batch cannot have
  # created: the batch starts on a clean tree, and the path list comes from
  # refactorer, which reads untrusted code.)
  _refactor_git rm -q --cached --ignore-unmatch -- "$spec" >/dev/null \
    || { echo "rollback: unstaging $p failed" >&2; return 1; }
  if [[ -e "$p" || -L "$p" ]]; then
    rm -f -- "$p" || { echo "rollback: removing $p failed" >&2; return 1; }
  fi
}

# Gitlinks (initialized submodules) in the index, one per line.
_refactor_gitlinks() {
  local tree="${1-}" meta g
  if [[ -n "$tree" ]]; then _refactor_git ls-tree -r -z "$tree"; else _refactor_git ls-files -s -z; fi \
    | while IFS=$'\t' read -r -d '' meta g; do
        if [[ "$meta" == 160000\ * ]]; then printf '%s\n' "$g"; fi
      done
}

# Is <path> a submodule, or inside one, given a gitlink list (one per line)?
# The one place both staging and rollback ask this question.
_refactor_under_gitlink() {
  local p="$1" links="$2" g
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    [[ "$p" == "$g" || "$p" == "$g"/* ]] && return 0
  done <<< "$links"
  return 1
}

# Stage one passing category. Usage: refactor_stage_category <prev-tree> <path>...
# <path>s are repository-relative and include deleted paths and both sides of
# every rename. Refuses (rc 1) with the stray list when anything outside them
# differs from the index, and refuses a path inside a submodule. Otherwise
# stages exactly those paths and prints TREE=<id> and STATUS=staged|no-change.
refactor_stage_category() {
  local prev="${1-}"; shift || true
  local p x y rec stray="" in_set t
  _refactor_valid_oid "$prev" || { echo "stage_category: bad previous tree: $prev" >&2; return 1; }
  [[ "$(git cat-file -t "$prev" 2>/dev/null)" == tree ]] || { echo "stage_category: not a tree: $prev" >&2; return 1; }
  (( $# > 0 )) || { echo "stage_category: no paths given" >&2; return 1; }
  local links
  _refactor_git ls-files -s >/dev/null 2>&1 || { echo "stage_category: git ls-files failed" >&2; return 1; }
  links=$(_refactor_gitlinks)
  for p in "$@"; do
    [[ -n "$p" && "$p" != /* && "$p" != *$'\n'* ]] || { echo "stage_category: bad path: $p" >&2; return 1; }
    if _refactor_git_internal_path "$p"; then echo "stage_category: refusing a .git path: $p" >&2; return 1; fi
    if _refactor_under_gitlink "$p" "$links"; then
      echo "stage_category: $p is inside a submodule; submodule content is not rolled back, so the category is refused" >&2
      return 1
    fi
  done
  _refactor_load_exclude || return 1

  # Checked first, so a failing git status is an error, not an empty "clean".
  # (The -z stream itself cannot go through $( ): bash drops its NUL bytes.)
  _refactor_git status --porcelain=v1 -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"} >/dev/null \
    || { echo "stage_category: git status failed" >&2; return 1; }
  # Worktree-vs-index entries only: earlier categories are already staged and
  # show in the X column, which is not this category's business.
  while IFS= read -r -d '' rec; do
    x="${rec:0:1}"; y="${rec:1:1}"; p="${rec:3}"
    if [[ "$x" == R || "$x" == C || "$y" == R || "$y" == C ]]; then
      IFS= read -r -d '' _ || true   # a rename/copy record carries its source next
    fi
    [[ "$y" == " " ]] && continue
    in_set=0
    for t in "$@"; do [[ "$t" == "$p" ]] && { in_set=1; break; }; done
    (( in_set )) || stray="$stray$p"$'\n'
  done < <(_refactor_git status --porcelain=v1 -z --untracked-files=all -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"})
  if [[ -n "$stray" ]]; then
    printf 'stage_category: files outside the category changed (not staged):\n%s' "$stray" >&2
    return 1
  fi

  # The stray check proved nothing outside <path>s differs from the index, so
  # stage with the same repo-wide pathspec. Staging the paths one by one fails
  # on a path that is already gone from both index and disk (a `git mv` or
  # `git rm` source), which is a normal shape for a category.
  _refactor_git add -A -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"} || { echo "stage_category: git add failed" >&2; return 1; }
  t=$(git write-tree) || { echo "stage_category: git write-tree failed" >&2; return 1; }
  printf 'TREE=%s\n' "$t"
  if [[ "$t" == "$prev" ]]; then echo "STATUS=no-change"; else echo "STATUS=staged"; fi
}

# The diff the quality gate reviews: everything since <start>, refused when
# anything outside the exclusions is still uncommitted.
refactor_gate_diff() {
  local start="${1-}" dirty
  _refactor_valid_oid "$start" || { echo "gate_diff: bad start commit: $start" >&2; return 1; }
  git rev-parse --verify -q "$start^{commit}" >/dev/null || { echo "gate_diff: not a commit: $start" >&2; return 1; }
  dirty=$(refactor_dirty) || return 1
  if [[ -n "$dirty" ]]; then
    printf 'gate_diff: uncommitted changes remain; the gate does not start:\n%s\n' "$dirty" >&2
    return 1
  fi
  _refactor_git diff --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/ "$start" -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"}
}

# --- the lead's commit loop (plan "Committing categories") -------------------
#
# refactorer stages each passing category and reports its tree id; it never
# commits. The lead commits them one by one, and at each commit the index AND
# the working tree equal that category's tree, because git-mutation-guard.sh
# credential-scans working-tree files and commit hooks read them too.

# Worktree-vs-index differences and untracked files only (the X column, staged
# changes, is ignored). Empty means the working tree equals the index.
_refactor_unstaged() {
  local st
  _refactor_load_exclude || return 1
  st=$(_refactor_git status --porcelain -- :/ ${_REFACTOR_EX[@]+"${_REFACTOR_EX[@]}"}) \
    || { echo "git-safety: git status failed" >&2; return 1; }
  [[ -n "$st" ]] || return 0
  grep '^.[^ ]' <<< "$st"
  return 0
}

_refactor_is_tree() {
  _refactor_valid_oid "${1-}" && [[ "$(git cat-file -t "$1" 2>/dev/null)" == tree ]]
}

# One category group: <n> <prev-tree> <tree> <path>... — the tree is a tree
# and changes only the given paths relative to <prev-tree>.
_refactor_check_group() {
  local n="$1" prev="$2" cur="$3"; shift 3
  local changed t ok
  _refactor_is_tree "$cur" || { echo "check_trees: category $n: not a tree id: $cur" >&2; return 1; }
  (( $# > 0 )) || { echo "check_trees: category $n: no paths reported" >&2; return 1; }
  while IFS= read -r -d '' changed; do
    ok=0
    for t in "$@"; do [[ "$t" == "$changed" ]] && { ok=1; break; }; done
    (( ok )) || { echo "check_trees: category $n: tree $cur changes an unreported path: $changed" >&2; return 1; }
  done < <(_refactor_git diff -z --no-renames --name-only "$prev" "$cur")
}

# Validate every tree id refactorer reported before any of them is used.
# Usage: _refactor_check_trees <base-tree> <T1> <path>... -- <T2> <path>... -- ...
# <base-tree> is HEAD's tree when refactorer started (the checkpoint's tree in
# Step 5, the last committed tree in a gate-fix round). Each id must be a tree;
# the paths it changes against the previous tree must be among the paths
# reported for it; the last id must equal the index the lead sees (`git
# write-tree`), and the working tree must equal the index.
_refactor_check_trees() {
  local prev="${1-}"; shift || true
  local cur="" n=0 mine p
  local paths=()
  _refactor_is_tree "$prev" || { echo "check_trees: base is not a tree: $prev" >&2; return 1; }
  (( $# > 0 )) || { echo "check_trees: no categories given" >&2; return 1; }
  while (( $# > 0 )); do
    if [[ "$1" == "--" ]]; then
      [[ -n "$cur" ]] || { echo "check_trees: empty category group" >&2; return 1; }
      n=$((n + 1))
      _refactor_check_group "$n" "$prev" "$cur" ${paths[@]+"${paths[@]}"} || return 1
      prev="$cur"; cur=""; paths=(); shift; continue
    fi
    if [[ -z "$cur" ]]; then cur="$1"; else paths+=("$1"); fi
    shift
  done
  [[ -n "$cur" ]] || { echo "check_trees: empty category group" >&2; return 1; }
  n=$((n + 1))
  _refactor_check_group "$n" "$prev" "$cur" ${paths[@]+"${paths[@]}"} || return 1

  mine=$(git write-tree) || return 1
  [[ "$mine" == "$cur" ]] || {
    echo "check_trees: the last reported tree $cur is not the current index ($mine)" >&2; return 1; }
  p=$(_refactor_unstaged) || return 1
  [[ -z "$p" ]] || { printf 'check_trees: the working tree differs from the index:\n%s\n' "$p" >&2; return 1; }
  echo "check_trees: ok ($n categories)"
}

# Move the index and the working tree from tree <from> to tree <to>. A two-tree
# read-tree touches only paths that differ between the two trees (never the
# excluded plugin paths) and refuses rather than overwrite an untracked file.
refactor_set_category_tree() {
  local from="${1-}" to="${2-}" mine
  _refactor_is_tree "$from" || { echo "set_category_tree: not a tree: $from" >&2; return 1; }
  _refactor_is_tree "$to" || { echo "set_category_tree: not a tree: $to" >&2; return 1; }
  # Running the tests after staging leaves stale stat data, which read-tree -m
  # would report as "not uptodate" even when the content is identical.
  git update-index -q --refresh >/dev/null 2>&1
  mine=$(git write-tree) || return 1
  if [[ "$mine" != "$from" ]]; then
    echo "set_category_tree: the index is $mine, expected $from; nothing moved" >&2
    return 1
  fi
  git read-tree -m -u "$from" "$to" || {
    echo "set_category_tree: git read-tree failed moving $from -> $to" >&2; return 1; }
}

# After `git commit` for one category. Prints one outcome line and returns:
#   0  clean         HEAD moved, HEAD^{tree} = <tree>, working tree clean
#   2  refused       HEAD did not move
#   3  hook-changed  HEAD moved, but the committed tree differs or files changed
refactor_verify_category() {
  local pre="${1-}" tree="${2-}" head htree dirty rc
  _refactor_valid_oid "$pre" || { echo "verify_category: bad PRE_HEAD: $pre" >&2; return 1; }
  _refactor_is_tree "$tree" || { echo "verify_category: not a tree: $tree" >&2; return 1; }
  _refactor_after_commit "$pre"; rc=$?
  (( rc == 1 )) && return 1
  if (( rc == 2 )); then
    echo "verify_category: refused — the commit was not made"
    return 2
  fi
  head="$_REFACTOR_HEAD" dirty="$_REFACTOR_DIRTY"
  htree=$(git rev-parse "HEAD^{tree}") || return 1
  if [[ "$htree" == "$tree" && -z "$dirty" ]]; then
    echo "verify_category: clean $head"
    return 0
  fi
  echo "verify_category: hook-changed — commit $head kept, but a hook changed the content:"
  _refactor_git diff --stat "$tree" HEAD
  [[ -n "$dirty" ]] && printf 'files changed after the commit:\n%s\n' "$dirty"
  return 3
}

# --- the commit plan file --------------------------------------------------------
#
# Tree ids and paths come from refactorer's report, which is model output shaped
# by untrusted code, so they never go on a command line. The lead writes them
# with the Write tool to a plan file (in the session records directory, which
# the dirty check excludes), one category per `tree` line, in commit order,
# only categories that were staged:
#
#   tree <40- or 64-hex id>
#   slug <category slug, [a-z0-9-], at most 40>   (optional, once, after its tree)
#   path <repository-relative path>      (one line per path, verbatim)
#
# Blank lines are ignored; any other line refuses the whole plan.

# Print the plan's trees, one per line, after checking its format.
_refactor_plan_trees() {
  local plan="${1-}" line n=0 have_path=1
  [[ -f "$plan" && ! -L "$plan" ]] || { echo "plan: not a regular file: $plan" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '') ;;
      'tree '*)
        (( have_path )) || { echo "plan: category $n lists no paths" >&2; return 1; }
        _refactor_valid_oid "${line#tree }" || { echo "plan: bad tree id: ${line#tree }" >&2; return 1; }
        n=$((n + 1)); have_path=0; printf '%s\n' "${line#tree }" ;;
      'slug '*)
        (( n > 0 )) || { echo "plan: slug before any tree" >&2; return 1; }
        [[ "${line#slug }" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "plan: bad slug: ${line#slug }" >&2; return 1; } ;;
      'path --'|'path ') echo "plan: refused path line: $line" >&2; return 1 ;;
      'path '*)
        (( n > 0 )) || { echo "plan: path before any tree" >&2; return 1; }
        have_path=1 ;;
      *) echo "plan: unrecognised line: $line" >&2; return 1 ;;
    esac
  done < "$plan"
  (( n > 0 && have_path )) || { echo "plan: no complete category" >&2; return 1; }
}

# Number of categories in the plan.
refactor_plan_count() {
  local trees; trees=$(_refactor_plan_trees "${1-}") || return 1
  printf '%s\n' "$trees" | grep -c .
}

# Tree id of category <n> (1-based), or of the last one with `last`.
refactor_plan_tree() {
  local plan="${1-}" which="${2-}" trees count
  trees=$(_refactor_plan_trees "$plan") || return 1
  count=$(printf '%s\n' "$trees" | grep -c .)
  [[ "$which" == last ]] && which="$count"
  if ! [[ "$which" =~ ^[1-9][0-9]*$ ]] || (( which > count )); then
    echo "plan: no category $which (plan has $count)" >&2; return 1
  fi
  printf '%s\n' "$trees" | sed -n "${which}p"
}

# _refactor_check_trees, fed from the plan file.
refactor_check_plan() {
  local start="${1-}" plan="${2-}" line args=() first=1
  _refactor_plan_trees "$plan" >/dev/null || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      'tree '*) (( first )) || args+=(--); first=0; args+=("${line#tree }") ;;
      'path '*) args+=("${line#path }") ;;
    esac
  done < "$plan"
  _refactor_check_trees "$start" "${args[@]}"
}

# The lead writes its plan and message files into the records directory with
# the Write tool, which follows a symlink, and the directory is usually inside
# the repository being refactored. (refactorer resolves its own session-file
# path; this check covers the lead's files.) Refuse a records path that
# passes through a symlink BELOW this repository's toplevel (a repository could
# ship `.claude -> <another checkout>`). Links above the toplevel are the
# user's own layout and fine; a records path outside the repository is not the
# repository's to redirect. Checked before anything is created.
_refactor_records_unlinked() {
  local a="$1" top link="" ph pp par
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  top=$(_refactor_phys "$top") || { echo "git-safety: cannot resolve $top" >&2; return 1; }
  while [[ "$a" == /?* ]]; do
    if [[ -d "$a" ]]; then
      ph=$(cd -P -- "$a" 2>/dev/null && pwd -P) || ph=""
      if [[ "$ph" == "$top" ]]; then
        # A component that resolves to the toplevel while its parent is
        # already inside it is a link back to the root (`.claude -> .`).
        # ${a%/*} is empty for /repo; `cd ""` stays put on some bash versions.
        par="${a%/*}"
        pp=$(cd -P -- "${par:-/}" 2>/dev/null && pwd -P) || pp=""
        if [[ -L "$a" && ( "$pp" == "$top" || "$pp" == "$top"/* ) ]]; then
          echo "git-safety: the session records directory is reached through a symlink inside the repository: $a" >&2
          return 1
        fi
        [[ -z "$link" ]] && return 0
        echo "git-safety: the session records directory is reached through a symlink inside the repository: $link" >&2
        return 1
      fi
    fi
    [[ -L "$a" ]] && link="$a"
    a="${a%/*}"
  done
  return 0
}

# The session records directory (absolute), created if missing.
_refactor_sessions_dir() {
  local d
  d=$(_refactor_resolve_paths | sed -n 's/^sessions //p') || return 1
  [[ -n "$d" ]] || { echo "git-safety: no session records directory resolved" >&2; return 1; }
  _refactor_records_unlinked "$d" || return 1
  mkdir -p -- "$d" || { echo "git-safety: cannot create $d" >&2; return 1; }
  printf '%s\n' "$d"
}

# This repository's name for file names: the toplevel's last component,
# reduced to [a-z0-9-].
_refactor_repo_tag() {
  local top tag
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  tag=$(printf '%s' "${top##*/}" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9-' '-')
  printf '%s\n' "${tag:-repo}"
}

# Where the lead writes the commit plan for this repository and round:
#   <session records>/<slug>-<repo>-r<round>-commit-plan.txt
# One file per repo and per gate round, so multi-repo runs and Step B rounds
# never overwrite each other's tree list. Usage: refactor_plan_path <slug> <round>
refactor_plan_path() {
  local slug="${1-}" round="${2-}" dir tag
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "plan_path: bad slug: $slug" >&2; return 1; }
  [[ "$round" =~ ^[0-9]{1,3}$ ]] || { echo "plan_path: bad round: $round" >&2; return 1; }
  local f
  dir=$(_refactor_sessions_dir) || return 1
  tag=$(_refactor_repo_tag) || return 1
  f="$dir/$slug-$tag-r$round-commit-plan.txt"
  # The lead writes this file with the Write tool, which follows a symlink, and
  # a repository could ship a link at this predictable name: remove whatever
  # already sits there, as refactor_commit_msg does. (A linked directory on the
  # way is refused by _refactor_sessions_dir.)
  if [[ -L "$f" || -e "$f" ]]; then
    [[ -L "$f" || -f "$f" ]] || { echo "plan_path: not a regular file: $f" >&2; return 1; }
    rm -f -- "$f" || { echo "plan_path: cannot remove $f" >&2; return 1; }
  fi
  printf '%s\n' "$f"
}

# Write category <n>'s commit message from a fixed template and print its path.
# The slug comes from the plan file (checked there against [a-z0-9-]), never
# from a command line: it is the only part of the message ever derived from
# finding text. A ticket key is taken from the branch name when it has one
# (`feature/PROJ-12-x` -> `[PROJ-12] `). Usage: refactor_commit_msg <plan> <n>
refactor_commit_msg() {
  local plan="${1-}" n="${2-}" total slug line k=0 branch ticket="" file
  total=$(refactor_plan_count "$plan") || return 1
  if ! [[ "$n" =~ ^[1-9][0-9]{0,3}$ ]] || (( n > total )); then
    echo "commit_msg: no category $n (plan has $total)" >&2; return 1
  fi
  slug=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      'tree '*) k=$((k + 1)) ;;
      'slug '*) (( k == n )) && slug="${line#slug }" ;;
    esac
  done < "$plan"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || slug="category-$n"
  branch=$(git branch --show-current 2>/dev/null)
  [[ "$branch" =~ (^|/)([A-Z][A-Z0-9]*-[0-9]+) ]] && ticket="[${BASH_REMATCH[2]}] "
  file="${plan%-commit-plan.txt}-$n-commit-msg.txt"
  # Never write through a link planted at that name.
  [[ -L "$file" ]] && { echo "commit_msg: $file is a symlink; refusing" >&2; return 1; }
  rm -f -- "$file"
  # noclobber: if anything appeared at that name since the rm (a planted link),
  # the write fails instead of following it.
  ( set -o noclobber; printf '%srefactor(%s): %s/%s via /refactor\n' "$ticket" "$slug" "$n" "$total" > "$file" ) \
    || { echo "commit_msg: cannot write $file" >&2; return 1; }
  printf '%s\n' "$file"
}

# After a commit a hook changed (verify rc 3), put the LATER categories' changes
# back into the working tree on top of what the hook left, so nothing that
# passed its tests is lost. Applies `git diff <tree-n> <tree-last>` to the
# working tree only; on a conflict it applies nothing and says so.
refactor_restore_later() {
  local from="${1-}" to="${2-}" patch
  if ! _refactor_is_tree "$from" || ! _refactor_is_tree "$to"; then
    echo "restore_later: not a tree" >&2; return 1
  fi
  [[ "$from" == "$to" ]] && return 0
  # Plumbing, not `git diff`: diff-tree ignores the user's diff.noprefix,
  # diff.external, textconv and color settings, any of which would break the
  # patch git apply reads.
  # Status checked on its own call; the patch itself is captured with a
  # sentinel, because $( ) strips every trailing newline and a binary patch
  # can end in a blank line git apply needs.
  git diff-tree -p --binary --full-index "$from" "$to" >/dev/null \
    || { echo "restore_later: git diff-tree failed" >&2; return 1; }
  patch=$(git diff-tree -p --binary --full-index "$from" "$to"; printf x)
  patch="${patch%x}"
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n "$top" && -d "$top" ]] || return 1
  # git apply works relative to the current directory; run it from the toplevel.
  # --whitespace=nowarn: the user's apply.whitespace=fix would silently change
  # the restored content, and =error would fail the check for no real overlap.
  local why
  if why=$(cd "$top" && printf '%s' "$patch" | git apply --whitespace=nowarn --check 2>&1); then
    (cd "$top" && printf '%s' "$patch" | git apply --whitespace=nowarn) || return 1
    echo "restore_later: later categories restored to the working tree (uncommitted)"
  else
    # Keep the later work reachable, so `git gc` cannot prune it while the
    # developer merges it by hand: a commit of the last tree under a ref.
    # A ref pointing straight at the tree: no commit object, so no signing
    # prompt and nothing that looks like history.
    local ref="refs/nexus-refactor/unapplied-${to:0:12}"
    git update-ref "$ref" "$to" 2>/dev/null || ref=""
    echo "restore_later: the later categories do not apply on top of the hook's edits; nothing applied." >&2
    [[ -n "$why" ]] && printf 'restore_later: git apply said: %s\n' "$why" >&2
    [[ -n "$ref" ]] && echo "restore_later: the later categories are kept at $ref (delete it with git update-ref -d $ref when done)" >&2
    echo "restore_later: recover by hand: git diff-tree -p --binary --full-index $from $to | git apply --whitespace=nowarn --3way" >&2
    return 1
  fi
}

# After the last category committed clean: remove this plan file and its
# commit-message files, so the session records do not fill up. On any stop the
# plan file is kept — it is the list of trees the recovery command needs.
refactor_plan_cleanup() {
  local plan="${1-}" base f n total dir
  base="${plan%-commit-plan.txt}"
  [[ "$base" != "$plan" ]] || { echo "plan_cleanup: not a plan file: $plan" >&2; return 1; }
  dir=$(_refactor_sessions_dir) || return 1
  [[ "${plan%/*}" == "$dir" ]] || { echo "plan_cleanup: $plan is not in the session records ($dir)" >&2; return 1; }
  total=$(refactor_plan_count "$plan") || return 1
  # Exactly the names refactor_commit_msg writes for this plan — never a glob,
  # which could match another run whose slug extends this one's.
  for (( n = 1; n <= total; n++ )); do
    f="$base-$n-commit-msg.txt"
    [[ -f "$f" && ! -L "$f" ]] && rm -f -- "$f"
  done
  rm -f -- "$plan"
}
