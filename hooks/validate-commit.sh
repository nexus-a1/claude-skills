#!/bin/bash
# Hook: Validate git commit messages contain a ticket number
# Pattern: PROJ-123, ABC-1, etc.

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → keep safety hooks (validate-commit is safety)
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="validate-commit"; _nexus_class="safety"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && { echo "WARN: safety hook $_nexus_name disabled via NEXUS_HOOK_PROFILE=off — commit validation inactive" >&2; exit 0; }
# safety hooks are NOT disabled by "minimal" — only "off" reaches them
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) echo "WARN: safety hook $_nexus_name disabled via NEXUS_DISABLED_HOOKS — commit validation inactive" >&2; exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

# The payload arrives as JSON on stdin. This hook read an environment variable
# that Claude Code never sets, so the test below never matched and no commit
# message was ever validated. See hook-input.sh;
# bash-token-filter.py is the reference implementation.
# shellcheck source=hook-input.sh
# ${BASH_SOURCE[0]%/*}, not $(dirname …): dirname is an external command, and a
# safety hook that needs PATH to find its own contract can be turned off by
# PATH. Parameter expansion needs nothing.
. "${BASH_SOURCE[0]%/*}/hook-input.sh" || {
    echo "BLOCKED: validate-commit could not load its input contract (hooks/hook-input.sh)." >&2
    exit 2
}
# The file existing is not the same as the contract being loaded: a truncated
# or partially written hook-input.sh sources without error and leaves the
# function undefined, which is command-not-found — status 127, and then rc 0
# from the hook. Fail closed on that too.
#
# Two guards, either of which suffices: the `type` check names the problem, and
# the `|| exit 2` catches the 127. Measured — removing either one alone changes
# no outcome, and only removing BOTH fails the test. Keep both; do not delete
# one on the grounds that the suite still passes.
type hook_read_input >/dev/null 2>&1 || {
    echo "BLOCKED: validate-commit loaded hooks/hook-input.sh but hook_read_input is not defined." >&2
    echo "The contract file is present but incomplete. Refusing to run unguarded." >&2
    exit 2
}
hook_read_input "$_nexus_name" || exit 2

COMMIT_CMD="${HOOK_COMMAND:-}"

# Only validate if this is a git commit command
if [[ "$COMMIT_CMD" =~ git[[:space:]]+commit ]]; then
    # Store HEREDOC pattern in variable for portable newline matching across bash versions
    # [^\n]* before the newline, not `.*`: `.` matches a newline here, and the
    # greedy form ran to the LAST newline in the command and captured `)"` as
    # the message. So even the branch meant to read a heredoc read the wrong
    # line — the check has never once looked at a real commit subject.
    HEREDOC_PATTERN=$'cat[[:space:]]+<<[^\n]*\n([^\n]+)'

    # The heredoc form is read ONLY when it is the -m argument, and it is tried
    # before the quoted branch. Two separate defects meet here.
    #
    # Order: the quoted -m branch matches `-m "$(cat <<'` and captures
    # `$(cat <<` as the message, so every quoted-heredoc commit was rejected for
    # lacking a ticket it never looked for — the exact shape /commit emits.
    #
    # Binding: matching any `cat <<` in the command let an UNRELATED heredoc
    # decide. `git commit -m "no ticket" && cat <<EOF > notes` passed when the
    # notes began with a ticket, and `git commit -m "[X-1] ok" && cat <<EOF`
    # was BLOCKED when they did not — the hook was reading the wrong document
    # in both directions.
    if [[ "$COMMIT_CMD" =~ (^|[[:space:]])(-[a-zA-Z]*m|--message)[=[:space:]]+\"?\$\(cat[[:space:]]+\<\< ]] \
       && [[ "$COMMIT_CMD" =~ $HEREDOC_PATTERN ]]; then
        MESSAGE="${BASH_REMATCH[1]}"
    # Quoted -m. A captured value beginning with a command substitution is not a
    # message this hook can read — `-m "$(gen-msg)"` produces its text at run
    # time. Claiming it lacks a ticket would block a commit on the strength of
    # something never inspected, so it is allowed, like the no-flag case.
    # `-[a-zA-Z]*m`, not a bare `-m`: `git commit -am "…"` is an ordinary form and
    # a literal `-m` does not occur in it, so a ticket-less `-am` commit passed
    # unchecked while the same message under `-m` was blocked. `--message` too.
    elif [[ "$COMMIT_CMD" =~ (^|[[:space:]])(-[a-zA-Z]*m|--message)[=[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
        MESSAGE="${BASH_REMATCH[3]}"
        case "$MESSAGE" in
            '$('*|'`'*)
                # Visible, not silent: this is a skip any caller can invoke with
                # `-m "$(echo wip)"`, so it should appear rather than look like
                # a pass.
                echo "WARN: commit message is produced at run time and cannot be checked for a ticket." >&2
                exit 0 ;;
        esac
    elif [[ "$COMMIT_CMD" =~ (^|[[:space:]])(-[a-zA-Z]*m|--message)[=[:space:]]+([^[:space:]]+) ]]; then
        MESSAGE="${BASH_REMATCH[3]}"
    else
        # No -m flag found, allow (might be interactive or amend)
        exit 0
    fi

    # Trim leading whitespace from message
    MESSAGE="${MESSAGE#"${MESSAGE%%[![:space:]]*}"}"

    # Check for ticket pattern (e.g., PROJ-123, ABC-1)
    if [[ ! "$MESSAGE" =~ [A-Z]+-[0-9]+ ]]; then
        # stderr: on a blocking exit the model never sees stdout, so a message
        # written there is a block with no stated reason.
        echo "BLOCKED: Commit message must contain a ticket number (e.g., PROJ-123)" >&2
        echo "Message: $MESSAGE" >&2
        exit 2
    fi
fi

exit 0
