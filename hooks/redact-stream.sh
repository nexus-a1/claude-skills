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
#   redact-stream.sh [--map FILE] [--pii CLASSES] < input > output
#
# --map FILE   session map of placeholder assignments, one `kind<TAB>n<TAB>value`
#              per line. Read at start so earlier assignments are honoured,
#              appended to as new values are seen. The hook creates it mode 0600
#              under .claude/session-state/, which is gitignored. Without --map
#              numbering is stable only within one invocation.
#
# --pii CLASSES  comma-separated structured-PII classes to redact on top of the
#              secrets tier: email, phone, iban, pesel, nip, card, ip. Absent or
#              empty means none — the secrets tier is unconditional, the PII
#              tier is opted into. The shapes and validators come from
#              plugin/shared/pii-patterns.sh; redact-output.sh resolves the
#              session's set from .claude/configuration.yml and NEXUS_REDACT_PII
#              and passes it here. A class named here that the library does not
#              know is dropped with a note on stderr; a library that cannot be
#              loaded at all withholds output, because a caller that asked for
#              PII redaction and got none silently is the failure this whole
#              file exists to prevent.
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
#   7. with --pii, every enabled structured-PII class: an email address, a
#      phone number, an IBAN, a PESEL, a NIP, a payment card, an IPv4 address;
#      kind = the class name. Applied after 1-5 and before 6, on the text
#      between placeholders only, so a value the secrets tier already replaced
#      is not scanned again. Where the format defines a checksum — Luhn for a
#      card, mod-97 for an IBAN, the PESEL and NIP control digits — a candidate
#      that fails it is left in clear: redacting every sixteen-digit number is
#      how a filter gets switched off wholesale.
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
PII_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --map) MAP_FILE="${2:-}"; shift 2 ;;
        --map=*) MAP_FILE="${1#--map=}"; shift ;;
        --pii) PII_ARG="${2:-}"; shift 2 ;;
        --pii=*) PII_ARG="${1#--pii=}"; shift ;;
        -h|--help) sed -n '2,65p' "$0"; exit 0 ;;
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

# ── Tier 2: structured PII, only when asked for ──────────────────────────────
# The classes arrive as a comma list. Each name is checked against the library's
# own list before it selects anything, so a typo cannot quietly turn a class
# off; only rules whose class is enabled are handed to awk, so a disabled class
# costs nothing per line.
_pii_classes=""
_pii_rules=""
_pii_email_veto=""
if [ -n "$PII_ARG" ]; then
    _pii_lib="${BASH_SOURCE[0]%/*}/../shared/pii-patterns.sh"
    # shellcheck source=../shared/pii-patterns.sh
    . "$_pii_lib" 2>/dev/null || _withhold "cannot load $_pii_lib (PII classes were requested)"
    [ "${#NEXUS_PII_RULES[@]}" -gt 0 ] 2>/dev/null || _withhold "PII rule list is empty (PII classes were requested)"
    _rest="$PII_ARG"
    while [ -n "$_rest" ]; do
        _name="${_rest%%,*}"
        if [ "$_name" = "$_rest" ]; then _rest=""; else _rest="${_rest#*,}"; fi
        while [ "${_name# }" != "$_name" ]; do _name="${_name# }"; done
        while [ "${_name% }" != "$_name" ]; do _name="${_name% }"; done
        [ -n "$_name" ] || continue
        if ! nexus_pii_is_class "$_name"; then
            echo "redact-stream: unknown PII class '$_name' — ignored" >&2
            continue
        fi
        case ",$_pii_classes," in *",$_name,"*) continue ;; esac
        _pii_classes="${_pii_classes:+$_pii_classes,}$_name"
    done
    for _entry in "${NEXUS_PII_RULES[@]}"; do
        case ",$_pii_classes," in
            *",${_entry%%|*},"*) _pii_rules="${_pii_rules}${_entry}"$'\n' ;;
        esac
    done
    for _entry in "${NEXUS_PII_EMAIL_LOCAL_VETO[@]}"; do
        _pii_email_veto="${_pii_email_veto}${_entry}"$'\n'
    done
fi

# Everything awk needs goes through ENVIRON: a -v value would have escape
# processing run on it, and these strings are full of backslashes.
export NEXUS_REDACT_PATTERNS="$_patterns"
export NEXUS_REDACT_MAP="$MAP_FILE"
export NEXUS_REDACT_PII_CLASSES="$_pii_classes"
export NEXUS_REDACT_PII_RULES="$_pii_rules"
export NEXUS_REDACT_PII_EMAIL_VETO="$_pii_email_veto"
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
    # Only a value the filter can defend goes into the map: a short, plain or
    # path-shaped value reformatted out of the map (`cut -f3`) would print
    # in clear, and it gains nothing from cross-run numbering. A PII value is
    # defended by its own rule rather than by rule 6 — a six-character email
    # address is matched wherever it appears, including in a column cut out of
    # the map — so the length floor does not apply to it.
    if (mapfile != "" && index(value, "\t") == 0 && (secretish(value) || (kind in PIICLASS))) {
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
# --- tier 2: structured PII --------------------------------------------------
# Checksums first. Each returns 1 only when the candidate is a well-formed
# member of its format, so a number that merely has the right length is left in
# clear. That asymmetry is deliberate: a missed redaction is a leak the content
# rules and the name-based read guard still stand behind, while a filter that
# eats every long number is one the user turns off.
function luhn(d,   i, sum, dig, alt, n) {
    n = length(d); sum = 0; alt = 0
    for (i = n; i >= 1; i--) {
        dig = substr(d, i, 1) + 0
        if (alt) { dig *= 2; if (dig > 9) dig -= 9 }
        sum += dig; alt = 1 - alt
    }
    return (sum % 10) == 0
}
# PESEL: weights 1,3,7,9 repeating over the first ten digits, control digit
# eleventh. The checksum alone accepts one eleven-digit number in ten, so the
# embedded date is checked too — month 1-12 (plus the 20/40/60/80 century
# offsets) and day 1-31 — which is what keeps an eleven-digit millisecond
# timestamp out.
function pesel_ok(d,   w, i, sum, mm, dd, mon) {
    if (length(d) != 11) return 0
    split("1,3,7,9,1,3,7,9,1,3", w, ",")
    sum = 0
    for (i = 1; i <= 10; i++) sum += w[i] * (substr(d, i, 1) + 0)
    if (((10 - (sum % 10)) % 10) != substr(d, 11, 1) + 0) return 0
    mm = substr(d, 3, 2) + 0
    dd = substr(d, 5, 2) + 0
    mon = mm % 20
    if (mm > 92 || mon < 1 || mon > 12) return 0
    if (dd < 1 || dd > 31) return 0
    return 1
}
# NIP: weights 6,5,7,2,3,4,5,6,7 mod 11; a remainder of 10 is not a valid
# check digit and marks the number invalid rather than wrapping.
function nip_ok(d,   w, i, sum, c) {
    if (length(d) != 10) return 0
    split("6,5,7,2,3,4,5,6,7", w, ",")
    sum = 0
    for (i = 1; i <= 9; i++) sum += w[i] * (substr(d, i, 1) + 0)
    c = sum % 11
    if (c == 10) return 0
    return c == substr(d, 10, 1) + 0
}
# IBAN mod-97 (ISO 13616): move the first four characters to the end, map A-Z
# to 10-35, take the whole thing mod 97 digit by digit — the number is far too
# long for a double, the running remainder is not.
function iban_ok(s,   i, c, t, rem, v, n) {
    n = length(s)
    if (n < 15 || n > 34) return 0
    if (s !~ /^[A-Z][A-Z][0-9][0-9]/) return 0
    t = substr(s, 5) substr(s, 1, 4)
    rem = 0
    for (i = 1; i <= n; i++) {
        c = substr(t, i, 1)
        if (c ~ /^[0-9]$/) rem = (rem * 10 + (c + 0)) % 97
        else {
            v = index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
            if (v == 0) return 0
            rem = (rem * 100 + v + 9) % 97
        }
    }
    return rem == 1
}
function strip_sep(s,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c != " " && c != "-" && c != "(" && c != ")") out = out c
    }
    return out
}
function count_digits(s,   i, n) {
    n = 0
    for (i = 1; i <= length(s); i++) if (substr(s, i, 1) ~ /^[0-9]$/) n++
    return n
}
# Drop the last separator-delimited group of a candidate, or return "" when
# there is none. Greedy matching over-reaches on the two rules whose shape is
# open-ended (an IBAN written in groups, a phone number followed by more
# numbers); trimming the tail and re-validating recovers the real value instead
# of discarding it.
function trim_group(s,   i, c) {
    for (i = length(s); i >= 1; i--) {
        c = substr(s, i, 1)
        if (c == " " || c == "-") return substr(s, 1, i - 1)
    }
    return ""
}
# How many characters of `cand` are a valid instance of `rule`. 0 = no.
function pii_accept(rule, cand, before, after,   local, dom, dig, t, n, i, PARTS) {
    if (rule == "email") {
        if (before ~ /^[A-Za-z0-9_.%+-]$/) return 0
        local = cand; sub(/@.*/, "", local)
        dom = cand; sub(/^[^@]*@/, "", dom)
        if (local in EVETO) return 0
        # GitHub`s per-user noreply address carries a username, not a contact
        # address, and it is on every commit trailer.
        if (dom ~ /(^|\.)noreply\.github\.com$/) return 0
        return length(cand)
    }
    if (rule == "phone-intl") {
        if (before ~ /^[A-Za-z0-9+]$/) return 0
        t = cand
        while (t != "") {
            dig = count_digits(t)
            if (dig >= 8 && dig <= 15 && substr(t, length(t), 1) ~ /^[0-9]$/) return length(t)
            if (dig < 8) return 0
            t = trim_group(t)
        }
        return 0
    }
    if (rule == "phone-pl") {
        if (before ~ /^[0-9A-Za-z_-]$/) return 0
        if (after ~ /^[0-9A-Za-z_-]$/) return 0
        return length(cand)
    }
    if (rule == "iban") {
        if (before ~ /^[A-Za-z0-9]$/) return 0
        if (after ~ /^[A-Za-z0-9]$/) return 0
        t = cand
        while (t != "") {
            if (iban_ok(strip_sep(t))) return length(t)
            t = trim_group(t)
        }
        return 0
    }
    if (rule == "card") {
        if (before ~ /^[0-9A-Za-z_-]$/) return 0
        if (after ~ /^[0-9A-Za-z_-]$/) return 0
        t = strip_sep(cand)
        n = length(t)
        if (n < 13 || n > 19) return 0
        if (!luhn(t)) return 0
        return length(cand)
    }
    if (rule == "nip") {
        if (before ~ /^[0-9A-Za-z_-]$/) return 0
        if (after ~ /^[0-9A-Za-z_-]$/) return 0
        if (!nip_ok(strip_sep(cand))) return 0
        return length(cand)
    }
    if (rule == "ipv4") {
        if (before ~ /^[0-9A-Za-z_.-]$/) return 0
        if (after ~ /^[0-9A-Za-z_.-]$/) return 0
        n = split(cand, PARTS, ".")
        if (n != 4) return 0
        for (i = 1; i <= 4; i++) if (PARTS[i] + 0 > 255) return 0
        return length(cand)
    }
    return 0
}
# One regex rule over placeholder-free text. A rejected candidate advances by a
# single character rather than by its whole length, so a value that starts one
# character later is still found.
function pii_rule(t, i,   out, cand, n, before, after) {
    # The needle: a character the rule cannot match without. Skipping the regex
    # on a segment that lacks it is not an optimisation for its own sake —
    # mawk`s matcher is quadratic when an unbounded class precedes a required
    # literal, and a build log full of long digit runs took eighteen seconds
    # through the email rule alone before this line existed.
    if (PNEEDLE[i] != "" && index(t, PNEEDLE[i]) == 0) return t
    out = ""
    while (match(t, PX[i])) {
        cand = substr(t, RSTART, RLENGTH)
        # The character before the candidate, which after a rejection is no
        # longer inside `t` — it has already been moved to `out`. Reading it
        # from `t` alone made every boundary veto self-defeating: rejecting
        # `git@github.com` for its service-account local part advanced one
        # character and then accepted `it@github.com`, whose "preceding
        # character" had just been chopped off.
        before = (RSTART > 1) ? substr(t, RSTART - 1, 1) : substr(out, length(out), 1)
        after = substr(t, RSTART + RLENGTH, 1)
        n = pii_accept(PRULE[i], cand, before, after)
        if (n > 0 && n < RLENGTH) {
            # A trimmed accept: what follows the trim is text again, not the
            # tail of a match, so re-derive the character after it.
            after = substr(t, RSTART + n, 1)
            if (PRULE[i] == "iban" && after ~ /^[A-Za-z0-9]$/) n = 0
        }
        if (n > 0) {
            out = out substr(t, 1, RSTART - 1) place(PC[i], substr(cand, 1, n))
            t = substr(t, RSTART + n)
        } else {
            out = out substr(t, 1, RSTART)
            t = substr(t, RSTART + 1)
        }
    }
    return out t
}
# The unseparated numeric classes. Walking maximal digit runs rather than
# matching `[0-9]{13,19}` gets the boundary right by construction — a run glued
# to a letter, a dot, a slash or a dash is part of an identifier, a version, a
# path or a date, and is not a card — and it sidesteps mawk`s comma-interval
# defect entirely.
function pii_digits(t, niplabel,   out, run, L, before, after, after2, kind) {
    if (!(("card" in PIICLASS) || ("pesel" in PIICLASS) || ("nip" in PIICLASS))) return t
    out = ""
    while (match(t, /[0-9]+/)) {
        run = substr(t, RSTART, RLENGTH); L = length(run)
        before = (RSTART > 1) ? substr(t, RSTART - 1, 1) : ""
        after = substr(t, RSTART + RLENGTH, 1)
        after2 = substr(t, RSTART + RLENGTH + 1, 1)
        kind = ""
        # A trailing "." only disqualifies when a digit follows it: that is a
        # decimal or a version, whereas a full stop ends a sentence.
        if (before !~ /^[A-Za-z0-9_.\/-]$/ && after !~ /^[A-Za-z0-9_\/-]$/ &&
            !(after == "." && after2 ~ /^[0-9]$/)) {
            if (("card" in PIICLASS) && L >= 13 && L <= 19 && luhn(run)) kind = "card"
            else if (("pesel" in PIICLASS) && L == 11 && pesel_ok(run)) kind = "pesel"
            else if (("nip" in PIICLASS) && L == 10 && niplabel && nip_ok(run)) kind = "nip"
        }
        if (kind != "") out = out substr(t, 1, RSTART - 1) place(kind, run)
        else out = out substr(t, 1, RSTART + RLENGTH - 1)
        t = substr(t, RSTART + RLENGTH)
    }
    return out t
}
function pii_seg(t, niplabel,   i) {
    for (i = 1; i <= pn; i++) t = pii_rule(t, i)
    return pii_digits(t, niplabel)
}
# Apply the PII rules to a line, copying well-formed placeholders through
# untouched. Splitting on them is what keeps `postgres://app:<REDACTED:...>@
# db.example.com/x` from reading as an email address, and what keeps a
# placeholder from being scanned twice.
function pii_line(s, niplabel,   out, p) {
    if (pn == 0 && !(("card" in PIICLASS) || ("pesel" in PIICLASS) || ("nip" in PIICLASS))) return s
    out = ""
    while (s != "") {
        p = index(s, "<REDACTED:")
        if (p == 0) { out = out pii_seg(s, niplabel); break }
        out = out pii_seg(substr(s, 1, p - 1), niplabel)
        s = substr(s, p)
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

    # Tier 2. Empty unless --pii named classes; the bash half has already
    # dropped every name the library does not know, so anything arriving here
    # selects a real rule.
    pn = 0
    npc = split(ENVIRON["NEXUS_REDACT_PII_CLASSES"], PL, ",")
    for (i = 1; i <= npc; i++) {
        if (PL[i] == "") continue
        PIICLASS[PL[i]] = 1
        KINDS[PL[i]] = 1
    }
    np = split(ENVIRON["NEXUS_REDACT_PII_RULES"], L, "\n")
    for (i = 1; i <= np; i++) {
        if (L[i] == "") continue
        p1 = index(L[i], "|"); if (p1 == 0) continue
        rest = substr(L[i], p1 + 1)
        p2 = index(rest, "|"); if (p2 == 0) continue
        k = substr(L[i], 1, p1 - 1)
        if (!(k in PIICLASS)) continue
        r = substr(rest, p2 + 1)
        p3 = index(r, "|"); if (p3 == 0) continue
        pn++
        PC[pn] = k
        PRULE[pn] = substr(rest, 1, p2 - 1)
        PNEEDLE[pn] = substr(r, 1, p3 - 1)
        r = substr(r, p3 + 1)
        if (needfix) r = fix_intervals(r)
        PX[pn] = r
    }
    nev = split(ENVIRON["NEXUS_REDACT_PII_EMAIL_VETO"], L, "\n")
    for (i = 1; i <= nev; i++) if (L[i] != "") EVETO[L[i]] = 1
    if (mapfile != "") {
        while ((getline line < mapfile) > 0) {
            t1 = index(line, "\t"); if (t1 == 0) continue
            rest = substr(line, t1 + 1)
            t2 = index(rest, "\t"); if (t2 == 0) continue
            k = substr(line, 1, t1 - 1); num = substr(rest, 1, t2 - 1) + 0; v = substr(rest, t2 + 1)
            if (k == "" || num <= 0 || v == "") continue
            if (!(v in M)) { M[v] = "<REDACTED:" k ":" num ">"; if (secretish(v)) KNOWN[++nk] = v }
            if (num > C[k]) C[k] = num
            # Rule 0 hides a map line by its KIND, and the kinds registered
            # below are only the ones this run can produce. A map written when
            # a PII class was enabled, read back by a run where it is not,
            # would otherwise print that line in clear. A kind holding at
            # least one letter is a kind; the letter test is what keeps
            # `git diff --numstat` (12<TAB>3<TAB>path) out.
            if (k ~ /[a-z]/) KINDS[k] = 1
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

    # 7. structured PII, on the text between placeholders. After 1-5 so a
    #    value the secrets tier owns keeps its kind, and before 6 so a PII
    #    value seen here is chased through the rest of the stream like any
    #    other. The NIP label is read off the ORIGINAL line: a bare ten-digit
    #    number is a unix timestamp far more often than it is a tax id, so it
    #    is only read as a NIP when the line says so.
    if (pn > 0 || ("card" in PIICLASS) || ("pesel" in PIICLASS) || ("nip" in PIICLASS))
        s = pii_line(s, (tolower($0) ~ /(^|[^a-z])nip([^a-z]|$)/))

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
