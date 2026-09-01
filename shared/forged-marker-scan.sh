#!/bin/bash
# forged-marker-scan.sh
# Single source of truth for the forged content-boundary marker scan.
#
# Untrusted text is wrapped in UNTRUSTED-CONTENT:START / :END (and
# ARCHIVED-CONTENT:START / :END) fences before it reaches a model. Text that
# carries its own closing marker can end the fence early, so everything after it
# reads as trusted instruction rather than as quoted data. The scan finds that.
#
# Four sites ran their own copy of `grep -nE '(UNTRUSTED|ARCHIVED)-CONTENT:(START|END)'`
# — create-requirements SKILL.md at three stages, and the archivist agent. Both
# defects below were shared by all four, which is the argument for one helper:
# a fifth copy is how a class ends up closed in three places out of five.
#
# Defect 1 — ASCII literals only.
#   The hyphen in `UNTRUSTED-CONTENT` was matched as U+002D and nothing else. A
#   marker written with U+2011 NON-BREAKING HYPHEN, or with a zero-width joiner
#   sitting inside the word, still reads as a closing marker to a model but
#   walked straight past a scan looking for the ASCII byte. Normalisation runs
#   before the match, so the variants collapse onto the shape being matched.
#
# Defect 2 — the scan echoed what it found.
#   `grep -n` prints the matching LINE, and that line is attacker-controlled by
#   definition: it is the text under suspicion. Every site piped it to the
#   transcript, which is the one place it must not reach — a scan that quotes
#   its own attacker into the conversation has delivered the payload it was
#   there to stop. This reports line NUMBERS and a COUNT. The text is never
#   printed, by this helper or by anything it calls.
#
# Usage:
#   source /path/to/forged-marker-scan.sh
#   printf '%s' "$TEXT" | nexus_scan_forged_markers
#   rc=$?
#
# Exit status is grep's, deliberately, so a call site converting from the inline
# grep keeps its existing rc handling unchanged:
#   0  at least one forged marker found  (line numbers and count on stdout)
#   1  none found                        (nothing on stdout)
#   2+ the scan itself failed            (no conclusion about the text)
#
# Sourcing contract: source it with a hard failure on absence. A consumer that
# skips it silently has no function to call, and a `command not found` in a
# fence that then carries on reports clean on every input.

# Marker shapes, after normalisation. The hyphen here is ASCII by the time the
# match runs; see _nexus_normalise_markers.
NEXUS_FORGED_MARKER_RE='(UNTRUSTED|ARCHIVED)-CONTENT:(START|END)'

# Collapse the confusable characters onto the ASCII shapes the pattern matches.
#
# LC_ALL=C on purpose: it makes sed operate on BYTES, so the byte sequences
# below mean exactly themselves whatever locale the caller happens to run under.
# The multibyte alternative — a bracket expression holding the real characters —
# depends on a UTF-8 locale being present and correctly configured, and degrades
# to per-byte matching when it is not. Per-byte matching of a bracket expression
# is not a weaker version of the same thing: it corrupts unrelated UTF-8 text by
# rewriting single continuation bytes. Bytes, stated once, are the safe form.
#
#   U+2010..U+2015  hyphen, non-breaking hyphen, figure/en/em dash, horizontal
#                   bar          E2 80 90 .. E2 80 95   -> '-'
#   U+2212          minus sign   E2 88 92               -> '-'
#   U+FF0D          fullwidth hyphen-minus
#                                EF BC 8D               -> '-'
#   U+FE63          small hyphen-minus
#                                EF B9 A3               -> '-'
#   U+FF1A          fullwidth colon
#                                EF BC 9A               -> ':'
#   U+200B..U+200D  zero-width space, non-joiner, joiner
#                                E2 80 8B .. E2 80 8D   -> removed
#   U+FEFF          zero-width no-break space (BOM)
#                                EF BB BF               -> removed
#   U+00AD          soft hyphen — renders as nothing mid-word, so it hides
#                   INSIDE the word rather than standing in for the hyphen
#                                C2 AD                  -> removed
#   U+2060          word joiner  E2 81 A0               -> removed
#
# The ticket named the first two groups as a minimum. The rest are here because
# each is a one-line bypass of exactly the same shape, and a confusable list that
# stops at the examples in the ticket is a list somebody walks around. Homoglyph
# LETTERS (Cyrillic es for c, Greek omicron for o) are deliberately NOT here:
# that needs a real confusables table, not a sed, and half of one would read as
# coverage it does not have.
#
# Zero-width characters are DELETED rather than mapped, because they carry no
# width: `UNTRUSTED<ZWSP>-CONTENT` is one token to a reader and to a model, and
# replacing it with a space would break the very word the pattern needs to see.
_nexus_normalise_markers() {
    LC_ALL=C sed -E \
        -e 's/\xE2\x80[\x90-\x95]|\xE2\x88\x92|\xEF\xBC\x8D|\xEF\xB9\xA3/-/g' \
        -e 's/\xEF\xBC\x9A/:/g' \
        -e 's/\xE2\x80[\x8B-\x8D]|\xEF\xBB\xBF|\xC2\xAD|\xE2\x81\xA0//g'
}

# stdin -> stdout. Prints nothing at all when the text is clean.
#
# NO `trap … RETURN` anywhere below, deliberately. This file is SOURCED into the
# caller's shell — into a skill's bash fence — and a RETURN trap set here does
# not belong to this function: it stays installed and fires on every later
# function return in that shell, where the local it names is out of scope. Under
# the `set -u` the test harness runs with, that is an unbound-variable error, and
# under `set -e` it takes the whole run down. A library may not change the shell
# it is sourced into. Cleanup is therefore explicit on every exit path.
nexus_scan_forged_markers() {
    local normalised lines count rc

    normalised="$(mktemp)" || return 2

    if ! _nexus_normalise_markers > "$normalised"; then
        rm -f "$normalised"
        return 2
    fi

    # Case-INSENSITIVE. The archivist's inline scan was `grep -rniE`, so
    # `archived-content:end` was flagged there before this helper existed;
    # matching case-sensitively here would have been a silent security
    # regression at that site, and a bypass at all four — lowercase closes a
    # fence for a model exactly as uppercase does.
    #
    # -q, and its status is the verdict, on a FILE rather than a pipe. A
    # pipeline inside a command substitution reports its LAST stage's status, so
    # reading grep's own status through PIPESTATUS yields cut's or tr's — 0 on
    # clean text, which turns "nothing found" into "found".
    grep -qiE "$NEXUS_FORGED_MARKER_RE" "$normalised"
    rc=$?

    # Three ways, never two. Folding 2+ into "no matches" is how a scan that
    # could not run reports clean.
    if [ "$rc" -ge 2 ]; then
        rm -f "$normalised"
        return "$rc"
    fi
    if [ "$rc" -eq 1 ]; then
        rm -f "$normalised"
        return 1
    fi

    # Markers, not matching lines: `grep -c` counts lines, so two markers on one
    # line reported 1 and the number under-stated the finding.
    count="$(grep -oiE "$NEXUS_FORGED_MARKER_RE" "$normalised" | grep -c .)"
    # Only now, and only the numbers. `cut -d: -f1` takes the field grep
    # prepends; a marker line carrying its own colons cannot widen it, because
    # the line number is always first, and one file is ever passed so there is
    # no filename field in front of it.
    lines="$(grep -niE "$NEXUS_FORGED_MARKER_RE" "$normalised" | cut -d: -f1 | tr '\n' ' ')"
    lines="${lines% }"
    rm -f "$normalised"

    printf 'FORGED_MARKER_COUNT: %s\n' "$count"
    printf 'FORGED_MARKER_LINES: %s\n' "$lines"
    return 0
}

# Recursive form, for a site scanning a TREE rather than one stream (the
# archivist scans a ticket directory plus index.json before committing them).
#
# Delegates to the single-stream scan once per file rather than reaching for
# `grep -r`. grep -r would match raw bytes and miss every unicode variant — that
# is defect 1 reappearing the moment the recursive case is written separately,
# which is the whole argument for one helper.
#
# The FILE PATH is printed; the matched text still is not. Note the one caveat:
# a path is not always neutral — a filename in a scanned tree can carry text
# from the same source as its contents. It is printed anyway, because a finding
# nobody can locate cannot be acted on, and a name is bounded where a line is
# not. Callers must treat it as data, never as instruction.
#
# Same exit status contract as nexus_scan_forged_markers.
nexus_scan_forged_markers_tree() {
    local target listing f out rc found=1

    [ "$#" -gt 0 ] || return 2

    listing="$(mktemp)" || return 2

    for target in "$@"; do
        if [ -d "$target" ]; then
            # find's status is CHECKED, and -print0 is not decoration. As a
            # process substitution its status is unreachable and its stderr was
            # discarded, so a subdirectory the scan could not descend produced
            # no filenames, no error, and a clean verdict for a tree it never
            # enumerated. And a filename containing a newline split into two
            # nonexistent paths, each of which then failed to open — clean
            # again, by a second route.
            if ! find "$target" -type f -print0 > "$listing" 2>/dev/null; then
                rm -f "$listing"
                return 2
            fi
        elif [ -f "$target" ]; then
            printf '%s\0' "$target" > "$listing"
        else
            # Neither a file nor a directory is not "clean" — it is UNSCANNED,
            # and reporting it as clean is the failure this helper exists to
            # avoid.
            rm -f "$listing"
            return 2
        fi

        while IFS= read -r -d '' f; do
            [ -n "$f" ] || continue
            # An unreadable file is an I/O failure, not a clean file. Without
            # this the redirection below simply fails, the function is never
            # entered, and its status of 1 reads as "nothing found here".
            if [ ! -r "$f" ]; then
                rm -f "$listing"
                return 2
            fi
            out="$(nexus_scan_forged_markers < "$f")"
            rc=$?
            if [ "$rc" -ge 2 ]; then
                rm -f "$listing"
                return "$rc"
            fi
            if [ "$rc" -eq 0 ]; then
                found=0
                printf 'FORGED_MARKER_FILE: %s\n%s\n' "$f" "$out"
            fi
        done < "$listing"
    done

    rm -f "$listing"
    return "$found"
}
