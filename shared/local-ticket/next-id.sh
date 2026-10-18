#!/usr/bin/env bash
# plugin/shared/local-ticket/next-id.sh
#
# Prints the next local ticket ID for a project that has no tracker, from the
# optional `project.ticket_prefix` key in .claude/configuration.yml.
#
# Usage:
#   next-id.sh            (no arguments; run from inside the project)
#
# Exit / stdout:
#   0  PREFIX-N   the next free ID: highest N found anywhere, plus 1
#   0  (empty)    no configuration file, or project.ticket_prefix not set
#   2  (empty)    project.ticket_prefix is set but invalid; stderr names the rule
#   1  (empty)    a source exists but could not be read; stderr names it
#
# N is the highest number found in three places: local and remote-tracking
# branch names, commit subjects on every ref, and the top-level folder names in
# the configured work directory. There is no counter file — this script writes
# nothing. A source that does not exist yet (no work directory, no commits, no
# remote, not a git repository) counts as empty, so a brand-new project gets
# PREFIX-1. A source that exists but cannot be read is an error, never "empty":
# a failed read that looked like "no matches" would hand out a number in use.
#
# shortcut: no lock, two sessions passing /create-requirements' re-check in the
# same moment can both take N; add a lock (see draft-reconcile.sh:113-129) if
# that ever happens.

set -u
# [A-Z] in a non-C locale can match lowercase letters.
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'next-id: %s\n' "${2}" >&2; exit "${1}"; }

[ "$#" -eq 0 ] || die 2 "takes no arguments"

found=""
for candidate in \
  "$SELF_DIR/../resolve-config.sh" \
  "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/shared/resolve-config.sh" \
  "$HOME/.claude/shared/resolve-config.sh"; do
  if [ -f "$candidate" ]; then
    # resolve-config.sh reads unset variables at file scope.
    set +u
    # shellcheck source=/dev/null
    . "$candidate"
    set -u
    found=1
    break
  fi
done
[ -n "$found" ] || die 1 "resolve-config.sh not found — reinstall the nexus plugin"

[ -n "${CONFIG:-}" ] || exit 0
[ -r "$CONFIG" ] || die 1 "cannot read $CONFIG"
# No uncommented ticket_prefix line: not configured, and no yq needed — a
# project that never set a prefix must not start seeing "yq is required".
grep -qE '^[[:space:]]*ticket_prefix[[:space:]]*:' -- "$CONFIG"
rc=$?
[ "$rc" -eq 1 ] && exit 0
[ "$rc" -eq 0 ] || die 1 "cannot read $CONFIG"
command -v yq >/dev/null 2>&1 || die 1 "yq is required to read $CONFIG and was not found on PATH"

present="$(yq -r 'select(document_index == 0) | (.project // {}) | has("ticket_prefix")' "$CONFIG" 2>/dev/null)" \
  || die 1 "could not parse $CONFIG"
[ "$present" = "true" ] || exit 0
# The key is present, so a null (`ticket_prefix:` with no value) is invalid,
# not unset.
prefix="$(yq -r 'select(document_index == 0) | .project.ticket_prefix' "$CONFIG" 2>/dev/null)" \
  || die 1 "could not parse $CONFIG"
if ! [[ "$prefix" =~ ^[A-Z]+$ ]] || [ "$prefix" = "DRAFT" ]; then
  die 2 "project.ticket_prefix in $CONFIG must be uppercase letters A-Z only, and not DRAFT — ignoring it"
fi

refs=""
subjects=""
command -v git >/dev/null 2>&1 || die 1 "git is required and was not found on PATH"
# Only "not a git repository" means the git sources are absent. Any other
# failure (e.g. "detected dubious ownership") means history could not be read.
if ! git_err="$(git rev-parse --is-inside-work-tree 2>&1 >/dev/null)"; then
  case "$git_err" in
    *"not a git repository"*) in_git="" ;;
    *) die 1 "cannot query git history: ${git_err%%$'\n'*}" ;;
  esac
else
  in_git=1
fi
if [ -n "$in_git" ]; then
  refs="$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes)" \
    || die 1 "git for-each-ref failed"
  any_ref="$(git for-each-ref --count=1 --format='%(refname)')" \
    || die 1 "git for-each-ref failed"
  # A fresh `git init` has no refs, and `git log --all` can fail there.
  if [ -n "$any_ref" ]; then
    subjects="$(git log --all --format=%s)" || die 1 "git log failed"
  fi
fi

# resolve_artifact warns on stderr and falls back to the default folder when the
# work location is misconfigured. Scanning that guess could offer a taken ID, so
# any warning is treated as unreadable. The path itself is always one line.
resolved="$(resolve_artifact work work 2>&1)"
[ "$(printf '%s\n' "$resolved" | wc -l)" -eq 1 ] \
  || die 1 "the work location in $CONFIG is misconfigured: ${resolved%$'\n'*}"
WORK_DIR="$resolved"
names=""
if [ -e "$WORK_DIR" ] || [ -L "$WORK_DIR" ]; then
  if ! { [ -d "$WORK_DIR" ] && [ -r "$WORK_DIR" ] && [ -x "$WORK_DIR" ]; }; then
    die 1 "work directory $WORK_DIR exists but is not a readable directory"
  fi
  # Two levels: epic tickets live at {EPIC}-{slug}/{TICKET}-{slug}/. Relative
  # paths, so a prefix-like name in WORK_DIR itself is never counted.
  names="$(cd "$WORK_DIR" && find . -mindepth 1 -maxdepth 2)" || die 1 "could not list $WORK_DIR"
fi

# The letter guard keeps SMT-40 from counting as MT-40.
matches="$(printf '%s\n%s\n%s\n' "$refs" "$subjects" "$names" \
  | grep -oE "(^|[^A-Za-z])${prefix}-[0-9]+")"
rc=$?
[ "$rc" -le 1 ] || die 1 "scan failed (grep exit $rc)"

max=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  n="${m##*-}"
  # shortcut: numbers over 9 digits are ignored, so bash arithmetic cannot overflow.
  [ "${#n}" -le 9 ] || continue
  n=$((10#$n))
  [ "$n" -gt "$max" ] && max="$n"
done <<< "$matches"

printf '%s-%d\n' "$prefix" "$((max + 1))"
