#!/bin/bash
# redact-stream.sh — replace secrets on stdin with stable placeholders, line by
# line, as the text streams through. The runtime half of the redact-output
# hook: that hook rewrites every Bash command so its stdout and stderr flow
# through this filter before the tool captures them, so the model sees
#
#     DATABASE_URL=postgres://app:<REDACTED:url-password:1>@db/app
#     AWS_SECRET_ACCESS_KEY=<REDACTED:env-secret:2>
#
# and never the values. The same value gets the same placeholder within a
# session, so "the key on line 3 is the one the compose file uses" is still a
# statement the reader can make; a flat *** would destroy that.
#
# Usage:
#   redact-stream.sh [--map FILE] < input > output
#
# --map FILE   session map of placeholder assignments, one `kind<TAB>n<TAB>value`
#              per line. Read at start so earlier assignments are honoured,
#              appended to as new values are seen. The hook creates it mode 0600
#              under .claude/session-state/, which is gitignored. Without --map
#              numbering is stable only within one invocation.
#
# What is redacted, in order:
#   1. every pattern in plugin/shared/credential-patterns.sh (the same list the
#      commit-time credential scan blocks on), kind = the label slugified;
#      a repo .gitleaks.toml widens the list (kind = gitleaks)
#   2. the value of a KEY=value, key: value, "key": "value" or --key=value
#      assignment whose KEY looks secret-bearing (…PASSWORD, …SECRET, …TOKEN,
#      …API_KEY, DATABASE_URL, DSN, …), anywhere in the line; kind =
#      env-secret, the key itself stays visible
#   3. the password in a URL userinfo (scheme://user:PASS@host), kind = url-password
#   4. bearer/basic credentials in an Authorization header, kind = auth-header
#   5. every line between -----BEGIN … PRIVATE KEY----- and its END line,
#      kind = private-key-body; the BEGIN and END lines stay visible
#   6. every value already known to be a secret (from this run or the map),
#      wherever else it appears outside a placeholder, when it is shaped like
#      one: 8+ characters, no whitespace, not a plain lowercase word, not a
#      path or a shell expansion
#   0. a line of the session map itself comes back as its placeholder, so
#      `cat` on the map reveals nothing whatever the values are
#
# What is NOT redacted, said plainly: names, addresses and free-text personal
# data (that needs a model, not a filter); a secret split across two lines;
# anything a caller printed before this filter was in place.
#
# Fails CLOSED: if the pattern library cannot be loaded, or awk is missing, the
# input is drained and nothing is written to stdout. Passing text through on
# failure would turn a broken redactor into a leak. Exit 2 in that case so a
# caller that checks can tell "withheld" from "clean".
#
# Plain POSIX awk on purpose (mawk on most laptops, gawk in CI): no gensub, no
# three-argument match, no IGNORECASE. Case-insensitive matching is done by
# matching a tolower() copy and cutting the original at the same offsets,
# which works because tolower() preserves length. One more mawk fact, measured
# rather than assumed: mawk 1.3.4 reads an open-ended interval `X{n,}` as
# exactly `X{n}`, so a JWT pattern ending in `{20,}` would match twenty
# characters and let the rest of the token through. The BEGIN block probes for
# that and rewrites `X{n,}` to `X{n}X*` when the running awk needs it.

set -u

MAP_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --map) MAP_FILE="${2:-}"; shift 2 ;;
        --map=*) MAP_FILE="${1#--map=}"; shift ;;
        -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
        *) echo "redact-stream: unknown argument: $1" >&2; while IFS= read -r _; do :; done; exit 2 ;;
    esac
done

# Drain with a builtin: this path exists for when PATH is broken, so it must
# not depend on PATH to find cat.
_withhold() {
    echo "redact-stream: $1 — output withheld rather than passed through unredacted" >&2
    while IFS= read -r _; do :; done
    exit 2
}

command -v awk >/dev/null 2>&1 || _withhold "awk not found"

# ${BASH_SOURCE[0]%/*}, not dirname: an external command this filter needs to
# find its own pattern list can be taken away by PATH. Parameter expansion
# cannot.
_cred_lib="${BASH_SOURCE[0]%/*}/../shared/credential-patterns.sh"
# shellcheck source=../shared/credential-patterns.sh
. "$_cred_lib" 2>/dev/null || _withhold "cannot load $_cred_lib"
[ "${#NEXUS_CREDENTIAL_PATTERNS[@]}" -gt 0 ] 2>/dev/null || _withhold "pattern list is empty"

# Labels become kinds: lowercase, runs of anything but [a-z0-9] collapsed to
# one dash, trimmed. Pure bash — no tr/sed, and no ${x,,} (bash 3.2 on macOS).
_slug() {
    local s="$1" out="" c="" i=0 prev_dash=1
    local upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ" lower="abcdefghijklmnopqrstuvwxyz" pre=""
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-z0-9]) out="$out$c"; prev_dash=0 ;;
            [A-Z]) pre="${upper%%"$c"*}"; out="$out${lower:${#pre}:1}"; prev_dash=0 ;;
            *) [ "$prev_dash" -eq 0 ] && out="$out-"; prev_dash=1 ;;
        esac
    done
    printf '%s' "${out%-}"
}
_patterns=""
_entry=""
for _entry in "${NEXUS_CREDENTIAL_PATTERNS[@]}"; do
    _patterns="${_patterns}$(_slug "${_entry%%|*}")|${_entry#*|}"$'\n'
done
# gitleaks additions, strictly additive, same as the report writer's redactor.
# nexus_redaction_patterns prints the baseline first; skip that many lines.
_extra=""
_extra="$(nexus_redaction_patterns 2>/dev/null | tail -n +$(( ${#NEXUS_CREDENTIAL_PATTERNS[@]} + 1 )) || true)"
# Each one is inspected, then compile-probed. gitleaks rules are RE2, and
# RE2-only syntax is the common case: `(?i)`, `\d`, `\w`, `\s`, `\b`,
# lookaround. mawk refuses those at compile time; gawk ACCEPTS `(?i)` and
# then matches nothing — a rule that is silently dead is worse than one that
# is skipped and named. So the inspection comes first and behaves the same
# under every awk, and the probe catches what inspection cannot (an
# unbalanced paren). Fed to mawk unprobed, one such rule aborted the filter
# at the first line, stdout empty, and with every Bash call wrapped that
# repository lost ALL command output. Skipped rules are named on stderr.
# One awk fork per rule that passes inspection: a compile failure is fatal
# to the process, so rules cannot share one. About a millisecond each.
if [ -n "$_extra" ]; then
    while IFS= read -r _entry; do
        [ -n "$_entry" ] || continue
        case "$_entry" in
            *'(?'*|*'\d'*|*'\w'*|*'\s'*|*'\b'*|*'\D'*|*'\W'*|*'\S'*|*'\B'*|*'\A'*|*'\z'*|*'\Z'*)
                echo "redact-stream: skipping a .gitleaks.toml rule that uses RE2-only syntax (not ERE): ${_entry:0:60}" >&2
                continue ;;
        esac
        if NEXUS_PROBE_RE="$_entry" awk 'BEGIN { match("probe", ENVIRON["NEXUS_PROBE_RE"]); exit 0 }' >/dev/null 2>&1; then
            _patterns="${_patterns}gitleaks|${_entry}"$'\n'
        else
            echo "redact-stream: skipping a .gitleaks.toml rule awk cannot compile as ERE: ${_entry:0:60}" >&2
        fi
    done <<<"$_extra"
fi
[ -n "$_patterns" ] || _withhold "no patterns resolved"

# Everything awk needs goes through ENVIRON: a -v value would have escape
# processing run on it, and these strings are full of backslashes.
export NEXUS_REDACT_PATTERNS="$_patterns"
export NEXUS_REDACT_MAP="$MAP_FILE"
# Set by the tests to exercise the interval rewrite even under an awk that
# does not need it.
export NEXUS_REDACT_FORCE_INTERVAL_FIX="${NEXUS_REDACT_FORCE_INTERVAL_FIX:-}"

# Per-line flushing. Measured under mawk 1.3.4: when stdout is a file or a
# pipe, neither fflush() nor fflush("/dev/stdout") nor system("") writes
# anything out before exit — only `-W interactive` does, and that flag is
# mawk's own (gawk warns on it). This is not a latency nicety: a child the
# command leaves holding the pipe keeps awk alive past the shell's bounded
# wait, and a line still in awk's buffer at that point is a line the tool
# never receives. gawk flushes on fflush(), which the program also calls.
_awk_opts=()
case "$(awk -W version 2>&1)" in
    *mawk*) _awk_opts=(-W interactive) ;;
esac

exec awk ${_awk_opts[@]+"${_awk_opts[@]}"} '
# --- interval rewrite -------------------------------------------------------
# Return the atom that ends at position `end` of regex r: a bracket expression
# `[...]`, a group `(...)`, an escaped char `\x`, or a single char.
function atom_before(r, end,   j, depth, c) {
    c = substr(r, end, 1)
    if (c == "]") {
        for (j = end - 1; j >= 1; j--) {
            if (substr(r, j, 1) == "[" && (j == 1 || substr(r, j - 1, 1) != "\\")) {
                return substr(r, j, end - j + 1)
            }
        }
        return c
    }
    if (c == ")") {
        depth = 0
        for (j = end; j >= 1; j--) {
            if (substr(r, j, 1) == ")" && (j == 1 || substr(r, j - 1, 1) != "\\")) depth++
            else if (substr(r, j, 1) == "(" && (j == 1 || substr(r, j - 1, 1) != "\\")) {
                depth--
                if (depth == 0) return substr(r, j, end - j + 1)
            }
        }
        return c
    }
    if (end > 1 && substr(r, end - 1, 1) == "\\") return substr(r, end - 1, 2)
    return c
}
# X{n,}  ->  X{n}X*
function fix_intervals(r,   out, p, q, atom, before, n) {
    out = ""
    while (match(r, /\{[0-9]+,\}/)) {
        p = RSTART; q = RLENGTH
        n = substr(r, p + 1, q - 3)
        before = substr(r, 1, p - 1)
        atom = atom_before(before, length(before))
        out = out before "{" n "}" atom "*"
        r = substr(r, p + q)
    }
    return out r
}
# --- placeholders ------------------------------------------------------------
# A value is chased across later lines (rule 6) only when it is shaped like a
# secret: eight or more characters, no whitespace, not a shell expansion, not
# a plain word, not a path. "password" as a compose default, "changeme", and
# a TAP line`s file path all went into the map once and every later mention
# of them came back as a placeholder. A path is `/`, `./`, `../` or `~/`
# followed by lowercase components only; a base64 secret that happens to
# start with `/` has uppercase in it and is still chased.
function secretish(v) {
    if (length(v) < 8) return 0
    if (v ~ /[[:space:]]/) return 0
    if (v ~ /^[$<]/) return 0
    if (v ~ /^[a-z]+$/) return 0
    if (v ~ /^(\.\.?|~)?\/[a-z0-9_.-]*(\/[a-z0-9_.-]*)*$/) return 0
    return 1
}
function place(kind, value,   ph) {
    if (value in M) return M[value]
    ph = "<REDACTED:" kind ":" (++C[kind]) ">"
    M[value] = ph
    if (secretish(value)) KNOWN[++nk] = value
    # Only a value rule 6 can defend goes into the map: a short, plain or
    # path-shaped value reformatted out of the map (`cut -f3`) would print
    # in clear, and it gains nothing from cross-run numbering.
    if (mapfile != "" && index(value, "\t") == 0 && secretish(value)) {
        printf "%s\t%d\t%s\n", kind, C[kind], value >> mapfile
        close(mapfile)
    }
    return ph
}
function trimr(s) { sub(/[[:space:]]+$/, "", s); return s }
# True when t ends inside a well-formed placeholder prefix: the last
# "<REDACTED:" has no ">" after it and what follows it is kind[:n]. A bare
# literal "<REDACTED:" in prose does not count, so it cannot switch the
# env rule off for the rest of a line.
function inside_placeholder(t,   k, last, tail) {
    last = 0
    tail = t
    while ((k = index(tail, "<REDACTED:")) > 0) { last += k; tail = substr(tail, k + 1) }
    if (last == 0) return 0
    tail = substr(t, last)
    if (index(tail, ">") > 0) return 0
    return tail ~ /^<REDACTED:[a-z0-9-]+(:[0-9]*)?$/
}
# Replace every literal occurrence of lit in s with rep, skipping the text
# inside <REDACTED:...> placeholders: "password" is eight characters and
# lives inside <REDACTED:url-password:1>.
function replace_literal(s, lit, rep,   out, p, ll, e) {
    ll = length(lit); out = ""
    while (s != "") {
        p = index(s, "<REDACTED:")
        if (p == 0) { out = out gsub_literal(s, lit, rep); break }
        out = out gsub_literal(substr(s, 1, p - 1), lit, rep)
        s = substr(s, p)
        # Only a well-formed placeholder is skipped; a stray literal marker
        # followed by a later ">" is ordinary text and gets scanned.
        if (match(s, /^<REDACTED:[a-z0-9-]+(:[0-9]+)?>/)) {
            out = out substr(s, 1, RLENGTH)
            s = substr(s, RLENGTH + 1)
        } else {
            out = out substr(s, 1, 10)
            s = substr(s, 11)
        }
    }
    return out
}
function gsub_literal(s, lit, rep,   out, p, ll) {
    ll = length(lit); out = ""
    while ((p = index(s, lit)) > 0) {
        out = out substr(s, 1, p - 1) rep
        s = substr(s, p + ll)
    }
    return out s
}
# Position of the closing quote q in rest (which starts right after the
# opening one), skipping quotes escaped by an odd number of backslashes.
# 0 when there is none.
function closing_quote(rest, q,   i, n, bs) {
    n = length(rest)
    for (i = 1; i <= n; i++) {
        if (substr(rest, i, 1) == "\\") { bs++; continue }
        if (substr(rest, i, 1) == q && bs % 2 == 0) return i
        bs = 0
    }
    return 0
}
BEGIN {
    mapfile = ENVIRON["NEXUS_REDACT_MAP"]
    needfix = (ENVIRON["NEXUS_REDACT_FORCE_INTERVAL_FIX"] != "")
    if (!needfix) { match("aaaa", "a{2,}"); if (RLENGTH != 4) needfix = 1 }
    np = split(ENVIRON["NEXUS_REDACT_PATTERNS"], L, "\n")
    n = 0; nk = 0
    for (i = 1; i <= np; i++) {
        if (L[i] == "") continue
        k = L[i]; sub(/\|.*/, "", k)
        r = L[i]; sub(/^[^|]*\|/, "", r)
        if (k == "private-key-pem") continue   # handled as a block, see 5.
        if (needfix) r = fix_intervals(r)
        n++; K[n] = k; R[n] = r
        KINDS[k] = 1
    }
    KINDS["env-secret"] = 1; KINDS["url-password"] = 1; KINDS["auth-header"] = 1; KINDS["gitleaks"] = 1
    if (n == 0) { print "redact-stream: no patterns loaded" > "/dev/stderr"; exit 2 }
    if (mapfile != "") {
        while ((getline line < mapfile) > 0) {
            t1 = index(line, "\t"); if (t1 == 0) continue
            rest = substr(line, t1 + 1)
            t2 = index(rest, "\t"); if (t2 == 0) continue
            k = substr(line, 1, t1 - 1); num = substr(rest, 1, t2 - 1) + 0; v = substr(rest, t2 + 1)
            if (k == "" || num <= 0 || v == "") continue
            if (!(v in M)) { M[v] = "<REDACTED:" k ":" num ">"; if (secretish(v)) KNOWN[++nk] = v }
            if (num > C[k]) C[k] = num
        }
        close(mapfile)
    }
    inkey = 0
    # Key names, matched anywhere in the line so `"password": "x"` in JSON
    # and `--password=x` on a command line count. Lowercased: matched
    # against a tolower() copy. A key that is EXACTLY pass or pwd is vetoed
    # below (TAP`s `PASS:` and the shell`s `PWD=`), as is a key with a
    # non-secret suffix (secret_name, token_count, password_file).
    envkey = "(^|[[:space:]{,(;&-])[\"'\'']?(export[[:space:]]+)?([a-z_][a-z0-9_]*)?(password|passwd|pass|pwd|secret|token|api_key|apikey|private_key|access_key|secret_key|credential|credentials|dsn|database_url|connection_string|conn_str)[a-z0-9_]*[\"'\'']?[[:space:]]*[=:][[:space:]]*"
    keyveto = "(^|_)(name|names|count|counts|id|ids|type|types|file|files|path|paths|dir|len|length|size|policy|ttl|expiry|expires|header|prefix|suffix|format|kind|enabled|required|version)$"
    urlpw  = "://[^/:@[:space:]]*:[^@/[:space:]]+@"
    authhd = "authorization[[:space:]]*:[[:space:]]*(bearer|basic|token)[[:space:]]+[^[:space:]]+"
}
{
    s = $0

    # 0. a line of the session map itself (`kind<TAB>n<TAB>value`), so that
    #    `cat` on the map hands back placeholders. Only a kind this filter
    #    emits counts, and only when a map is in use: `git diff --numstat`
    #    prints `12<TAB>3<TAB>file`, which is not a map line.
    if (mapfile != "" && match(s, /^[a-z0-9-]+\t[0-9]+\t/) && (substr(s, 1, index(s, "\t") - 1) in KINDS)) {
        t1 = index(s, "\t"); t2 = t1 + index(substr(s, t1 + 1), "\t")
        print "<REDACTED:" substr(s, 1, t1 - 1) ":" substr(s, t1 + 1, t2 - t1 - 1) ">"
        fflush(); next
    }

    # 5. private key bodies. Inside a block: everything up to the END marker
    #    goes; text after the END marker on that line falls through to the
    #    other rules. A BEGIN with its END on the same line (JSON with
    #    \n-escaped PEM) is redacted in place, as many times as it occurs;
    #    a BEGIN without one opens a block, and the rest of that line goes.
    if (inkey) {
        if (match(s, /-----END [A-Z ]*PRIVATE KEY-----/)) {
            s = (RSTART > 1 ? "<REDACTED:private-key-body>" : "") substr(s, RSTART)
            inkey = 0
        } else {
            print "<REDACTED:private-key-body>"; fflush(); next
        }
    }
    out = ""
    while (match(s, /-----BEGIN [A-Z ]*PRIVATE KEY-----/)) {
        b = RSTART + RLENGTH
        out = out substr(s, 1, b - 1)
        s = substr(s, b)
        if (match(s, /-----END [A-Z ]*PRIVATE KEY-----/)) {
            out = out "<REDACTED:private-key-body>"
            s = substr(s, RSTART)
        } else {
            if (s != "") out = out "<REDACTED:private-key-body>"
            s = ""
            inkey = 1
        }
    }
    s = out s

    # 1. credential patterns.
    for (i = 1; i <= n; i++) {
        out = ""
        while (match(s, R[i])) {
            if (RLENGTH <= 0) break
            out = out substr(s, 1, RSTART - 1) place(K[i], substr(s, RSTART, RLENGTH))
            s = substr(s, RSTART + RLENGTH)
        }
        s = out s
    }

    # 3. URL userinfo password: scheme://user:PASS@host — only PASS goes.
    out = ""
    while (match(s, urlpw)) {
        seg = substr(s, RSTART, RLENGTH)
        c = index(substr(seg, 4), ":") + 3
        pw = substr(seg, c + 1, length(seg) - c - 1)
        if (pw !~ /^<REDACTED:/) seg = substr(seg, 1, c) place("url-password", pw) "@"
        out = out substr(s, 1, RSTART - 1) seg
        s = substr(s, RSTART + RLENGTH)
    }
    s = out s

    # 4. Authorization header credential.
    low = tolower(s)
    if (match(low, authhd)) {
        seg = substr(s, RSTART, RLENGTH)
        sp = 0
        for (j = length(seg); j > 0; j--) { if (substr(seg, j, 1) ~ /[[:space:]]/) { sp = j; break } }
        if (sp > 0) {
            cred = substr(seg, sp + 1)
            if (cred !~ /^<REDACTED:/) seg = substr(seg, 1, sp) place("auth-header", cred)
            s = substr(s, 1, RSTART - 1) seg substr(s, RSTART + RLENGTH)
        }
    }

    # 2. secret-bearing assignment, every occurrence in the line. A quoted
    #    value ends at its closing quote (escaped quotes skipped); an
    #    unquoted one at whitespace or , ; } & ). After 3 and 4 on purpose:
    #    a value already holding a placeholder keeps its structure.
    out = ""
    low = tolower(s)
    while (match(low, envkey)) {
        head = substr(s, 1, RSTART + RLENGTH - 1)
        rest = substr(s, RSTART + RLENGTH)
        # the key itself: the identifier just before the = or :
        key = substr(low, RSTART, RLENGTH)
        sub(/[[:space:]]*[=:][[:space:]]*$/, "", key)
        sub(/["'\'']$/, "", key)
        sub(/^.*[^a-z0-9_]/, "", key)
        sub(/^export_?/, "", key)
        skip = 0
        if (inside_placeholder(head) && index(rest, ">") > 0) skip = 1
        else if (key ~ /^(old)?pwd$/ || key ~ /^(by|com)?pass(ed|es|ing)?$/) skip = 1
        else if (key ~ keyveto) skip = 1
        if (skip) {
            out = out head
            s = rest
            low = tolower(s)
            continue
        }
        q = substr(rest, 1, 1)
        consumed = 0; val = ""
        if ((q == "\"" || q == "'\''") && (e = closing_quote(substr(rest, 2), q)) > 0) {
            inner = substr(rest, 2, e - 1)
            val = q inner q
            consumed = e + 1
            if (inner != "" && index(inner, "<REDACTED:") == 0) val = q place("env-secret", inner) q
        } else if (match(rest, /^[^[:space:],;}&)]+/)) {
            val = substr(rest, 1, RLENGTH)
            consumed = RLENGTH
            if (index(val, "<REDACTED:") == 0) val = place("env-secret", val)
        }
        out = out head val
        s = substr(rest, consumed + 1)
        low = tolower(s)
    }
    s = out s

    # 6. a value known to be a secret is a secret wherever else it appears —
    #    outside placeholders, which replace_literal skips.
    for (j = 1; j <= nk; j++) {
        if (index(s, KNOWN[j]) > 0) s = replace_literal(s, KNOWN[j], M[KNOWN[j]])
    }

    print s
    fflush()
}
END {
    fflush()
}'
