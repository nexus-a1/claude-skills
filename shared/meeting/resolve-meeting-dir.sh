#!/usr/bin/env bash
# Meeting directory resolution for the /meeting skill.
#
# A meeting record directory is named "{YYYY-MM-DD-HHMM}-{slug}" (local time,
# captured once when the meeting is opened). Directories written before that
# format shipped are named with the bare "{slug}" and are never renamed or
# migrated — they stay readable in place, forever.
#
# Both functions are READ-ONLY by construction: nothing here creates, moves, or
# writes a directory. Only Step L1 of the skill creates a meeting.
#
# Expects $MEETINGS_DIR and (optionally) $LEGACY_MEETINGS_DIR to be set by the
# caller — see the Configuration block in plugin/skills/meeting/SKILL.md.
#
# Design invariant: NEVER derive a slug from a directory name. `state.json.slug`
# is authoritative. Parsing a slug back out of a directory name is the only
# operation that can be genuinely ambiguous, so no code here does it.
#
# Portability: no `sort -V` and no `date -d` — both are GNU-only and would break
# silently on macOS/BSD. Plain POSIX `sort` is correct here because the
# fixed-width zero-padded timestamp makes ASCII order identical to chronological
# order.
#
# Safe to source under `set -euo pipefail`: no bare `cmd && assignment`
# statements (they return non-zero when the test fails and would abort the
# caller), and no unguarded empty-array expansions.

# resolve_meeting_dir SLUG_OR_DIRNAME
#
# Resolves a bare slug OR a full directory name to exactly one meeting
# directory. Searches $MEETINGS_DIR, then $LEGACY_MEETINGS_DIR.
#
# Ranking for a bare slug: any timestamped match outranks a legacy bare match
# (a bare directory can only exist because it predates this format, so it is
# provably older). Among timestamped matches, the lexicographic maximum is the
# newest.
#
# stdout: the resolved path, on success (exit 0)
# stderr: an ERROR line, on failure (exit 1) — nothing is written to stdout
resolve_meeting_dir() {
  local arg="$1" root dir slug
  local -a ts_hits=() bare_hits=()

  if [ -z "$arg" ]; then
    echo "ERROR: resolve_meeting_dir: empty meeting identifier" >&2
    return 1
  fi

  # 1. A full timestamped directory name was supplied — try it as an exact
  #    path first. Each [0-9] absorbs exactly one digit, so no arbitrary text
  #    (a slug such as "retro-q3-sync") can ever satisfy this pattern.
  #
  #    On a miss we deliberately fall through to the slug search rather than
  #    failing: a slug is allowed to look like a timestamped directory name
  #    (nothing forbids someone naming a meeting "2026-07-25-0900-standup"),
  #    and treating this branch as terminal would make such a meeting
  #    unreachable by slug. Falling through cannot produce a wrong match,
  #    because the search below compares state.json.slug for exact equality.
  case "$arg" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]-*)
      for root in "$MEETINGS_DIR" "${LEGACY_MEETINGS_DIR:-}"; do
        if [ -n "$root" ] && [ -f "$root/$arg/state.json" ]; then
          printf '%s\n' "$root/$arg"
          return 0
        fi
      done
      ;;
  esac

  # 2. A bare slug was supplied. Timestamped candidates are found by anchoring
  #    the PREFIX only and then comparing state.json.slug — never by pattern-
  #    matching the slug out of the directory name. That is what makes a slug
  #    which is a dash-suffix of another slug ("sync" vs "q3-sync") safe, and
  #    what keeps a collision-suffixed directory ("...-q3-sync-2") resolvable
  #    while a genuine "q3-sync-2" meeting stays distinct.
  #
  #    Only $MEETINGS_DIR is scanned for timestamped directories: the legacy
  #    root is write-frozen and predates this format, so it cannot contain one.
  for dir in "$MEETINGS_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]-*; do
    if [ -f "$dir/state.json" ]; then
      slug=$(jq -r '.slug // empty' "$dir/state.json" 2>/dev/null || true)
      if [ "$slug" = "$arg" ]; then
        ts_hits+=("$dir")
      fi
    fi
  done

  # Legacy bare directories: an exact directory test, never a glob.
  for root in "$MEETINGS_DIR" "${LEGACY_MEETINGS_DIR:-}"; do
    if [ -n "$root" ] && [ -f "$root/$arg/state.json" ]; then
      bare_hits+=("$root/$arg")
    fi
  done

  # 3. Rank: timestamped always beats legacy bare.
  if [ "${#ts_hits[@]}" -gt 0 ]; then
    printf '%s\n' "${ts_hits[@]}" | sort | tail -n 1
    return 0
  fi
  if [ "${#bare_hits[@]}" -gt 0 ]; then
    printf '%s\n' "${bare_hits[0]}"
    return 0
  fi

  echo "ERROR: meeting '$arg' not found in $MEETINGS_DIR${LEGACY_MEETINGS_DIR:+ or $LEGACY_MEETINGS_DIR}" >&2
  return 1
}

# find_in_progress_meetings
#
# Enumerates every meeting directory — both naming shapes, both roots — and
# emits one tab-separated "path<TAB>slug<TAB>status" row per meeting whose
# status is "in-progress".
#
# Use this ONLY when Wrap/Resume were given no identifier at all. Do NOT feed
# the resulting slug back into resolve_meeting_dir: that resolver ranks by
# timestamp with no status awareness and could return a newer *wrapped*
# directory instead of the open one found here. Bind MDIR to the path column
# directly.
#
# The slug column comes from state.json, so it stays correct even when a
# directory name says otherwise.
find_in_progress_meetings() {
  local root dir slug status

  for root in "$MEETINGS_DIR" "${LEGACY_MEETINGS_DIR:-}"; do
    if [ -z "$root" ] || [ ! -d "$root" ]; then
      continue
    fi
    for dir in "$root"/*/; do
      dir="${dir%/}"
      if [ ! -f "$dir/state.json" ]; then
        continue
      fi
      status=$(jq -r '.status // empty' "$dir/state.json" 2>/dev/null || true)
      if [ "$status" != "in-progress" ]; then
        continue
      fi
      slug=$(jq -r '.slug // empty' "$dir/state.json" 2>/dev/null || true)
      printf '%s\t%s\t%s\n' "$dir" "$slug" "$status"
    done
  done
}
