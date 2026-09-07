#!/bin/bash
# pii-patterns.sh
# Tier 2 of the redaction layer: structured personal data, next to the
# credential list in credential-patterns.sh.
#
# Tier 1 (credential-patterns.sh) answers "is this a secret". This file answers
# "is this someone's personal data in a machine-checkable format" — an email
# address, a phone number, a bank account, a national identifier, a payment
# card, an IP address. Only STRUCTURED classes live here: each one has a shape
# a filter can match and, where the format defines one, a checksum that turns a
# guess into a decision. Names, addresses and free-text personal data are NOT
# here and cannot be — that needs a model, not a regex. See the "what this does
# not cover" section in plugin/shared/hook-profiles.md.
#
# Consumers:
#   - plugin/hooks/redact-stream.sh  — the streaming filter, via --pii
#   - plugin/hooks/redact-output.sh  — resolves the enabled set for a session
#
# Usage:
#   source /path/to/pii-patterns.sh
#   "${NEXUS_PII_CLASSES[@]}"                # every class this file knows
#   "${NEXUS_PII_DEFAULT_CLASSES[@]}"        # the set that is on by default
#   "${NEXUS_PII_RULES[@]}"                  # 'class|rule|regex' entries
#   nexus_pii_resolve_classes [config_file]  # -> comma list for --pii
#
# Sourcing contract, same as credential-patterns.sh: source it with a hard
# failure on absence. A consumer that skips it silently ends up with no classes
# and reports clean on every input.

# Every class this file can detect. A name outside this list is never honoured,
# wherever it came from — a config file, an environment variable, a --pii
# argument — because the class name selects a code path, and an unknown name
# selecting nothing silently is how a switched-on class ends up switched off.
NEXUS_PII_CLASSES=(email phone iban pesel nip card ip)

# ── The default set, and why ────────────────────────────────────────────────
#
# The rule applied to each class: does a working agent NEED the real value to
# do the task, more often than not? If yes it defaults off, because a redactor
# that breaks the task gets turned off wholesale, and a wholesale-off redactor
# protects nothing.
#
#   email  ON  — the class most likely to carry a real person's data in a repo
#                (fixtures, seed data, support tickets, CSV exports). The key
#                and the domain shape stay visible, so "an address is
#                configured here" survives; only the address goes. Cost, stated
#                plainly: `git log`, `git blame` and `gh` output show author
#                addresses as placeholders. Service addresses are exempt (see
#                the veto below) so git remotes and GitHub noreply trailers are
#                unaffected.
#   phone  ON  — needed for a task essentially never.
#   iban   ON  — likewise, and a leaked one is directly abusable.
#   pesel  ON  — a Polish national identity number is never task input.
#   nip    ON  — a tax identifier is not task input either.
#   card   ON  — a PAN is never something an agent needs to read back.
#   ip     OFF — the one class an agent genuinely needs. Container addresses,
#                `127.0.0.1`, a `192.168.x` home lab, a `docker inspect`, a
#                failing DNS lookup: redacting these breaks ordinary debugging
#                for a value that is usually infrastructure, not a person. It
#                is also the class with the worst false-positive neighbour —
#                a four-part version string is an IPv4 address to any regex.
#                Turn it on for a project that handles subscriber logs.
#
# Change the set per project in .claude/configuration.yml (redaction.pii.*), or
# per session with NEXUS_REDACT_PII.
NEXUS_PII_DEFAULT_CLASSES=(email phone iban pesel nip card)

# ── Detection rules ─────────────────────────────────────────────────────────
#
# Format: 'class|rule|needle|regex'. The regex is everything after the THIRD
# pipe, so it may itself contain a pipe. `rule` names the validator
# redact-stream.sh applies to a candidate the regex found; a candidate that
# fails its validator is left in clear, which is the right way round — a filter
# that redacts every 16-digit number is a filter someone disables.
#
# `needle` is a single character the rule cannot match without, or empty. It is
# a PERFORMANCE guard, not a correctness one: a segment that does not contain
# it is skipped without running the regex at all. Measured, because the cost is
# not obvious — mawk's matcher is quadratic when an unbounded character class
# precedes a required literal, so the email rule spent 18 seconds on fifty
# 3000-character lines of digits that contain no `@` at all, and this filter
# runs on the output of every Bash command in the session. With the needle
# check the same input costs 0.3 s. Only add a needle a match genuinely cannot
# occur without.
#
# POSIX ERE only, and NO comma intervals. Measured, not assumed: mawk 1.3.4
# reads `{13,19}` as exactly `{13}` — the same defect the filter's fix_intervals
# works around for `{n,}` — so `[0-9]{13,19}` would match thirteen digits of a
# sixteen-digit card and redact a partial number. Exact `{n}`, `?` and `+` are
# safe under every awk here. The unseparated forms (a bare card number, a
# PESEL, a bare NIP) are not matched by regex at all: redact-stream walks
# maximal digit runs for those, which gets the boundary right by construction.
NEXUS_PII_RULES=(
    # An address, with a service-account veto applied by the validator.
    'email|email|@|[A-Za-z0-9_.%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z][A-Za-z]+'

    # E.164 and any +-prefixed international number: the validator counts the
    # digits (8..15 per E.164) and rejects the rest.
    'phone|phone-intl|+|\+[0-9][0-9 ()-]*[0-9]'
    # Polish national form, dashed only. The space-separated `123 456 789` is
    # deliberately NOT matched without a country code: three space-separated
    # three-digit columns are ordinary tabular output.
    'phone|phone-pl|-|[0-9]{3}-[0-9]{3}-[0-9]{3}'

    # IBAN: grouped first (longer), then unseparated. Both are mod-97 checked.
    'iban|iban| |[A-Z][A-Z][0-9][0-9]([ ][A-Z0-9]{4})+([ ][A-Z0-9][A-Z0-9]?[A-Z0-9]?)?'
    'iban|iban||[A-Z][A-Z][0-9][0-9][A-Z0-9]+'

    # Card, separated forms: 4-4-4-4 and the 4-6-5 Amex grouping. Luhn-checked.
    'card|card||[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}'
    'card|card||[0-9]{4}[ -][0-9]{6}[ -][0-9]{5}'

    # NIP, dashed forms (3-3-2-2 and 3-2-2-3). Checksum-checked.
    'nip|nip|-|[0-9]{3}-[0-9]{3}-[0-9]{2}-[0-9]{2}'
    'nip|nip|-|[0-9]{3}-[0-9]{2}-[0-9]{2}-[0-9]{3}'

    # IPv4 only, octets range-checked. IPv6 is not covered; see hook-profiles.md.
    'ip|ipv4|.|[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?'
)

# Local parts that are service accounts, not people. Vetoed by the email
# validator so `git@github.com` in a remote URL and the `noreply@` trailer on
# every commit stay readable. No real person's address is one of these, so the
# veto costs no protection.
NEXUS_PII_EMAIL_LOCAL_VETO=(git noreply no-reply)

# True when $1 names a class this file knows.
nexus_pii_is_class() {
    local want="$1" c
    for c in "${NEXUS_PII_CLASSES[@]}"; do
        [ "$c" = "$want" ] && return 0
    done
    return 1
}

# Read `redaction.pii.<class>: true|false` out of a configuration.yml.
#
# A hand-rolled reader rather than yq, because this runs inside a PreToolUse
# hook on every Bash call and must work on a machine that has neither yq nor
# python. It reads exactly one nested block and nothing else: the keys it
# accepts are the class names above, and the only values it accepts are `true`
# and `false`. A config value never becomes a path, an argument or a command
# here — it selects a name from a list this file wrote.
#
# Prints `class<TAB>true|false` lines. Silent when the file is absent.
nexus_pii_config_flags() {
    local cfg="$1"
    [ -n "$cfg" ] && [ -r "$cfg" ] || return 0
    awk '
        # Depth of a line, in leading spaces. Tabs are not YAML indentation.
        function ind(l,   i, n) { n = 0; while (substr(l, n + 1, 1) == " ") n++; return n }
        { line = $0 }
        line ~ /^[[:space:]]*#/ { next }
        {
            d = ind(line)
            key = line; sub(/^[[:space:]]+/, "", key)
            if (key ~ /^redaction:[[:space:]]*$/ && d == 0) { inred = 1; redd = d; next }
            if (inred && d <= redd && key !~ /^$/) { inred = 0; inpii = 0 }
            if (inred && key ~ /^pii:[[:space:]]*$/) { inpii = 1; piid = d; next }
            if (inpii && d <= piid && key !~ /^$/) { inpii = 0 }
            if (inpii && match(key, /^[a-z0-9]+:[[:space:]]*(true|false)[[:space:]]*$/)) {
                name = key; sub(/:.*/, "", name)
                val = key; sub(/^[a-z0-9]+:[[:space:]]*/, "", val); sub(/[[:space:]]*$/, "", val)
                printf "%s\t%s\n", name, val
            }
        }
    ' "$cfg" 2>/dev/null || return 0
}

# Resolve the classes that are on for this session.
#
# Precedence, highest first:
#   1. NEXUS_REDACT_PII — a comma list, or `none`, or `all`. A session-level
#      override, so "I need the real addresses for this one task" does not
#      require editing a file that is checked in. An EMPTY value is treated as
#      unset, not as `none`: a wrapper that writes `export FOO=${FOO:-}` over
#      every NEXUS_* variable would otherwise switch a redaction tier off with
#      nobody having asked. Turning it off takes the word `none`.
#   2. .claude/configuration.yml → redaction.pii.<class>: true|false, applied
#      on top of the defaults, so a config naming one class changes that class
#      and leaves the rest at their documented default.
#   3. NEXUS_PII_DEFAULT_CLASSES.
#
# Prints a comma-separated list (possibly empty) on stdout. An unknown name is
# dropped with a note on stderr rather than ignored silently: a typo'd class in
# a config file is a class the author believes is on.
#
# $1 (optional) — path to a configuration.yml. When omitted, the file is looked
# up by walking up from $PWD, the same way resolve-config.sh does.
# No associative arrays and no ${x,,}: bash 3.2 is still the shell on stock
# macOS, and a hook that dies with a syntax error there fails open.
nexus_pii_resolve_classes() {
    local cfg="${1-}"
    local c name val on=" "

    if [ -z "$cfg" ]; then
        local d="$PWD"
        while [ -n "$d" ] && [ "$d" != "/" ]; do
            if [ -f "$d/.claude/configuration.yml" ]; then cfg="$d/.claude/configuration.yml"; break; fi
            d="${d%/*}"
        done
    fi

    # Session override wins outright.
    local env_set="${NEXUS_REDACT_PII-}"
    if [ -n "$env_set" ]; then
        case "$env_set" in
            none|off)
                return 0 ;;
            all)
                for c in "${NEXUS_PII_CLASSES[@]}"; do on="$on$c "; done ;;
            *)
                local rest="$env_set"
                while [ -n "$rest" ]; do
                    name="${rest%%,*}"
                    if [ "$name" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
                    # Trim spaces without tr or sed: a hook must not need PATH.
                    while [ "${name# }" != "$name" ]; do name="${name# }"; done
                    while [ "${name% }" != "$name" ]; do name="${name% }"; done
                    [ -n "$name" ] || continue
                    if ! nexus_pii_is_class "$name"; then
                        echo "pii-patterns: NEXUS_REDACT_PII names an unknown class '$name' — ignored" >&2
                        continue
                    fi
                    case "$on" in *" $name "*) : ;; *) on="$on$name " ;; esac
                done ;;
        esac
        _nexus_pii_emit "$on"
        return 0
    fi

    # Defaults, then the config's overrides on top of them.
    for c in "${NEXUS_PII_DEFAULT_CLASSES[@]}"; do on="$on$c "; done
    if [ -n "$cfg" ]; then
        while IFS="$(printf '\t')" read -r name val; do
            [ -n "$name" ] || continue
            if ! nexus_pii_is_class "$name"; then
                echo "pii-patterns: $cfg names an unknown redaction.pii class '$name' — ignored" >&2
                continue
            fi
            case "$val" in
                true) case "$on" in *" $name "*) : ;; *) on="$on$name " ;; esac ;;
                false) on="${on// $name / }" ;;
                *) : ;;
            esac
        done < <(nexus_pii_config_flags "$cfg")
    fi

    _nexus_pii_emit "$on"
}

# Space-padded set -> comma list, in NEXUS_PII_CLASSES order so the output is
# stable whatever order the config named things in.
_nexus_pii_emit() {
    local set_str="$1" c out=""
    for c in "${NEXUS_PII_CLASSES[@]}"; do
        case "$set_str" in *" $c "*) out="${out:+$out,}$c" ;; esac
    done
    printf '%s' "$out"
}
