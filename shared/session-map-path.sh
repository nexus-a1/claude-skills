#!/bin/bash
# session-map-path.sh — where the redaction session map lives.
#
# Also provides nexus_main_checkout, the repository-identity helper the task
# store (shared/tasks/tasks.sh) uses to name a project the same way from its
# checkout and every linked worktree.
#
# `redact-output.sh` assigns a placeholder and writes the pair into the map;
# `reverse-substitute.sh` reads that map back to turn the placeholder into the
# value again. The two must land on the SAME FILE for the same repository, and
# every number in that file must mean exactly one value, or the model is handed
# an identifier that quietly means two things.
#
# WHY THIS IS A SHARED FILE RATHER THAN TEN LINES IN EACH HOOK
#
# It was ten lines in each hook, and both said `git rev-parse --show-toplevel`.
# For a LINKED WORKTREE that answers with the worktree's own path, not the main
# checkout's, so every worktree of one repository got its own map and its own
# independently numbered placeholder sequence. The Bash tool's working
# directory persists between calls, so a single session moves between worktrees
# freely — and this repository's own documented workflow is one worktree per
# ticket, several open at once. `<REDACTED:env-secret:1>` then meant one value
# while the session sat in the first worktree and a different value once it had
# `cd`-ed to the second, with `reverse-substitute` resolving it against
# whichever map matched the current root. Reproduced end to end in
# tests/hooks/redact-output.test and tests/hooks/reverse-substitute.test.
#
# So the map is keyed on the REPOSITORY, via `git rev-parse --git-common-dir`,
# which every linked worktree of one repository answers identically. It still
# lives at `<main checkout>/.claude/session-state/`: the map's defences are all
# keyed on that path — the `read-guard` deny entry in credential-patterns.sh,
# the `.gitignore` of `*` written beside it, mode 0600 — and moving the file
# would have silently taken every one of them off it.
#
# THE TRADEOFF THAT WAS ACCEPTED. One map per repository holds more than one
# map per worktree did: every secret the session saw in any worktree, in clear,
# in a single plaintext file. That is deliberate. The alternative — leaving the
# maps split and making the collision visible instead — leaves a placeholder
# the model legitimately saw unresolvable from a sibling worktree, which is the
# one thing reverse-substitute exists to do. In practice the worktrees of one
# repository are checkouts of the same project reading the same `.env`, so the
# set of values barely widens; what widens is the number of sessions writing
# into one file. See "Also worth noting" in CL-110.

# The main checkout of the repository containing <dir> (default: the current
# directory), printed as an absolute path. Every linked worktree of a
# repository answers with the same one. Also used by the task store, to name a
# project the same way from its checkout and from each of its worktrees.
#
# Returns 1 when <dir> is not inside a repository, and 2 when it is but the main
# checkout cannot be confirmed (a `--separate-git-dir` or bare repository, or a
# submodule, whose git directory does not sit inside a checkout of its own).
nexus_main_checkout() {
    local dir="${1:-.}" root common main

    root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$root" ] || return 1

    # --git-common-dir is the ONE directory every linked worktree of a
    # repository shares. It answers relative to the directory git ran in
    # (".git" in the main checkout, "../.git" one level down) and absolutely
    # from a linked worktree, so resolve it rather than trusting its shape.
    common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null || true)"
    [ -n "$common" ] && common="$(cd "$dir" 2>/dev/null && cd "$common" 2>/dev/null && pwd -P || true)"
    [ -n "$common" ] || return 2

    # The main checkout is the parent of its own .git. That holds for an
    # ordinary repository and not for `--separate-git-dir` or a bare one, so it
    # is checked rather than assumed: a parent that does not carry a `.git` of
    # its own is not the main worktree.
    main="${common%/*}"
    [ -n "$main" ] || main="/"
    [ -d "$main" ] && [ -e "$main/.git" ] || return 2
    # Same directory reached by two spellings (a symlinked path, say): keep the
    # one `--show-toplevel` gave, so an answer does not move under a caller that
    # is already using it.
    if [ "$main" -ef "$root" ] 2>/dev/null; then main="$root"; fi
    printf '%s' "$main"
}

# Absolute path of the directory the session map and its audit log belong in,
# for the repository containing the current working directory. Outside a
# repository: a subdirectory of the user's own ~/.claude — that subdirectory
# and never ~/.claude itself, because the `*` .gitignore written beside the map
# would otherwise ignore the whole config directory.
#
# Prints the directory; never creates it. Callers create it with the umask and
# the .gitignore they need.
nexus_redaction_state_dir() {
    local root main

    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$root" ]; then
        printf '%s' "${HOME:-/tmp}/.claude/session-state"
        return 0
    fi

    # The fallback, when the main checkout cannot be confirmed, is the
    # per-worktree behaviour this file exists to replace — narrower than
    # correct, never wider.
    if main="$(nexus_main_checkout .)"; then
        printf '%s' "$main/.claude/session-state"
        return 0
    fi

    printf '%s' "$root/.claude/session-state"
}
