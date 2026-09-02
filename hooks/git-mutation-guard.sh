#!/bin/bash
# PreToolUse Hook: Enforce git-mutation policy directly on Bash commands.
#
# Policy (enforced regardless of caller):
#   1. Block pushes to protected branches (main, master, release/*).
#   2. Scan staged files for credentials before every commit.
#   3. Block push unless security-auditor confirmed the current HEAD
#      (state file at .claude/session-state/git-audit.json).
#
# Explicit bypasses (logged to stderr, never silent):
#   GIT_AUTHORIZED=1             — legacy bypass. Skips ALL checks below.
#                                  Kept for backward compatibility with existing
#                                  git-operator callers and release skills.
#   SECURITY_AUDITOR_BYPASS=1    — skip only the security-auditor state check
#                                  (branch protection + credential scan still run).
#   NEXUS_KB_WRITE=1             — skip only branch protection (credential scan
#                                  + security-auditor state check still run).
#                                  For the sanctioned git-backed knowledge-base
#                                  write pattern: KB repos (requirements,
#                                  product-knowledge) are separate git remotes
#                                  with no PR/review process of their own, so a
#                                  direct push to their default branch is the
#                                  intended workflow, not a bypass of *this*
#                                  project's review requirement. Set this only
#                                  immediately before the push step, never for
#                                  pushes to the project's own repo.
#
# Scope: this guard only inspects Bash tool calls. Other tools are untouched.

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → keep safety hooks (git-mutation-guard is safety)
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="git-mutation-guard"; _nexus_class="safety"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && { echo "WARN: safety hook $_nexus_name disabled via NEXUS_HOOK_PROFILE=off — git mutation guard inactive" >&2; exit 0; }
# safety hooks are NOT disabled by "minimal" — only "off" reaches them
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) echo "WARN: safety hook $_nexus_name disabled via NEXUS_DISABLED_HOOKS — git mutation guard inactive" >&2; exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

set -u

# The payload arrives as JSON on stdin. This hook read an environment variable
# Claude Code never sets, so `input` was always empty, the git check below never
# matched, and every policy here was inert. See hook-input.sh for the full
# account; bash-token-filter.py in this same PreToolUse block is the reference
# implementation.
# shellcheck source=hook-input.sh
# ${BASH_SOURCE[0]%/*}, not $(dirname …): dirname is an external command, and a
# safety hook that needs PATH to find its own contract can be turned off by
# PATH. Parameter expansion needs nothing.
. "${BASH_SOURCE[0]%/*}/hook-input.sh" || {
    echo "BLOCKED: git-mutation-guard could not load its input contract (hooks/hook-input.sh)." >&2
    echo "Refusing to run unguarded." >&2
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
    echo "BLOCKED: git-mutation-guard loaded hooks/hook-input.sh but hook_read_input is not defined." >&2
    echo "The contract file is present but incomplete. Refusing to run unguarded." >&2
    exit 2
}
hook_read_input "$_nexus_name" || exit 2

input="${HOOK_COMMAND:-}"

# BEFORE the fast exit below, which requires `git` to follow whitespace or start
# the string. In `bash -c "git push"` the character before `git` is a quote, so
# the fast exit fired and the refusal was never reached — the one shape that
# most needs refusing looked like "not a git command".
#
# A shell inside a string still runs, and blanking quoted runs would hide the
# verb from every check below. Refuse rather than guess: an unreadable mutation
# is not an absent one.
if hook_has_shell_in_string "$input"; then
    echo "BLOCKED: a git commit/push inside a shell string (bash -c \"…\" or eval) cannot be inspected." >&2
    echo "Run the git command directly so the guard can see it — branch protection, the credential" >&2
    echo "scan and the audit gate all read the command text." >&2
    exit 2
fi

# Fast exit: no mention of git at all.
#
# A plain substring test, deliberately. The old form required `git` to follow
# whitespace or start the string, which is false for `(git push)`, `$(git push)`
# and `/usr/bin/git push` — all of which the segmenter finds, and all of which
# exited here before it ever ran. This test exists to skip work on unrelated
# commands, so it should err toward doing the work: `digit` costs one wasted
# segmentation pass and nothing else, while a missed shape is an unguarded push.
case "$input" in
    *git*) : ;;
    *) exit 0 ;;
esac

# Legacy bypass — keep commands issued by existing git-operator callers and
# the release skills working without rewriting every caller at once.
# GIT_AUTHORIZED is read PER SEGMENT and skips only that segment.
#
# It used to set one flag and `exit 0` for the whole command, so
# `GIT_AUTHORIZED=1 git commit -m x && git push origin master` ran the push with
# no branch protection, no audit gate and no scan — one segment vouching for
# another, which is the precise failure this whole change exists to remove. It
# appeared here, in the fix for it.


# A git mutation the segmenter could not attribute to a command it understands —
# `nice git push`, `timeout 5 git push`, and whatever wrapper comes next.
# Enumerating wrappers is a losing game and each one missed is an unguarded
# push, so the guard refuses what it cannot read instead of allowing it.
# Quotes spliced into the verb — `"git" push`, `g'i't push` — are ordinary shell
# that runs git, but blanking quoted runs erases the word, so neither the
# segmenter nor the residue check sees it.
if hook_has_spliced_verb "$input"; then
    echo "BLOCKED: this command splices quotes into a git verb, which the guard cannot read." >&2
    echo "Write the command without the embedded quotes so branch protection, the credential scan" >&2
    echo "and the audit gate can see what it does." >&2
    exit 2
fi

if hook_unmatched_git_verb "$input"; then
    echo "BLOCKED: this command contains a git commit/push the guard cannot attribute to a command it understands." >&2
    echo "That usually means a wrapper (nice, timeout, xargs, nohup) in front of git. Run the git command" >&2
    echo "directly so branch protection, the credential scan and the audit gate can read it." >&2
    exit 2
fi

# Every occurrence, each gated on its own terms. The checks were anchored at the
# start of the command, so `echo hi && git push` and `cd /tmp && git push` were
# ungated entirely — a guard against the shapes our own prompts use rather than
# against what a model composes.
# EVERY segment, not the first of each kind. Keeping only the first meant its
# declarations gated the whole command: `NEXUS_KB_WRITE=1 git push kb main &&
# git push origin master` skipped branch protection for the SECOND push, a
# direct push to a protected branch on the strength of a bypass that applied to
# a different remote.
# Each segment carries the directory its git will run in (NX-61). A hook runs
# in the session's working directory, so a command that moves first -- and the
# worktree-per-ticket workflow is nothing but such commands -- was gated
# against the directory it started in rather than the repository it writes to.
push_segments=()
push_dirs=()
commit_segments=()
commit_dirs=()
while IFS=$'\t' read -r _class _wd _seg; do
    case "$_class" in
        push)
            # A segment carrying the legacy full bypass is skipped, and only it.
            hook_declares "$_seg" GIT_AUTHORIZED || { push_segments+=("$_seg"); push_dirs+=("$_wd"); } ;;
        commit)
            hook_declares "$_seg" GIT_AUTHORIZED || { commit_segments+=("$_seg"); commit_dirs+=("$_wd"); } ;;
        exempt) ;;      # --help, or a dry-run push: looked at, nothing to gate
        unreadable) ;;  # refused above, before this loop runs
        *)  # A class this loop does not know. Dropping it silently is how a
            # later addition to the segmenter would arrive ungated.
            echo "BLOCKED: git-mutation-guard saw a segment class it does not handle: $_class" >&2
            exit 2 ;;
    esac
done < <(hook_git_segments "$input")

# A directory change the segmenter could see but not read. Refusing is not
# caution for its own sake: the alternative is asking the hook's own cwd about
# a branch, a HEAD and an audit record that belong to some other repository,
# and then answering confidently. That is the NX-61 bug, and it fails in both
# directions -- it blocked every legitimate worktree push, and it would just as
# readily approve a push to master because the directory it asked was not the
# one being written to.
_refuse_unreadable_dir() {
    echo "BLOCKED: git-mutation-guard cannot tell which repository this $1 is for." >&2
    echo "The command changes directory in a way the guard cannot follow (a quoted or" >&2
    echo "variable path, or --git-dir/--work-tree). Use an unquoted path, or address the" >&2
    echo "repository with 'git -C <dir> $1 ...', so branch protection and the audit gate" >&2
    echo "read the repository you are actually writing to." >&2
    exit 2
}

# ---------------------------------------------------------------------------
# 1. Branch protection + security-auditor gate on push
# ---------------------------------------------------------------------------
_i=0
for push_segment in ${push_segments[@]+"${push_segments[@]}"}; do
    push_dir="${push_dirs[$_i]}"
    _i=$(( _i + 1 ))
    [ "$push_dir" = "?" ] && _refuse_unreadable_dir push
    # Every question below is asked of the repository being pushed, not of the
    # directory the hook happens to be standing in.
    current_branch=$(git -C "$push_dir" branch --show-current 2>/dev/null || true)
    repo_root=$(git -C "$push_dir" rev-parse --show-toplevel 2>/dev/null || true)
    # The declaration must lead the SEGMENT whose verb it precedes, and each
    # segment is judged on its own — a bypass on one push does not license
    # another push in the same command.
    if hook_declares "$push_segment" NEXUS_KB_WRITE; then
        echo "WARN: NEXUS_KB_WRITE=1 — skipping branch-protection check (sanctioned direct-to-trunk push to a git-backed KB repo, not this project). Credential scan and security-auditor state check still apply." >&2
    else
        case "$current_branch" in
            main|master|release/*)
                # Allow the initial creating push (remote branch doesn't exist yet).
                # Subsequent pushes to an existing protected branch must go through a PR.
                if git -C "$push_dir" ls-remote --exit-code --heads origin "$current_branch" >/dev/null 2>&1; then
                    echo "BLOCKED: direct push to protected branch '$current_branch'." >&2
                    echo "Remote branch already exists — subsequent changes must go through a PR." >&2
                    echo "Pushing to a git-backed knowledge-base repo (not this project)? Prefix with NEXUS_KB_WRITE=1." >&2
                    exit 2
                fi
                ;;
        esac
    fi

    if ! hook_declares "$push_segment" SECURITY_AUDITOR_BYPASS; then
        state_file="$repo_root/.claude/session-state/git-audit.json"
        head_sha=$(git -C "$push_dir" rev-parse HEAD 2>/dev/null || true)
        # Resolved from this script's own location rather than named as
        # ${CLAUDE_PLUGIN_ROOT}: the variable may be unset in the shell reading
        # this message, and a path that prints empty is worse than no path.
        # Same reasoning as the hook-input.sh source at the top of this file.
        audit_script="${BASH_SOURCE[0]%/*}/record-audit.sh"
        # ...and anchored to the repository being PUSHED, not the one the reader
        # happens to be standing in. record-audit.sh resolves its target with a
        # bare `git rev-parse --show-toplevel` (no -C), so a reader pushing a
        # linked worktree from the main checkout would stamp the main checkout
        # while the gate reads "$repo_root" -- the push stays blocked after doing
        # exactly what the message said, AND a passing record is written for a
        # HEAD nobody audited, which can clear a later push from there. Found by
        # review of this ticket's own change: naming the command is what made
        # that reachable, since before it no command was named at all. The
        # worktree-per-ticket shape it breaks is this repo's house convention
        # (CLAUDE.md, "Jira Ticket Workflow") and a supported guard path (NX-61).
        if [ -n "$repo_root" ]; then
            audit_cmd="(cd \"$repo_root\" && bash \"$audit_script\")"
        else
            # repo_root is set with `|| true` above, so it can be empty. `cd ""`
            # succeeds and stays put, which would silently reintroduce the very
            # wrong-directory bug this branch exists to avoid.
            audit_cmd="bash \"$audit_script\""
        fi
        if [[ ! -f "$state_file" ]]; then
            # CL-78: name the script that actually writes the file. This message
            # used to say only "run the security-auditor agent", which does not
            # and cannot produce it -- that agent is declared Read/Grep/Glob, so
            # it has no way to write anything. An agent following the old text
            # literally ran the audit, saw no file appear, and was left to
            # improvise; at least one improvised by forging the state file by
            # hand. Both halves have to be named, and the second is the one that
            # clears the gate.
            echo "BLOCKED: push requires a recorded security audit for this HEAD." >&2
            echo "Two steps -- the second is the one that unblocks the push:" >&2
            echo "  1. Run the security-auditor agent on the committed changes." >&2
            echo "  2. Record the result:  $audit_cmd" >&2
            echo "Step 1 alone writes nothing (the agent has no Write tool); step 2 writes the file." >&2
            echo "State file expected at: $state_file" >&2
            exit 2
        fi
        recorded_sha=$(grep -o '"head_sha": *"[^"]*"' "$state_file" | grep -o '[^"]*"$' | tr -d '"' 2>/dev/null || true)
        recorded_branch=$(grep -o '"branch": *"[^"]*"' "$state_file" | grep -o '[^"]*"$' | tr -d '"' 2>/dev/null || true)
        if [[ "$recorded_sha" != "$head_sha" || "$recorded_branch" != "$current_branch" ]]; then
            echo "BLOCKED: the recorded security audit is stale — it does not match this HEAD." >&2
            echo "  Audited: ${recorded_branch:-<unknown>} @ ${recorded_sha:-<unknown>}" >&2
            echo "  Current: $current_branch @ $head_sha" >&2
            # Same CL-78 fix as above: re-running the agent alone leaves the
            # stale record in place, so the push stays blocked. Naming the
            # HEAD-keying here too, because this is the branch that fires after
            # an amend or an added commit, and that is exactly when it reads as
            # a bug rather than as the intended invalidation.
            echo "Re-audit the current HEAD, then re-record it:  $audit_cmd" >&2
            echo "The record is keyed to HEAD, so any amend, rebase or new commit invalidates it." >&2
            exit 2
        fi
    else
        echo "WARN: SECURITY_AUDITOR_BYPASS=1 — skipping audit state check." >&2
    fi
done

# ---------------------------------------------------------------------------
# 2. Credential scan on commit
# ---------------------------------------------------------------------------
# The staged set is a property of the REPOSITORY, not of a segment -- so it is
# collected per repository and then reused. Two commits in one command used to
# run the scanner twice over an identical file list and print every finding
# twice; but two commits in one command can now be two different repositories,
# and collecting once for all of them scanned the wrong tree for the second
# (NX-61). `_scanned_dirs` keeps both properties: one scan per repository, and
# no repository skipped.
_scanned_dirs=""
_j=0
for commit_segment in ${commit_segments[@]+"${commit_segments[@]}"}; do
    commit_dir="${commit_dirs[$_j]}"
    _j=$(( _j + 1 ))
    [ "$commit_dir" = "?" ] && _refuse_unreadable_dir commit
    case "$_scanned_dirs" in
        *"|$commit_dir|"*) continue ;;   # this repository is already scanned
    esac
    _scanned_dirs="$_scanned_dirs|$commit_dir|"
    repo_root=$(git -C "$commit_dir" rev-parse --show-toplevel 2>/dev/null || true)
    staged=()
    while IFS= read -r _f; do [ -n "$_f" ] && staged+=("$_f"); done \
        < <(git -C "$commit_dir" diff --cached --name-only --diff-filter=ACM 2>/dev/null)
    # `while read`, not mapfile. mapfile does not exist in bash 3.2, which is
    # still /bin/bash on macOS — and there the array expansion below would abort
    # under `set -u` with exit 1, a status Claude Code does not treat as a block.
    # The credential scan would have failed OPEN on that platform even once the
    # hook could read its input again. Pre-existing, and invisible until now
    # because the hook never got this far.
    extra=()
    # `git commit -a` / `--all` also stages all modified tracked files.
    if [[ "$commit_segment" =~ git[[:space:]]+commit[[:space:]]+(-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|$) ]]; then
        while IFS= read -r _f; do [ -n "$_f" ] && extra+=("$_f"); done \
            < <(git -C "$commit_dir" diff --name-only --diff-filter=ACM 2>/dev/null)
    fi
    targets=()
    # ${arr[@]+"${arr[@]}"}: bash < 4.4 — macOS /bin/bash 3.2 — treats expansion
    # of an EMPTY array as unbound under `set -u`. A commit without -a leaves
    # `extra` empty, so this line aborted with exit 1, which is not a block, and
    # the credential scan never ran. The same silent fail-open this branch
    # exists to close, one level down and only on the platform CI does not run.
    for f in ${staged[@]+"${staged[@]}"} ${extra[@]+"${extra[@]}"}; do
        [[ -n "$f" && -f "$repo_root/$f" ]] && targets+=("$repo_root/$f")
    done

    if (( ${#targets[@]} > 0 )); then
        # ${BASH_SOURCE[0]%/*}, not $(dirname "$0"): dirname is external, so a
        # PATH without it made this empty and the scanner path `/credential-scan.sh`.
        scanner="${BASH_SOURCE[0]%/*}/credential-scan.sh"
        # No `if [[ -x ]]` without an else. That form allowed the commit with no
        # scan and no message whenever the scanner was missing or lost its exec
        # bit — including after a marketplace sync that does not preserve modes.
        # A scan that cannot run is not a scan that passed.
        if [[ ! -x "$scanner" ]]; then
            echo "BLOCKED: credential scanner not found or not executable at $scanner." >&2
            echo "Refusing to commit unscanned. Check the plugin installation, or disable" >&2
            echo "this hook explicitly with NEXUS_DISABLED_HOOKS=git-mutation-guard." >&2
            exit 2
        fi
        if ! "$scanner" "${targets[@]}" >&2; then
            echo "BLOCKED: credential-scan findings above. Commit refused." >&2
            echo "Resolve the finding, or use GIT_AUTHORIZED=1 git commit … to bypass all checks (legacy; document the reason in the commit body)." >&2
            exit 2
        fi
    fi
done

exit 0
