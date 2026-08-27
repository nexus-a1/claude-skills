#!/bin/bash
# report-path.sh
# Resolve where a /pr-review report (or its gate-approval ledger) is written,
# and verify that location is actually excluded from version control in THIS
# project before anything is written to it.
#
# Why the verification exists. The report reproduces diff excerpts as evidence,
# so it can contain a secret a contributor accidentally committed. The natural
# home, .claude/session-state/, is gitignored in the plugin's own development
# repository — and nowhere else by default. Nothing in the shipped plugin
# creates that entry in a user's project. Writing there on the strength of "it
# is ignored where we developed it" would put diff-derived secrets on a
# commit-eligible path in every other install.
#
# The same check gates the approval ledger, for a different reason: a committed
# ledger would pre-approve gate-command execution for everyone who clones the
# repository, defeating the per-user approval it exists to enforce.
#
# Usage:
#   source /path/to/report-path.sh
#   path=$(resolve_report_path pr 123)          # remote review of PR #123
#   path=$(resolve_report_path branch feat/x)   # local review of a branch
#   ledger=$(resolve_ledger_path)
#
# Exit / return:
#   0 — path emitted on stdout, and its directory is verified excluded
#   1 — the directory is NOT excluded; nothing is emitted, guidance on stderr
#   2 — usage error, or not inside a git repository

set -u

REPORT_SUBDIR=".claude/session-state/pr-review"

# Absolute path of the directory reports live in for the current repository.
_report_dir() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null) || return 2
    [[ -n "$root" ]] || return 2
    printf '%s/%s\n' "$root" "$REPORT_SUBDIR"
}

# Is the report directory excluded from version control here?
#
# `git check-ignore` answers for paths that do not exist yet, which is the
# normal case on a first run — so this deliberately does not create the
# directory first. Creating it would be a side effect performed before we know
# whether we are allowed to write there at all.
#
# Returns 0 when excluded, 1 when tracked/committable, 2 when not in a repo.
verify_report_dir_excluded() {
    local dir
    dir=$(_report_dir) || return 2
    git check-ignore -q "$dir" 2>/dev/null
}

# Emit remediation the user can act on, rather than a bare refusal.
_explain_not_excluded() {
    local dir="$1"
    cat >&2 <<EOF
pr-review: refusing to write a review report to a path that is not excluded
           from version control.

  Path:   $dir
  Reason: the report quotes lines from the diff as evidence. On a tracked path
          those excerpts become commit-eligible, so a secret that appears in a
          diff can be committed a second time by whoever runs the next
          'git add'.

  Fix:    add this line to .gitignore, then re-run:

              .claude/session-state/

          That directory is already used for local, per-repository state and is
          not intended to be shared.
EOF
}

# resolve_report_path <pr|branch> <identifier>
#
# The path is a pure function of (target, head commit): re-reviewing the same
# PR after a push writes a new file rather than overwriting the previous one,
# so two reviews of two different commits can never collide.
resolve_report_path() {
    local mode="${1-}" ident="${2-}"

    if [[ -z "$mode" || -z "$ident" ]]; then
        echo "Usage: resolve_report_path <pr|branch> <identifier>" >&2
        return 2
    fi

    local dir
    dir=$(_report_dir) || { echo "pr-review: not inside a git repository" >&2; return 2; }

    if ! verify_report_dir_excluded; then
        _explain_not_excluded "$dir"
        return 1
    fi

    local sha
    sha=$(git rev-parse --short HEAD 2>/dev/null) || {
        echo "pr-review: cannot resolve HEAD" >&2
        return 2
    }

    local base
    case "$mode" in
        pr)
            if [[ ! "$ident" =~ ^[0-9]+$ ]]; then
                echo "pr-review: PR identifier must be numeric, got '$ident'" >&2
                return 2
            fi
            base="pr-${ident}-${sha}"
            ;;
        branch)
            # Branch names carry '/' and other characters that cannot appear in
            # a filename. Collapse anything outside [A-Za-z0-9._-] to '-' so the
            # result is a single path segment.
            local slug="${ident//[^A-Za-z0-9._-]/-}"
            slug="${slug##-}"
            [[ -n "$slug" ]] || slug="branch"
            base="${slug}-${sha}"
            ;;
        *)
            echo "pr-review: unknown mode '$mode' (expected 'pr' or 'branch')" >&2
            return 2
            ;;
    esac

    printf '%s/%s.md\n' "$dir" "$base"
}

# Where the gate-command approval ledger lives. Same directory, same exclusion
# requirement, and deliberately NOT keyed by commit — approval is per project
# and must persist across commits, or it would re-prompt on every review.
resolve_ledger_path() {
    local dir
    dir=$(_report_dir) || { echo "pr-review: not inside a git repository" >&2; return 2; }

    if ! verify_report_dir_excluded; then
        _explain_not_excluded "$dir"
        return 1
    fi

    printf '%s/gates.accepted\n' "$dir"
}
