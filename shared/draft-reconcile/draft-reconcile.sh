#!/usr/bin/env bash
# plugin/shared/draft-reconcile/draft-reconcile.sh
#
# Reconciles a DRAFT-{slug} requirements session (created by
# `/create-requirements --no-ticket`) with a real ticket number, once one
# exists. Sourced (never executed as a subprocess) by three call sites:
#   - /create-requirements's `reconcile <draft-id> <ticket-id>` subcommand
#   - /update-context, when it detects an active DRAFT session plus a
#     ticket-shaped token in the user's note
#   - /resume-work, when it detects a DRAFT-prefixed identifier being resumed
#
# Usage (mirrors resolve-config.sh's sourcing convention — marketplace
# installs get ${CLAUDE_PLUGIN_ROOT} substituted inline; ~/.claude fallback
# is for local/dev copies only). Does NOT depend on $WORKSPACE_ROOT (or any
# other variable) being set by a prior `source resolve-config.sh` in the
# same shell — each skill's bash code block is very likely its own separate
# shell invocation, so a variable set in an earlier block cannot be relied
# on to persist into a later one (confirmed by testing: an initial draft
# that referenced $WORKSPACE_ROOT this way silently operated against
# whatever the caller's CWD happened to be, once the two calls landed in
# different shells). draft_reconcile instead derives the repository root
# itself, from $work_dir, via `git rev-parse --show-toplevel` —
# self-contained, no cross-call state assumption. The only precondition is
# that $work_dir is a real path inside the repository, which every caller
# already has by construction.
#
#   if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/draft-reconcile/draft-reconcile.sh" ]; then
#     source "${CLAUDE_PLUGIN_ROOT}/shared/draft-reconcile/draft-reconcile.sh"
#   elif [ -f "$HOME/.claude/shared/draft-reconcile/draft-reconcile.sh" ]; then
#     source "$HOME/.claude/shared/draft-reconcile/draft-reconcile.sh"
#   else
#     echo "ERROR: draft-reconcile.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
#     exit 1
#   fi
#   draft_reconcile_validate_ids "$DRAFT_ID" "$TICKET_ID" || exit 1   # cheap pre-check, e.g. before a `stat`
#   new_id=$(draft_reconcile "$WORK_DIR" "$DRAFT_ID" "$TICKET_ID" "$BASE_BRANCH") || exit 1
#
# Does NOT call AskUserQuestion — every caller owns its own confirm prompt;
# by the time draft_reconcile runs, (draft_id, ticket_id) is already a
# pre-confirmed pair. Only the standalone `reconcile` subcommand has no
# prior existence check on the draft session, so it alone must `stat`
# $WORK_DIR/{draft_id}/state.json before calling in — draft_reconcile_validate_ids
# below is the identifier-SHAPE half of that pre-check (single source of
# truth for the pattern); existence is the caller's job.
#
# Deliberately NOT `set -euo pipefail` — this file is sourced into a
# caller's shell, and changing the caller's shell options out from under it
# is a bigger footgun than any error this script could otherwise catch
# locally (resolve-config.sh, the only other genuinely-sourced shared lib
# in this plugin, follows the same convention). Every function below checks
# its own return codes explicitly instead.

# Identifier shape guard, exported standalone so callers with their own
# pre-flight (e.g. the reconcile subcommand's `stat`) can validate BEFORE
# building a path, not just rely on draft_reconcile's internal check — one
# source of truth for the pattern (mirrors the identifier-safety regex
# already established at update-context/SKILL.md:62 and the ticket regex
# at create-requirements/SKILL.md:182).
draft_reconcile_validate_ids() {
  local draft_id="$1" ticket_id="$2"
  # Slug interior must be bounded by alphanumerics (no leading/trailing
  # ./-/_) and must not contain ".." anywhere — both are invalid git
  # ref-name components, and rejecting them here (before any filesystem or
  # git operation) is cheaper than discovering it after two jq writes at
  # the branch-creation step.
  [[ "$draft_id" =~ ^DRAFT-[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || {
    echo "ERROR: invalid draft identifier '$draft_id' — expected DRAFT-{slug}, alphanumeric-bounded" >&2
    return 1
  }
  [[ "$draft_id" == *..* ]] && {
    echo "ERROR: invalid draft identifier '$draft_id' — consecutive dots are not a valid git ref component" >&2
    return 1
  }
  [[ "$ticket_id" =~ ^[A-Z]+-[0-9]+$ ]] || {
    echo "ERROR: invalid ticket identifier '$ticket_id' — expected TICKET-123 shape" >&2
    return 1
  }
  return 0
}

# The reconciliation procedure itself.
# Args: work_dir draft_id ticket_id base_branch
# Prints the new identifier (TICKET-{slug}) on stdout on success.
# Returns non-zero on any failure. Every failure after the rename undoes
# the rename before returning — no session is ever left findable under
# neither its old nor its new identifier.
draft_reconcile() {
  local work_dir="$1" draft_id="$2" ticket_id="$3" base_branch="$4"

  draft_reconcile_validate_ids "$draft_id" "$ticket_id" || return 1

  local draft_dir="$work_dir/$draft_id"
  [[ -f "$draft_dir/state.json" ]] || {
    echo "ERROR: no session found at $draft_dir/state.json" >&2
    return 1
  }

  local repo_root
  repo_root="$(git -C "$work_dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ERROR: could not determine the git repository root from $work_dir" >&2
    return 1
  }

  local slug="${draft_id#DRAFT-}"
  local new_id="${ticket_id}-${slug}"
  local new_dir="$work_dir/$new_id"

  # Lock lives OUTSIDE the directory being renamed — a lock file inside it
  # would be carried away by the rename itself, letting a second session
  # `touch` a fresh lock file at the old path post-rename and defeat mutual
  # exclusion entirely. Mirrors where .active-sessions.lock already sits
  # (write-safety.md), not the per-session state.json.lock pattern.
  local lock="$work_dir/.reconcile.lock"
  if [[ -L "$lock" ]]; then
    echo "ERROR: $lock is a symlink — refusing to open it (a planted symlink here could redirect the lock's truncation to an arbitrary file)" >&2
    return 1
  fi
  touch "$lock" 2>/dev/null || {
    echo "ERROR: cannot create lock file $lock" >&2
    return 1
  }

  local rc
  (
    flock -x -w 2 200 || { echo "ERROR: could not acquire $lock within 2s — another reconcile is likely in progress" >&2; exit 1; }

    # Collision pre-flight — INSIDE the lock, not before acquiring it, or
    # two racing sessions could both pass the check before either mutates
    # anything.
    if [[ -e "$new_dir" ]]; then
      echo "ERROR: $new_dir already exists — refusing to merge or overwrite" >&2
      exit 1
    fi
    if git -C "$repo_root" show-ref --verify --quiet "refs/heads/feature/$new_id" 2>/dev/null; then
      echo "ERROR: branch feature/$new_id already exists — refusing to reconcile onto it" >&2
      exit 1
    fi

    # Rename FIRST, not last: the manifest lives outside the renamed
    # directory, so writing manifest/state before the rename would leave a
    # window where a failed rename orphans a manifest entry pointing at a
    # directory that no longer exists. `-T` (no-target-directory) makes mv
    # fail loudly if $new_dir sprang into existence between the -e check
    # above and here (e.g. a concurrent /create-requirements or /epic run
    # creating that identifier fresh) instead of silently nesting the draft
    # inside it.
    mv -T "$draft_dir" "$new_dir" || {
      echo "ERROR: failed to rename $draft_dir -> $new_dir (target may have appeared concurrently)" >&2
      exit 1
    }

    # From here on, any failure must undo the rename before this subshell
    # exits, or the session becomes findable under neither identifier. A
    # bare directory-rename-back is not enough on its own: if state.json or
    # manifest.json were already rewritten to the new identifier before a
    # LATER step fails (e.g. the branch-creation checks below), moving the
    # directory back would leave the OLD path holding the NEW identifier's
    # content — a different, subtler half-renamed state than AC-3.3b is
    # guarding against. So _rollback also restores whichever of those two
    # files it already mutated, using the pre-mutation snapshots captured
    # right before each write below.
    orig_state="$(cat "$new_dir/state.json" 2>/dev/null)"
    state_mutated=""
    orig_manifest=""
    manifest_mutated=""
    orig_sessions=""
    sessions_mutated=""
    _rollback() {
      if [[ -n "$state_mutated" ]]; then
        printf '%s' "$orig_state" > "$new_dir/state.json" 2>/dev/null
      fi
      if [[ -n "$manifest_mutated" && -f "$manifest" ]]; then
        printf '%s' "$orig_manifest" > "$manifest" 2>/dev/null
      fi
      if [[ -n "$sessions_mutated" && -f "$sessions" ]]; then
        printf '%s' "$orig_sessions" > "$sessions" 2>/dev/null
      fi
      mv -T "$new_dir" "$draft_dir" 2>/dev/null
    }

    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # state.json: identifier + branches (local checkout only — no push
    # here; see the header note on the deferred push). Temp file lives in
    # the SAME directory as the target (mirrors auto-context.sh's
    # "${STATE_FILE}.tmp.$$" pattern) so the final `mv` is a true atomic
    # rename — a bare `mktemp` defaults to $TMPDIR, usually a different
    # filesystem, which would make this a non-atomic copy instead.
    tmp="$new_dir/.state.json.tmp.$$"
    if ! jq --arg id "$new_id" --arg base "$base_branch" --arg feat "feature/$new_id" --arg t "$now" \
         '.identifier = $id
          | .branches.base = $base
          | .branches.feature = $feat
          | .branches.remote_pushed = false
          | .updated_at = $t' \
         "$new_dir/state.json" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"; _rollback
      echo "ERROR: failed to update state.json for $new_id" >&2
      exit 1
    fi
    mv "$tmp" "$new_dir/state.json" || {
      rm -f "$tmp"; _rollback
      echo "ERROR: failed to commit the updated state.json for $new_id" >&2
      exit 1
    }
    state_mutated=1

    # Work manifest: rename the entry, populate branch (was null for a
    # DRAFT session per AC-3.2) and path (must track the renamed directory,
    # or manifest-driven tooling that skips items whose path doesn't exist
    # would treat this reconciled session as gone).
    manifest="$work_dir/manifest.json"
    if [[ -f "$manifest" ]]; then
      orig_manifest="$(cat "$manifest")"
      mtmp="$work_dir/.manifest.json.tmp.$$"
      if ! jq --arg old "$draft_id" --arg new "$new_id" --arg branch "feature/$new_id" \
              --arg path "$new_id/" --arg t "$now" \
           '(.items[] | select(.identifier == $old)) |= (.identifier = $new | .branch = $branch | .path = $path | .updated_at = $t)
            | .last_updated = $t' \
           "$manifest" > "$mtmp" 2>/dev/null; then
        rm -f "$mtmp"; _rollback
        echo "ERROR: failed to update work manifest for $new_id" >&2
        exit 1
      fi
      mv "$mtmp" "$manifest" || {
        rm -f "$mtmp"; _rollback
        echo "ERROR: failed to commit the updated work manifest for $new_id" >&2
        exit 1
      }
      manifest_mutated=1
    fi

    # .active-sessions: {session_id: work_id} — work_id is the VALUE, not
    # the key, and more than one session can point at the same work_id, so
    # every entry whose value equals the old id is rewritten. Nested under
    # its own lock, matching how the rest of the codebase already treats
    # this file (write-safety.md); no reverse lock-acquisition order exists
    # between .reconcile.lock and .active-sessions.lock, so nesting is safe.
    sessions="$work_dir/.active-sessions"
    if [[ -f "$sessions" ]]; then
      orig_sessions="$(cat "$sessions")"
      slock="$sessions.lock"
      touch "$slock" 2>/dev/null
      # A subshell's variable assignments don't propagate to this scope, so
      # sessions_mutated is set from the subshell's own exit status directly
      # (not via $?) — 0 only on an actual committed remap, letting
      # _rollback know a restore is needed.
      if ( flock -x -w 2 201 || { echo "WARNING: .active-sessions lock busy — session tracking for $new_id may still point at $draft_id; re-run reconcile is safe (idempotent)" >&2; exit 2; }
        stmp="$work_dir/.active-sessions.tmp.$$"
        if jq --arg old "$draft_id" --arg new "$new_id" \
           'with_entries(if .value == $old then .value = $new else . end)' \
           "$sessions" > "$stmp" 2>/dev/null; then
          mv "$stmp" "$sessions" || { rm -f "$stmp"; echo "WARNING: failed to commit .active-sessions remap for $new_id — session tracking may still point at $draft_id" >&2; exit 1; }
          exit 0
        else
          rm -f "$stmp"
          echo "WARNING: failed to remap .active-sessions for $new_id — session tracking may still point at $draft_id" >&2
          exit 1
        fi
      ) 201>"$slock"; then
        sessions_mutated=1
      fi
    fi

    # Local checkout only — mirrors create-requirements Stage 1.6 exactly.
    # No push here; the eventual push (wherever the session's next natural
    # push point is) must still call record-audit.sh first, same as
    # create-requirements Stage 2.3, or git-mutation-guard.sh will block it.
    # (A `--` guard before $base_branch was considered and rejected: tested
    # empirically, `git rev-parse --verify --` and `git checkout -b name --`
    # both treat `--` as the revision/pathspec separator here, not an
    # option terminator, and BOTH FAIL on a perfectly valid branch name —
    # confirmed with `git rev-parse --verify -- master` -> "fatal: Needed a
    # single revision". base_branch CAN be free text — every caller's base
    # branch picker offers "[Other] Enter custom branch" — so it is
    # instead bound safely at the call site (a quoted heredoc, not
    # templated into the command line) rather than guarded here with `--`
    # syntax that breaks the valid case.)
    if ! git -C "$repo_root" rev-parse --verify "$base_branch" >/dev/null 2>&1; then
      _rollback
      echo "ERROR: base branch '$base_branch' not found" >&2
      exit 1
    fi
    if ! git -C "$repo_root" checkout -b "feature/$new_id" "$base_branch" >/dev/null 2>&1; then
      _rollback
      echo "ERROR: failed to create branch feature/$new_id" >&2
      exit 1
    fi

    echo "$new_id"
  ) 200>"$lock"
  rc=$?

  return "$rc"
}
