#!/bin/bash
# reverse-substitute.sh — PreToolUse hook on Write, Edit and MultiEdit: turn a
# <REDACTED:kind:n> placeholder the model wrote back into the real value from
# the session map, before the file is written.
#
# WHY THIS EXISTS
#
# redact-output.sh replaces secrets and structured PII in Bash output with
# stable placeholders, so the model works with the SHAPE of a value and never
# the value. That leaves one thing impossible: writing a file that has to carry
# the real value — a .env from a template, a compose file, a config the model is
# refactoring around a credential it can see the placeholder of. Without this
# hook the model has to ask the user to paste the value in, which puts the value
# in the conversation and undoes the layer it just went through.
#
# So: the model writes `<REDACTED:env-secret:2>`, and the bytes that reach the
# file are the value that placeholder stands for.
#
# THIS IS THE ONE PLACE A BUG WRITES A REAL SECRET INTO THE WRONG FILE, so the
# rules are narrow and every one of them is pinned by a test in
# tests/hooks/reverse-substitute.test:
#
#   1. Only an EXACT, well-formed placeholder token is substituted:
#      `<REDACTED:` + kind + `:` + number + `>`. `<REDACTED:email:11>` never
#      resolves to entry 1; `<REDACTED:email:>`, `<REDACTED:email>` and a
#      lower/upper-case variant resolve to nothing.
#   2. A placeholder with no entry in the session map is left exactly as it was
#      and reported in systemMessage. It is never guessed at and never dropped.
#   3. The substitution is SINGLE PASS. A map value that itself looks like a
#      placeholder is written out as a value; it is not re-substituted.
#   4. Only `content` (Write) and `new_string` (Edit, MultiEdit) are touched.
#      NOT `file_path` — a substitution there could redirect the write itself.
#      NOT `old_string` — the Edit tool echoes an old_string it could not find
#      back into the conversation, so substituting there would put the value in
#      the transcript on every near-miss, which is the exact leak this whole
#      layer exists to prevent. Match on a neighbouring line instead.
#   5. The target path is resolved physically (symlinks and `..` included, `..`
#      never folded textually — that is only correct when the component before
#      it is a real directory) and compared against the repository root. A
#      path with a link count above one is refused too: a hardlink is a second
#      name for the same bytes and no path check can see it. Outside the repository, or on a
#      path the read-guard deny list marks sensitive, a value is written ONLY
#      if the file already contains that value — restoring what is already
#      there leaks nothing; putting something new there is what the rule is
#      for. Every other placeholder on such a path is left literal and named.
#   6. Every substitution is logged to redaction-audit.log beside the session
#      map: timestamp, action, path, kind, number. NEVER the value.
#
# ONE WRITER. Claude Code runs PreToolUse hooks in parallel, each on the
# ORIGINAL input, and when two return updatedInput the last to finish wins —
# non-deterministically. This is the only hook that returns updatedInput for
# Write, Edit and MultiEdit; redact-output is the only one that does for Bash.
# Do not register a second one on these tools without folding it into this file
# the way bash-token-filter.py was folded into redact-output.sh.
#
# FAILS OPEN, DELIBERATELY, AND THIS IS THE ONE HOOK THAT DOES. The other
# safety hooks block when they cannot do their job, because not blocking would
# leak. Here the failure mode is inverted: if this hook does nothing, the file
# receives the literal text `<REDACTED:env-secret:2>` — wrong content, plainly
# visible, no value anywhere it should not be. Blocking every Write on a
# machine without jq would buy nothing and cost the session. So: no jq, no map,
# an unreadable map, a payload it cannot parse — it says so on stderr and gets
# out of the way.
#
# What it cannot do, stated so nobody assumes it: it does not make the disk
# safe. A value the model can name a placeholder for is a value it can have
# written into any file in the repository, and reading that file back through
# `cat` redacts it again but `base64` does not. Redaction protects the
# transcript; it is not a boundary against a model that is trying to get around
# it. See "what this does not cover" in plugin/shared/hook-profiles.md.

# ── Kill-switch ──────────────────────────────────────────────────────────────
# NEXUS_HOOK_PROFILE=off      → disable ALL hooks (nuclear option)
# NEXUS_HOOK_PROFILE=minimal  → keep safety hooks (reverse-substitute is safety)
# NEXUS_DISABLED_HOOKS=a,b   → disable specific hooks by name
_nexus_name="reverse-substitute"; _nexus_class="safety"
[ "${NEXUS_HOOK_PROFILE:-full}" = "off" ] && { echo "WARN: safety hook $_nexus_name disabled via NEXUS_HOOK_PROFILE=off — a placeholder written into a file stays a placeholder" >&2; exit 0; }
# safety hooks are NOT disabled by "minimal" — only "off" reaches them
case ",${NEXUS_DISABLED_HOOKS//[[:space:]]/}," in *",$_nexus_name,"*) echo "WARN: safety hook $_nexus_name disabled via NEXUS_DISABLED_HOOKS — a placeholder written into a file stays a placeholder" >&2; exit 0 ;; esac
# ─────────────────────────────────────────────────────────────────────────────

set -u

_hook_dir="${BASH_SOURCE[0]%/*}"

_bail() { echo "reverse-substitute: $1 — no substitution performed" >&2; exit 0; }

command -v jq >/dev/null 2>&1 || _bail "jq is not installed"

_raw="$(cat 2>/dev/null || true)"
[ -n "$_raw" ] || exit 0

_tool="$(printf '%s' "$_raw" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$_tool" in
    Write|Edit|MultiEdit) : ;;
    *) exit 0 ;;
esac

# The fields this hook may rewrite, and only those. file_path and old_string
# are deliberately absent; see rule 4 in the header.
_subject="$(printf '%s' "$_raw" | jq -r '
    [ .tool_input.content? // empty,
      .tool_input.new_string? // empty,
      (.tool_input.edits[]? | .new_string? // empty) ]
    | map(select(type == "string")) | join("\n")' 2>/dev/null || true)"
# Nothing that could be a placeholder: leave with no output at all. This is the
# overwhelmingly common case and it must cost nothing.
case "$_subject" in *'<REDACTED:'*) : ;; *) exit 0 ;; esac

# The sentinel is not decoration. Command substitution strips trailing
# newlines, so `file_path` of "/repo/.env\n" would arrive here as "/repo/.env":
# every guard would then judge the .env — which may well already contain the
# value — while the tool wrote to a DIFFERENT, brand-new file whose name ends
# in a newline. Read the byte-exact value, then refuse a path with a newline in
# it outright: it is pathological, and a guard that cannot name the file it is
# guarding must not approve a write to it.
_path="$(printf '%s' "$_raw" | jq -r '(.tool_input.file_path // empty) + "\u0001"' 2>/dev/null || true)"
_path="${_path%$'\001'}"
[ -n "$_path" ] || _bail "the payload carries no file_path"
# A newline would be eaten by command substitution; a TAB would shift the
# columns of the audit TSV; an ESC or CR would rewrite the line a human reads.
# None of them can be checked or logged faithfully, so none is approved.
case "$_path" in *[[:cntrl:]]*) _bail "the target path contains a control character (a newline or a tab, say), so it can be neither checked byte-for-byte nor logged faithfully" ;; esac

# grep decides the "already contains" question and finds the placeholders. Its
# absence used to end the run silently, which is fail-safe and undiagnosable.
command -v grep >/dev/null 2>&1 || _bail "grep is not available"

# ── Where the session map lives (same rule as redact-output.sh) ──────────────
_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$_root" ]; then
    _state="$_root/.claude/session-state"
else
    _state="${HOME:-/tmp}/.claude/session-state"
fi
_map="$_state/redaction-map.tsv"
_audit="$_state/redaction-audit.log"
[ -r "$_map" ] || _bail "no readable session map at $_map"

# ── Path resolution ─────────────────────────────────────────────────────────
# Absolute, `.` folded — and `..` deliberately NOT folded. Collapsing `a/b/..`
# to `a` textually is only correct when `b` is a real directory: for a symlink
# it is the opposite of correct, because the kernel resolves the link first.
# `repo/vendorlink/../x` folds to `repo/x` (inside) and opens
# `/elsewhere/x` (outside) — a textual fold here defeated the very symlink
# resolution the next function exists to perform. `..` is left in the path and
# handed to `readlink -f`, which resolves it the way the kernel will; when
# `readlink -f` is unavailable, a path still carrying `..` is declared suspect
# rather than guessed at.
_norm() {
    local p="$1" out="" comp rest
    case "$p" in /*) : ;; *) p="$PWD/$p" ;; esac
    rest="${p#/}"
    while [ -n "$rest" ]; do
        comp="${rest%%/*}"
        if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$comp" in
            ""|.) : ;;
            *) out="$out/$comp" ;;
        esac
    done
    printf '%s' "${out:-/}"
}
# Physical path. `readlink -f` where it exists (GNU, and macOS 12.3+) because it
# resolves a symlink in the FINAL component too; otherwise the deepest existing
# ancestor is resolved with cd/pwd -P and a final component that is itself an
# unresolved symlink makes the path suspect — printed with a leading "?" so the
# caller treats it as guarded rather than as inside the repository.
_phys() {
    local p real
    p="$(_norm "$1")"
    if real="$(readlink -f -- "$p" 2>/dev/null)" && [ -n "$real" ]; then
        printf '%s' "$real"; return 0
    fi
    # No readlink -f. A `..` left in the path cannot be folded here without
    # making the symlink mistake above, so the path is declared suspect and
    # treated as guarded.
    case "$p" in */../*|*/..) printf '?%s' "$p"; return 0 ;; esac
    local dir="$p" tail="" base
    while [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
        base="${dir##*/}"
        tail="/$base$tail"
        dir="${dir%/*}"
        [ -n "$dir" ] || dir="/"
    done
    real="$(cd "$dir" 2>/dev/null && pwd -P)" || { printf '?%s' "$p"; return 0; }
    real="${real%/}$tail"
    [ -L "$p" ] && real="?$real"
    printf '%s' "$real"
}

_target="$(_phys "$_path")"
_root_phys=""
[ -n "$_root" ] && _root_phys="$(_phys "$_root")"

# Inside the repository? An unresolvable or symlinked target ("?" prefix) is
# not, and outside a repository nothing is.
_inside=0
case "$_target" in
    '?'*) _inside=0 ;;
    *)
        if [ -n "$_root_phys" ] && [ "${_root_phys#\?}" = "$_root_phys" ]; then
            case "$_target" in
                "$_root_phys"|"$_root_phys"/*) _inside=1 ;;
                *) _inside=0 ;;
            esac
        fi ;;
esac

# Sensitive by name? Same list read-guard refuses the Read tool on.
# shellcheck source=../shared/credential-patterns.sh
. "$_hook_dir/../shared/credential-patterns.sh" 2>/dev/null || _bail "cannot load the sensitive-path list"
type nexus_sensitive_path_match >/dev/null 2>&1 || _bail "the sensitive-path matcher is not defined"
# read-guard checks BOTH that the matcher exists and that the list it walks is
# non-empty; this file checked only the first, and an empty list makes the
# matcher return "no match" for every path in silence — the deny-list guard
# would simply not be there, in the one file whose whole job is to keep a
# secret out of the wrong path. Same check, same wording, same reason.
[ "${#NEXUS_SENSITIVE_PATH_GLOBS[@]}" -gt 0 ] 2>/dev/null \
    || _bail "the sensitive-path list is empty, so a sensitive path cannot be told from an ordinary one"
_target_real="${_target#\?}"
_sensitive=0
_sens_glob=""
if _sens_glob="$(nexus_sensitive_path_match "$_target_real")"; then _sensitive=1; fi

# A hardlink is a second name for the same bytes, and no amount of path
# resolution can see it: an in-repo name for a file that also lives outside the
# repository would pass every check above. A link count over one is rare enough
# in a working tree that refusing on it costs nothing. Where `stat` cannot
# answer, the count reads as 1 and this check is simply absent — said out loud
# in hook-profiles.md rather than left as an implied guarantee.
_links=1
if [ -f "$_target_real" ]; then
    _links="$(stat -c %h "$_target_real" 2>/dev/null || stat -f %l "$_target_real" 2>/dev/null || printf 1)"
    case "$_links" in ''|*[!0-9]*) _links=1 ;; esac
fi

# Guarded targets need the file to already hold a value before that value may
# be written into them again.
_guard_reason=""
if [ "$_inside" -ne 1 ]; then
    _guard_reason="outside the repository"
elif [ "$_links" -gt 1 ]; then
    _guard_reason="a hardlink, so its bytes have another name this check cannot see"
elif [ "$_sensitive" -eq 1 ]; then
    _guard_reason="a sensitive path (matches '$_sens_glob')"
fi

# ── Which placeholders are eligible ─────────────────────────────────────────
# Every key the map holds, and — separately — the values that may actually be
# written to THIS path. On a guarded path a value qualifies only when the file
# already contains it, checked with a fixed-string grep so no part of the value
# is ever interpreted as a pattern.
_tokens="$(printf '%s' "$_subject" | grep -o '<REDACTED:[a-z0-9-]\{1,\}:[0-9]\{1,\}>' 2>/dev/null || true)"
[ -n "$_tokens" ] || exit 0

# Values never touch a command line and never touch the disk.
#
# Two earlier shapes of this block were wrong in opposite directions. Handing
# each value to jq as `--arg v "$secret"` put it in /proc/<pid>/cmdline, which
# is world-readable on a stock box. Writing them to files under a `mktemp -d`
# closed that and opened a quieter version of the same hole: plaintext on disk
# for the life of the process, and hooks.json gives this hook a 20-second
# timeout — a SIGKILL at the deadline leaves the file behind, because no EXIT
# trap runs. (The `umask 077` that was supposed to cover it applied only inside
# the `$( )` that ran mktemp, so the files were 0664 under a 0700 directory.)
#
# So the values live in shell variables — not exported, so not in
# /proc/<pid>/environ either — and reach jq and grep through process
# substitution, which is a pipe. Nothing is written, so nothing is left behind.
#
# `sort -u` used to sit in the token pipeline. It is gone rather than checked:
# duplicates are harmless (the map builder tests membership, and the report
# arrays are `unique`d in jq), and an unchecked `sort` was one more command
# whose absence would have emptied $_tokens and ended the run in silence.
_known_json="$(jq -Rn --rawfile keys <(printf '%s\n' "$_tokens") '
    ($keys | split("\n") | map(select(length > 0)) | map({key: ., value: true}) | from_entries) as $want
    | [ inputs
        | split("\t")
        | select(length >= 3)
        | select((.[0] | test("^[a-z0-9-]+$")) and (.[1] | test("^[0-9]+$")))
        | {key: (.[0] + ":" + .[1]), value: (.[2:] | join("\t"))}
        | select(.value != "")
        | . as $e
        | select($want | has("<REDACTED:" + $e.key + ">")) ]
      | from_entries' < "$_map" 2>/dev/null || printf '{}')"
[ -n "$_known_json" ] || _known_json='{}'

# On a guarded path, keep only the values the file ALREADY contains. Each value
# reaches grep as a pattern FILE (-F -f) fed by a pipe, so it is never an
# argument, never a pattern, and never a word the shell splits.
_eligible_json="$_known_json"
if [ -n "$_guard_reason" ]; then
    _allowed=""
    while IFS= read -r _k; do
        [ -n "$_k" ] || continue
        _v="$(printf '%s' "$_known_json" | jq -r --arg k "$_k" '.[$k] // empty' 2>/dev/null || true)"
        # An EMPTY value would become an empty grep pattern, and an empty
        # pattern matches every line of every file — "this file already
        # contains that value" would be true for everything, on every guarded
        # path at once. The map builder already refuses an empty value; this is
        # the second gate, because "the first gate is enough" is exactly the
        # assumption that stops being true later.
        [ -n "$_v" ] || continue
        if [ -f "$_target_real" ] && [ -r "$_target_real" ] \
           && grep -qF -f <(printf '%s\n' "$_v") -- "$_target_real" 2>/dev/null; then
            _allowed="$_allowed$_k
"
        fi
    done < <(printf '%s' "$_known_json" | jq -r 'keys[]?')
    unset _v
    _eligible_json="$(printf '%s' "$_known_json" | jq -c --arg allowed "$_allowed" '
        . as $m
        | ($allowed | split("\n") | map(select(length > 0)))
        | map({key: ., value: $m[.]}) | from_entries' 2>/dev/null || printf '{}')"
    [ -n "$_eligible_json" ] || _eligible_json='{}'
fi

# ── Substitute ──────────────────────────────────────────────────────────────
# One pass, left to right, no rescanning: jq's gsub finds its matches in the
# INPUT and reassembles, so a replacement value that itself looks like a
# placeholder is written out and never looked at again. A key that is not in
# $map rebuilds the token it came from, byte for byte.
_out="$(printf '%s' "$_raw" | jq -c \
    --slurpfile mapf <(printf '%s' "$_eligible_json") \
    --slurpfile knownf <(printf '%s' "$_known_json") '
    ($mapf[0] // {}) as $map
    | ($knownf[0] // {}) as $known
    | def re: "<REDACTED:(?<k>[a-z0-9-]+):(?<n>[0-9]+)>";
      def sub_text: if type == "string" then gsub(re;
          ($map[.k + ":" + .n]) // ("<REDACTED:" + .k + ":" + .n + ">")) else . end;
      def toks: if type == "string" then [scan(re) | .[0] + ":" + .[1]] else [] end;
      . as $in
    | ($in.tool_input) as $ti
    # $all is built from EXACTLY the fields sub_text will rewrite. Reading
    # `.edits[]?` here while sub_text required `.edits | type == "array"` meant
    # an `edits` OBJECT counted its tokens as substituted and rewrote nothing —
    # an audit line for a substitution that never happened, which is the same
    # false record the single atomic append was written to prevent.
    | (if ($ti.edits? | type) == "array" then [ $ti.edits[] | .new_string? ] else [] end) as $edit_strings
    | ([ $ti.content? | toks ] + [ $ti.new_string? | toks ]
       + ($edit_strings | map(toks)) | flatten) as $all
    | ($ti
       | if has("content") then .content = (.content | sub_text) else . end
       | if has("new_string") then .new_string = (.new_string | sub_text) else . end
       | if has("edits") and (.edits | type == "array")
         then .edits = [ .edits[] | if type == "object" and has("new_string")
                                    then .new_string = (.new_string | sub_text) else . end ]
         else . end) as $new
    | {
        changed: ($new != $ti),
        updatedInput: $new,
        substituted: [ $all[] | . as $k | select($map | has($k)) ] | unique,
        withheld:    [ $all[] | . as $k | select(($map | has($k) | not) and ($known | has($k))) ] | unique,
        missing:     [ $all[] | . as $k | select($known | has($k) | not) ] | unique
      }' 2>/dev/null || true)"
[ -n "$_out" ] || _bail "could not build the rewritten input"

_changed="$(printf '%s' "$_out" | jq -r '.changed')"
_subs="$(printf '%s' "$_out" | jq -r '.substituted[]?')"
_withheld="$(printf '%s' "$_out" | jq -r '.withheld[]?')"
_missing="$(printf '%s' "$_out" | jq -r '.missing[]?')"

# ── Audit ───────────────────────────────────────────────────────────────────
# Path, kind and number. Never the value — an audit line that quotes what it is
# auditing is the leak it was written to detect.
#
# Every line is built first and appended in ONE write, and the write's own
# status decides whether the substitution happens at all. Two reasons for the
# shape. A precheck is not a result: `[ -w ]` is true for a DIRECTORY, so a
# redaction-audit.log that was a directory passed the check, every append
# failed, and the substitution went through unrecorded — the one case the
# header says cannot happen. And appending line by line with a bail in the
# middle leaves a "substituted" line for a substitution that then did not
# happen, which is a false record in the file whose whole job is to be true.
_audit_lines=""
# The path this line names is the RESOLVED one. In the branch where the path
# could not be resolved (no `readlink -f`, and a `..` or a symlinked final
# component), it is marked `unresolved:` instead of printed as though it had
# been: a guarded target can still receive a value it already contains, and a
# log that then names an in-repo symlink while the bytes landed outside the
# repository is a false record of exactly the kind the single atomic append
# was written to stop.
_audit_path="$_target_real"
[ "$_target_real" != "$_target" ] && _audit_path="unresolved:$_target_real"
_audit_add() {
    local action="$1" key="$2" kind num ts
    kind="${key%%:*}"; num="${key##*:}"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"
    _audit_lines="$_audit_lines$(printf '%s\t%s\t%s\t%s\t%s' "$ts" "$action" "$_audit_path" "$kind" "$num")
"
}
if [ -n "$_subs$_withheld" ]; then
    for _k in $_subs; do _audit_add substituted "$_k"; done
    for _k in $_withheld; do _audit_add withheld-guard "$_k"; done
    ( umask 077
      mkdir -p "$_state" 2>/dev/null || exit 1
      [ -e "$_state/.gitignore" ] || printf '*\n' > "$_state/.gitignore"
      [ -e "$_audit" ] || : > "$_audit"
    ) 2>/dev/null
    if ! printf '%s' "$_audit_lines" >> "$_audit" 2>/dev/null; then
        # An unlogged substitution is a secret in a file with no record of how
        # it got there. Refuse rather than write one: the file keeps the
        # literal placeholder, which is visible and harmless. A refusal that
        # could not be logged is only worth a word on stderr — nothing was
        # written either way.
        if [ -n "$_subs" ]; then
            _bail "the audit log at $_audit could not be appended to, so a substitution could not be recorded"
        fi
        echo "reverse-substitute: cannot write the audit log at $_audit" >&2
    fi
fi

# ── Report ──────────────────────────────────────────────────────────────────
_msg=""
# Parameter expansion rather than `tr`: with tr missing, the list of
# placeholders this message exists to name rendered as nothing at all, and the
# sentence still read as though it had named them.
_withheld_list="${_withheld//$'\n'/ }"
_missing_list="${_missing//$'\n'/ }"
if [ -n "$_withheld" ]; then
    # The advice has to match the guard that actually fired. A hardlink
    # refusal was being explained as though the value were new to the file.
    case "$_guard_reason" in
        "outside the repository")
            _advice="write it to a path inside the repository instead" ;;
        a\ hardlink*)
            _advice="write to a fresh path instead, or ask the user for the value" ;;
        *)
            _advice="the value would be new to that file, so ask the user rather than routing it through a placeholder" ;;
    esac
    _msg="reverse-substitute: left literal on ${_path} because it is ${_guard_reason} and the file does not already contain the value: ${_withheld_list}— $_advice."
fi
if [ -n "$_missing" ]; then
    _msg="${_msg:+$_msg }reverse-substitute: no session-map entry for ${_missing_list}— written literally. That placeholder was never issued in this session."
fi

if [ "$_changed" != "true" ]; then
    [ -n "$_msg" ] && jq -nc --arg m "$_msg" '{systemMessage: $m}'
    exit 0
fi

printf '%s' "$_out" | jq -c --arg m "$_msg" '
    {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: .updatedInput}}
    + (if $m == "" then {} else {systemMessage: $m} end)'
exit 0
