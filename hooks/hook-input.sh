#!/bin/bash
# Shared input contract for the shell hooks under plugin/hooks/.
#
# WHY THIS EXISTS
#
# Claude Code delivers a hook's payload as JSON on STDIN. It does NOT export the
# tool call into the environment: the only CLAUDE_* variables a hook receives are
# CLAUDE_PROJECT_DIR, CLAUDE_PLUGIN_ROOT, CLAUDE_PLUGIN_DATA and CLAUDE_EFFORT.
# There is no CLAUDE_TOOL_INPUT and no CLAUDE_TOOL_NAME.
#
# git-mutation-guard.sh and validate-commit.sh read `${CLAUDE_TOOL_INPUT:-}` and
# therefore saw an empty string in every real installation. Both begin by
# checking whether the command looks like a git command; an empty string does
# not, so both exited 0 immediately. Branch protection, the credential scan and
# the security-auditor push gate have all been inert — failing OPEN, silently,
# with a green test suite, because the tests set the variable themselves and so
# only ever exercised an interface that does not exist.
#
# bash-token-filter.py in the same PreToolUse block has always read stdin JSON
# correctly. It is the reference implementation; this file is its shell
# equivalent, and new hooks should copy one or the other rather than invent a
# third way.
#
# FAIL CLOSED
#
# A guard that cannot read its input must not wave the command through — that is
# precisely the failure being fixed. If the payload is missing or unparseable,
# hook_read_input aborts the hook with exit 2 (block) and says why. The escape
# hatch is the existing kill-switch, which is explicit and logged:
#   NEXUS_DISABLED_HOOKS=git-mutation-guard   or   NEXUS_HOOK_PROFILE=off

# hook_read_input — populates HOOK_TOOL_NAME, HOOK_COMMAND, HOOK_SESSION_ID.
#
# Call it once, at the top of a hook, AFTER the kill-switch block so a disabled
# hook stays disabled even when the payload is unreadable.
#
# SAFETY hooks call it plainly: an unreadable payload aborts with exit 2, which
# blocks the tool call. That is the point — a guard that cannot see the command
# must not approve it.
#
# ADVISORY hooks (audit, notify) pass 1 as the SECOND ARGUMENT and get a
# non-zero RETURN instead. Not an environment variable: read from the
# environment it would be an undocumented, unlogged kill-switch. An advisory hook has nothing to enforce, so blocking a user's
# command because a log line could not be labelled would be a worse bug than the
# missing label. Such a hook must then say the value is missing rather than
# invent one — writing "unknown" is how the audit log stayed full and useless.
hook_read_input() {
    local raw name
    # Second ARGUMENT, deliberately not an environment variable. Read from the
    # environment it would be an undocumented, unlogged kill-switch: anything
    # that happened to export HOOK_ALLOW_DEGRADED=1 would turn both safety hooks
    # into no-ops with no WARN, which is the failure this whole change exists to
    # remove. NEXUS_DISABLED_HOOKS is the supported off switch and it announces
    # itself.
    local degraded="${2:-0}"


    # `read -d ''` rather than `$(cat)`: cat is external, and a hook that needs
    # PATH to read its own stdin can be silenced by PATH. -d '' reads to NUL,
    # which a JSON payload does not contain, so it consumes everything and
    # returns non-zero at EOF — expected, hence the `|| true`.
    IFS= read -r -d '' raw || true

    if [ -z "$raw" ]; then
        echo "BLOCKED: ${1:-hook} received no input on stdin." >&2
        echo "Claude Code delivers the tool call as JSON on stdin. Getting nothing means the hook" >&2
        echo "is wired wrongly or invoked outside Claude Code. Refusing to run unguarded." >&2
        [ "$degraded" = "1" ] && return 1
        exit 2
    fi

    # AFTER the empty-stdin check, deliberately. Run before it, a hidden jq
    # plus an empty payload returned 0 — the two failure modes cancelled and the
    # hook waved the command through.
    if ! command -v jq >/dev/null 2>&1; then
        # Without jq the payload can only be matched crudely. If it looks like
        # it carries a git command this hook has something to protect and must
        # block; if not, blocking would stop every unrelated Bash call on a
        # machine without jq, a bigger outage than the risk it removes.
        # The match is against the COMMAND text roughly, not the whole payload:
        # `*git*` over the payload meant a cwd like ~/git/x, or the word
        # "legitimate" in a commit message, blocked everything.
        case "$raw" in
            *'"command"'*git[[:space:]]*) : ;;
            *)  # Reset before returning: these are exported, and a caller that
                # inherited stale values from the environment would otherwise
                # act on them as if this hook had read them.
                HOOK_COMMAND=""; HOOK_TOOL_NAME=""; HOOK_SESSION_ID=""
                export HOOK_COMMAND HOOK_TOOL_NAME HOOK_SESSION_ID
                return 0 ;;
        esac
        echo "BLOCKED: ${1:-hook} requires jq to inspect a git command and jq is not installed." >&2
        echo "Install jq, or disable this hook explicitly: NEXUS_DISABLED_HOOKS=${1:-hook}" >&2
        echo "Refusing to run unguarded — a guard that cannot read its input must not allow the command." >&2
        [ "$degraded" = "1" ] && return 1
        exit 2
    fi
    if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
        echo "BLOCKED: ${1:-hook} could not parse its stdin payload as JSON." >&2
        echo "Refusing to run unguarded." >&2
        [ "$degraded" = "1" ] && return 1
        exit 2
    fi

    # -e and an explicit type check. `{"tool_input":"git push"}` parses as valid
    # JSON, and `.tool_input.command` on a string errors — with the status
    # unchecked that left HOOK_COMMAND empty and the guard allowing everything,
    # which is the same fail-open shape one level down.
    #
    # The `type != "object"` arms are redundant TODAY: measured against a string,
    # null, an array, a bare scalar payload and a missing tool_input, jq errors
    # on its own or the no-command check below catches it, and removing them
    # changes no outcome. They stay because each of those two other defences can
    # be edited away by someone who does not know it was load-bearing, and this
    # says out loud what shape the hook accepts. No mutation test is claimed for
    # them, because none would fail — the behaviour is pinned by the outcome
    # test over all six shapes instead.
    if ! HOOK_COMMAND="$(printf '%s' "$raw" | jq -er '
            if type != "object" then error("payload is not an object")
            elif has("tool_input") and (.tool_input | type) != "object" then error("tool_input is not an object")
            else (.tool_input.command // "") end' 2>/dev/null)"; then
        echo "BLOCKED: ${1:-hook} received a payload it does not understand." >&2
        echo "Refusing to run unguarded." >&2
        [ "$degraded" = "1" ] && return 1
        exit 2
    fi
    HOOK_TOOL_NAME="$(printf '%s' "$raw" | jq -r '.tool_name // ""')"
    # A Bash call with no command is not a call with an empty command — the
    # guard would read that as "not git" and allow it. Refuse instead.
    # Not keyed on tool_name being "Bash": a payload with no tool_name at all
    # would have skipped this and returned an empty command, which the guard
    # reads as "not git". Anything that is not explicitly another tool is
    # treated as something this hook must be able to read.
    if [ -z "$HOOK_COMMAND" ] && [ "$HOOK_TOOL_NAME" != "Edit" ] \
       && [ "$HOOK_TOOL_NAME" != "Write" ] && [ "$HOOK_TOOL_NAME" != "Read" ] \
       && ! printf '%s' "$raw" | jq -e '.tool_input | has("command")' >/dev/null 2>&1; then
        echo "BLOCKED: ${1:-hook} got a Bash payload with no command field." >&2
        echo "Refusing to run unguarded." >&2
        [ "$degraded" = "1" ] && return 1
        exit 2
    fi
    HOOK_SESSION_ID="$(printf '%s' "$raw" | jq -r '.session_id // ""')"

    export HOOK_TOOL_NAME HOOK_SESSION_ID HOOK_COMMAND
    return 0
}

# hook_strip_env_assignments — echo the command with ALL leading VAR=value
# assignments removed, so a policy regex anchored on the verb still matches.
#
# ALL of them, not a known list. The previous code stripped only the three
# bypass names it recognised, so `FOO=1 git push` matched neither the anchored
# `git push` regex nor anything else, and skipped every check — an unguarded
# push available to anyone who prefixed an irrelevant variable. `env FOO=1 git
# push` had the same effect and is stripped here too.
hook_strip_env_assignments() {
    local cmd="$1"
    while :; do
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
        # `env`, including an absolute path and its own options: `env -i`,
        # `env -u FOO`, `/usr/bin/env`. Each of these ran the verb behind a word
        # the anchored regex could not see past.
        if [[ "$cmd" =~ ^(/[^[:space:]]*/)?env[[:space:]]+(.*)$ ]]; then
            cmd="${BASH_REMATCH[2]}"
            # env's own options, including `-u NAME` which takes an argument.
            while :; do
                cmd="${cmd#"${cmd%%[![:space:]]*}"}"
                if [[ "$cmd" =~ ^(-u|--unset)[[:space:]]+[^[:space:]]+[[:space:]]+(.*)$ ]]; then
                    cmd="${BASH_REMATCH[2]}"; continue
                fi
                if [[ "$cmd" =~ ^--?[A-Za-z0-9-]+[[:space:]]+(.*)$ ]]; then
                    cmd="${BASH_REMATCH[1]}"; continue
                fi
                break
            done
            continue
        fi
        # `command git push` and `\git push` both run git while hiding the word
        # from a regex anchored on `git`.
        if [[ "$cmd" =~ ^(command|builtin)[[:space:]]+(.*)$ ]]; then
            cmd="${BASH_REMATCH[2]}"; continue
        fi
        if [[ "$cmd" =~ ^\\(.*)$ ]]; then
            cmd="${BASH_REMATCH[1]}"; continue
        fi
        # A leading assignment. The value may be quoted and may contain spaces:
        # `GIT_SSH_COMMAND="ssh -i k" git push` used to strip to `k" git push …`,
        # which matched nothing and so skipped every check.
        if [[ "$cmd" =~ ^[A-Za-z_][A-Za-z_0-9]*=(\"[^\"]*\"|\'[^\']*\'|[^[:space:]]*)[[:space:]]+(.*)$ ]]; then
            cmd="${BASH_REMATCH[2]}"; continue
        fi
        break
    done
    printf '%s' "$cmd"
}

# hook_declares — true when the command's LEADING assignments set NAME to 1.
#
# Read from the command string, never from the environment. A PreToolUse hook
# runs before the command does, so an assignment written in the command has not
# taken effect anywhere the hook could observe — which is why reading these from
# the environment made the documented bypasses inert. Only leading assignments
# count: that is the only position where the shell would treat it as setting the
# variable for that command, and it is the only position the guard can trust.
hook_declares() {
    local cmd="$1" name="$2"
    while [[ "$cmd" =~ ^[[:space:]]*([A-Za-z_][A-Za-z_0-9]*)=(\"[^\"]*\"|\'[^\']*\'|[^[:space:]]*)[[:space:]]+(.*)$ ]]; do
        local val="${BASH_REMATCH[2]}"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        if [ "${BASH_REMATCH[1]}" = "$name" ] && [ "$val" = "1" ]; then
            return 0
        fi
        cmd="${BASH_REMATCH[3]}"
    done
    return 1
}

# ---------------------------------------------------------------------------
# Finding the git mutations in a command
# ---------------------------------------------------------------------------
#
# The policy regexes used to be anchored at the start of the command, so they
# saw only a LEADING verb. `echo hi && git push` and `cd /tmp && git push` were
# ungated entirely — no branch protection, no credential scan, no audit gate.
# That was tolerable only while the hook was inert; a guard that sees just the
# leading verb is a guard against the shapes our own prompts use, not against
# what a model actually composes.
#
# hook_git_segments prints one line per gated occurrence:
#
#     <verb> <TAB> <segment>
#
# so a caller can gate each one on its own terms — `git commit -m x && git push`
# yields a commit segment AND a push segment, and both get their own checks.

# Remove heredoc BODIES. Text a command writes to a file is not a command; a
# pattern doc containing `git push` in a heredoc must not be read as a push.
hook_strip_heredoc_bodies() {
    awk '
      inhd {
        t = $0
        # `<<-` permits a TAB-indented terminator. Comparing the raw line meant
        # such a heredoc never ended, and every command after it — including a
        # real push — was swallowed as body and never seen.
        if (dash) sub(/^\t+/, "", t)
        if (t == delim) inhd = 0
        next
      }
      {
        line = $0
        # The delimiter need not end the line: `cat <<EOF > doc.md` is ordinary.
        # What may follow is redirects and nothing else — which is what keeps
        # `echo "a << b"` from being read as an opener and swallowing the rest
        # of the command.
        if (match(line, /<<-?[ \t]*"?'"'"'?[A-Za-z_][A-Za-z_0-9]*"?'"'"'?/)) {
          d = substr(line, RSTART, RLENGTH)
          tail = substr(line, RSTART + RLENGTH)
          sub(/^<<-?[ \t]*/, "", d); gsub(/[^A-Za-z_0-9]/, "", d)
          if (d != "" && tail ~ /^([ \t]*[0-9]*[<>]+[ \t]*[^ \t<>]+)*[ \t]*$/) {
            inhd = 1; delim = d
            dash = (substr(line, RSTART, 3) ~ /^<<-/)
          }
        }
        print line
      }
    ' <<< "$1"
}

# A shell inside a string still runs. `bash -c "git push"` hides the verb from
# any scanner that blanks quoted runs, so it is refused outright rather than
# guessed at — an unreadable mutation is not an absent one.
hook_has_shell_in_string() {
    local seg
    # Per segment, and the git verb must be in the SAME one. Checked across the
    # whole input, `bash -c "npm test" && git commit -m x` was refused although
    # the commit is perfectly readable — a hook that blocks ordinary work gets
    # uninstalled, and then it protects nothing at all.
    while IFS= read -r seg; do
        [[ "$seg" =~ (^|[[:space:]\;\&\|\(])${HOOK_PATH_PREFIX}(bash|sh|zsh|ksh)[[:space:]]+-[a-z]*c[[:space:]] ]] || \
        [[ "$seg" =~ (^|[[:space:]\;\&\|\(])eval[[:space:]] ]] || continue
        [[ "$seg" =~ git[[:space:]]+(commit|push) ]] && return 0
    # printf with a trailing newline: without one, `read` returns non-zero on the
    # final (only) line and the loop body never runs at all — the check silently
    # passed everything it was given.
    done < <(printf '%s\n' "$1" | awk '{ gsub(/&&|\|\||[;&|]/, "\n"); print }')
    return 1
}

# The option run git itself accepts before a subcommand: -C <dir>, --git-dir=…,
# -c k=v, --no-pager, and the rest. The old allowlist named three of them, so
# `git --no-pager push` and `git -c user.email=x commit` matched nothing and ran
# ungated. A generic run is the only version that does not need extending every
# time git grows an option.
HOOK_GIT_OPTS='([[:space:]]+(-[A-Za-z]|--[A-Za-z][A-Za-z-]*)(=[^[:space:]]*)?([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'

# An optional absolute path in front of git or a shell: /usr/bin/git push ran
# ungated because the residue check refused to look past a `/`.
HOOK_PATH_PREFIX='(/[^[:space:]]*/)?'

# Strip shell comments in ONE left-to-right pass that tracks quote state.
#
# Two sed passes could not do this. Comments-then-quotes turned
# `git commit -m "[X-1] fix #12" && git push origin master` into
# `git commit -m "[X-1] fix` — everything from the ` #` swallowed, including the
# push, which then had no segment and was completely ungated. A `#123` issue ref
# in a commit message is ordinary, so that is the shape a real user hits first.
#
# Quotes-then-comments is no better: blanking `"…"` first destroys the quote
# characters, so an apostrophe in a genuine trailing comment pairs with a later
# one and eats the text between them.
#
# A `#` only starts a comment when it is outside quotes AND begins a word.
hook_strip_comments() {
    printf '%s\n' "$1" | awk '
      {
        line = $0; out = ""; sq = 0; dq = 0; n = length(line)
        for (i = 1; i <= n; i++) {
          c = substr(line, i, 1)
          if (c == "\047" && !dq) { sq = !sq }
          else if (c == "\"" && !sq) { dq = !dq }
          else if (c == "#" && !sq && !dq) {
            p = (i == 1) ? " " : substr(line, i - 1, 1)
            if (p == " " || p == "\t") break
          }
          out = out c
        }
        print out
      }'
}

hook_preprocess() {
    local c
    c="$(hook_strip_heredoc_bodies "$1")"
    c="$(hook_strip_comments "$c")"
    c="$(printf '%s' "$c" | sed 's/"[^"]*"/""/g')"
    c="$(printf '%s' "$c" | sed "s/'[^']*'//g")"
    printf '%s' "$c"
}

hook_git_segments() {
    local cmd="$1" seg verb rest

    # Non-empty in, empty out means the preprocessing failed — `sed` or `awk`
    # missing or shadowed. Every caller reads "no segments" as "nothing to
    # gate", so that silence is a pass. Emit `unreadable` instead, which the
    # guard refuses. This is the PATH-silencing failure CL-62 removed from the
    # hook's own plumbing, reintroduced by a helper that shells out.
    # A PROBE, not an inference. "Non-empty in, empty out" is also what a command
    # that is entirely comment produces — `# git push` legitimately preprocesses
    # to nothing, and treating that as breakage refused an ordinary comment.
    # So empty output only counts as failure when a string that must survive
    # preprocessing does not.
    if [ -n "$cmd" ] && [ -z "$(hook_preprocess "$cmd")" ] \
       && [ "$(hook_preprocess 'git push')" != "git push" ]; then
        printf 'unreadable\t%s\n' "$cmd"
        return 0
    fi

    cmd="$(hook_strip_heredoc_bodies "$cmd")"
    # Comments, quote-aware. A prompt naming `git push` while explaining it is
    # documentation, not an invocation — but a `#` inside a commit message is
    # neither, and stripping it as a comment took the rest of the command with it.
    cmd="$(hook_strip_comments "$cmd")"
    # Quoted runs become empty. Done AFTER the shell-in-a-string check above, so
    # a hidden verb is refused rather than silently dropped here.
    cmd="$(printf '%s' "$cmd" | sed 's/"[^"]*"/""/g')"
    cmd="$(printf '%s' "$cmd" | sed "s/'[^']*'//g")"
    # Separators — and `(`, `)`, `\$(`, newline — all start a new command.
    # awk, not `sed 's/…/\n/'`: BSD sed (macOS) inserts a literal `n` for that
    # escape, which would join every segment into one line and make every
    # compound check silently useless on a Mac — the platform least likely to be
    # the one anybody ran the suite on.
    # The backtick is in the list because it opens a command substitution:
    # x=`git push origin master` ran with no segment at all, since the leading
    # assignment strip consumed "x=`git" as the value.
    cmd="$(printf '%s' "$cmd" | awk '{ gsub(/&&|\|\||[;&|`]|\$\(|[(){}]/, "\n"); print }')"

    while IFS= read -r seg; do
        # Leading assignments and `env` come off THIS segment, not just the
        # string's start: `true; FOO=1 git push` has its assignment mid-string.
        seg="${seg#"${seg%%[![:space:]]*}"}"
        rest="$(hook_strip_env_assignments "$seg")"
        # `then`/`do`/`else` sit between a separator and the verb.
        rest="$(printf '%s' "$rest" | sed -E 's/^(then|do|else)[[:space:]]+//')"
        rest="$(hook_strip_env_assignments "$rest")"

        # --help is documentation, not a mutation. Emitted as `exempt` rather
        # than skipped silently, so the residue check below can tell "we looked
        # at this and it is fine" from "we could not see it at all".
        if [[ "$rest" =~ (^|[[:space:]])(--help|-h)([[:space:]]|$) ]] \
           && [[ "$rest" =~ ^git([[:space:]]|$) ]]; then
            printf 'exempt\t%s\n' "$seg"; continue
        fi

        # The option forms that never matched an anchored regex either.
        if [[ "$rest" =~ ^${HOOK_PATH_PREFIX}git${HOOK_GIT_OPTS}[[:space:]]+(commit|push)([[:space:]]|$) ]]; then
            # The verb is the last-but-one group; count them from the end rather
            # than by index, since the option run contributes several.
            verb="${BASH_REMATCH[${#BASH_REMATCH[@]}-2]}"
            # A dry-run push contacts the remote and writes nothing, so there is
            # no unreviewed change to gate. Gating it would block a diagnostic
            # for no gain.
            # ...and not when the flag is another option's ARGUMENT.
            # `git push -o --dry-run origin main` is a real push: -o consumes
            # `--dry-run` as its push-option value, so the flag is data, and
            # exempting it skipped branch protection and the audit gate.
            if [ "$verb" = "push" ] \
               && [[ "$rest" =~ (^|[[:space:]])--dry-run([[:space:]]|$) ]] \
               && ! [[ "$rest" =~ (^|[[:space:]])(-o|--push-option|--receive-pack|--exec|--repo)[[:space:]]+--dry-run ]]; then
                printf 'exempt\t%s\n' "$seg"; continue
            fi
            printf '%s\t%s\n' "$verb" "$seg"
        elif [[ "$rest" =~ (^|[^A-Za-z0-9_-])${HOOK_PATH_PREFIX}git${HOOK_GIT_OPTS}[[:space:]]+(commit|push)([[:space:]]|$) ]]; then
            # A mutation IS in this segment, but not where a command starts —
            # `nice git push`, `timeout 5 git push`, and whatever wrapper comes
            # next. Enumerating wrappers is a losing game and every miss is an
            # unguarded push, so the segment is reported as unreadable and the
            # caller refuses it. Per SEGMENT, deliberately: asking only whether
            # the command as a whole had any recognised verb let one vouch for
            # another, so `git commit -m x && nice git push` passed on the
            # strength of its commit.
            printf 'unreadable\t%s\n' "$seg"
        fi
    done <<< "$cmd"
}

# hook_unmatched_git_verb — true when the command clearly contains a git
# mutation that hook_git_segments could not attribute to a segment.
#
# Wrappers are open-ended: `nice git push`, `timeout 5 git push`,
# `xargs git push`, `nohup`, `stdbuf`, `time`, and whatever the next one is.
# Enumerating them is a losing game, and each one missed is an unguarded push.
# So the residue is checked instead: if a `git commit`/`git push` survives the
# same preprocessing the segmenter uses — heredoc bodies gone, comments gone,
# quoted runs blanked — and no segment claimed it, the guard cannot see what it
# is being asked to allow, and says so rather than allowing it.
#
# This is narrow on purpose. It fires only on a MUTATION verb, so reads and
# mentions are unaffected, and the quote blanking means a command that merely
# prints the words does not reach here.
# Quote-splicing: `"git" push origin master` and `g'i't push` are ordinary shell
# that runs git, but blanking quoted runs turns them into `"" push` and `gt
# push`, so neither the segmenter nor the residue check sees a verb. Detected on
# the input with quotes REMOVED rather than blanked — spliced quotes vanish and
# the verb reappears.
hook_has_spliced_verb() {
    local unquoted
    # Quotes REMOVED, not blanked — spliced ones vanish and the verb reappears.
    # Only quoted runs with NO whitespace inside are removed. Those are quotes
    # spliced into a word — `"git"`, `g'i't` — which vanish and rejoin the token.
    # A quoted run containing spaces is a complete argument: `echo "a && git push
    # origin main"` unquotes to something that LOOKS like a compound command, and
    # removing its quotes would turn a command that only prints into a blocked
    # one. Whitespace inside the quotes is what tells the two apart.
    unquoted="$(printf '%s' "$1" | sed "s/\"\([^\"[:space:]]*\)\"/\1/g; s/'\([^'[:space:]]*\)'/\1/g")"
    # The same segmentation, so the verb must be in COMMAND position after
    # unquoting. Merely containing the words is not enough: `echo "git push"`
    # unquotes to `echo git push`, where git is an argument, and blocking that
    # would be the cry-wolf failure the false-positive fixtures exist to prevent.
    # VERB segments only. hook_git_segments also emits `unreadable` for a verb
    # it can see but not attribute, and `echo git push` produces exactly that —
    # so testing for any output at all flagged every command that merely
    # mentions the words.
    # Pure bash, no grep. `grep -q … || return 1` reports "not spliced" when grep
    # is missing or shadowed, and `git "push" origin main` then runs with no
    # branch protection, no audit gate and no scan. This file says twice that a
    # hook needing PATH to read its own input can be silenced by PATH; this was
    # the one place still doing it.
    local _l _found=1
    while IFS= read -r _l; do
        # `unreadable` counts. `nice "git" push origin master` unquotes to
        # `nice git push`, which is a wrapper the segmenter cannot attribute —
        # class `unreadable`, not a verb. Ignoring it reported "not spliced",
        # while the original blanked to `nice "" push` with no verb at all, so
        # neither check saw anything and the push ran ungated.
        case "${_l%%$'\t'*}" in commit|push|unreadable) _found=0 ;; esac
    done < <(hook_git_segments "$unquoted")
    [ "$_found" = 0 ] || return 1
    # ...and only when the ordinary reading found nothing, so an ordinary
    # command is not reported twice.
    local _m _seen=1
    while IFS= read -r _m; do
        case "${_m%%$'\t'*}" in commit|push|unreadable) _seen=0 ;; esac
    done < <(hook_git_segments "$1")
    [ "$_seen" = 1 ]
}

hook_unmatched_git_verb() {
    local line
    while IFS= read -r line; do
        [ "${line%%$'\t'*}" = "unreadable" ] && return 0
    done < <(hook_git_segments "$1")
    return 1
}
