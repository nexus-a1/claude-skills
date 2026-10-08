#!/usr/bin/env bash
# shellcheck shell=bash
#
# Redaction settings writer for /configuration-init (CL-122).
#
# The setup wizard builds a whole new configuration.yml and writes it, which
# used to drop a hand-written `redaction.pii.*` block on every reconfigure. This
# library adds the one block that carries the wizard's on/off answer and the
# previous personal-data class settings forward.
#
# The reader side lives in shared/pii-patterns.sh (nexus_redaction_output_mode,
# nexus_pii_config_flags): the hooks load that file on every Bash call, so this
# writer stays out of it. One parser, two callers — the writer re-reads what it
# wrote with the same functions the hook uses, so a block the hook would
# misread is never left behind.
#
# Sourced, not executed. Do not add `set -euo pipefail` at file scope — it would
# leak into the caller's shell (same rule as artifacts.sh).
#
# Nothing here reads a value into a command, a path or an argument. Class names
# are accepted only if the PII library names them, values only if they are the
# words `true` or `false`, and every line written is built from those fixed
# words (AC-SEC-2).

# nexus_redaction_write_block NEW_CONFIG PREVIOUS_CONFIG on|off
#
# Appends a top-level `redaction:` block to NEW_CONFIG (the file the wizard
# just wrote, which has none):
#   - `enabled: false` when the answer is `off`; nothing for `on`, because
#     absent already means on and the default lives in code;
#   - `pii:` with every class flag found in PREVIOUS_CONFIG, so an `ip: true`
#     survives a reconfigure. The previous `enabled` value is never carried:
#     the answer given now decides, so "keep on" after a past "off" ends up on.
# PREVIOUS_CONFIG may be empty or unreadable; then only the answer is written.
# When there is nothing to add (answer `on`, no class flags) the file is left
# untouched.
#
# The file is changed by copying it, appending to the copy, re-reading the copy
# with the hook's own resolver, and only then moving it into place. The original
# is never half-written: on any failure it is byte-for-byte what it was.
#
# Prints REDACTION_BLOCK=written or REDACTION_BLOCK=none on success. Returns
#   0 success, 2 bad arguments or missing library, 3 NEW_CONFIG already has a
#   top-level `redaction:` (the wizard never writes one, so this is drift),
#   4 the write or the read-back check failed.
nexus_redaction_write_block() {
    local new="${1-}" prev="${2-}" choice="${3-}"
    local lib name val flags="" expect_flags="" tmp expect_mode

    case "$choice" in
        on|off) : ;;
        *) echo "redaction: choice must be on or off" >&2; return 2 ;;
    esac
    if [ -z "$new" ] || [ ! -f "$new" ] || [ ! -r "$new" ] || [ ! -w "$new" ]; then
        echo "redaction: cannot update ${new:-<no path>}" >&2
        return 2
    fi

    # The PII library sits one directory above this file. CLAUDE_PLUGIN_ROOT is
    # not exported into Bash tool calls (CL-120), so the library's own location
    # is the one fact that is always true here.
    lib="${BASH_SOURCE[0]%/*}/../pii-patterns.sh"
    # shellcheck source=../pii-patterns.sh
    if ! . "$lib" 2>/dev/null \
       || ! type nexus_pii_config_flags >/dev/null 2>&1 \
       || ! type nexus_pii_is_class >/dev/null 2>&1 \
       || ! type nexus_redaction_output_mode >/dev/null 2>&1; then
        echo "redaction: cannot load the PII library at $lib" >&2
        return 2
    fi

    # A second top-level block would make the file's meaning depend on which one
    # a reader reaches first.
    if [ -L "$new" ]; then
        echo "redaction: $new is a symlink; not replacing it with a regular file" >&2
        return 2
    fi
    if grep -qE '^redaction:' "$new" 2>/dev/null; then
        echo "redaction: $new already has a top-level redaction: block; not adding another" >&2
        return 3
    fi

    if [ -n "$prev" ] && [ -r "$prev" ]; then
        while IFS="$(printf '\t')" read -r name val; do
            [ -n "$name" ] || continue
            nexus_pii_is_class "$name" || continue
            case "$val" in true|false) : ;; *) continue ;; esac
            flags="${flags}    ${name}: ${val}
"
            expect_flags="${expect_flags}${name}$(printf '\t')${val}
"
        done < <(nexus_pii_config_flags "$prev")
    fi

    if [ "$choice" = "on" ] && [ -z "$flags" ]; then
        echo "REDACTION_BLOCK=none"
        return 0
    fi

    tmp="$(mktemp "${new}.redaction.XXXXXX" 2>/dev/null)" || { echo "redaction: cannot create a temporary file beside $new" >&2; return 4; }
    if ! cp -p -- "$new" "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"; echo "redaction: cannot copy $new" >&2; return 4
    fi

    # The wizard's file normally ends in a newline; if it does not, the block
    # would be glued to the last line and read as part of it.
    if [ -s "$tmp" ]; then
        if [ "$(tail -c 1 "$tmp" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
            printf '\n' >> "$tmp" || { rm -f -- "$tmp"; echo "redaction: cannot append to the temporary copy" >&2; return 4; }
        fi
    fi
    {
        printf '\nredaction:\n'
        [ "$choice" = "off" ] && printf '  enabled: false\n'
        if [ -n "$flags" ]; then printf '  pii:\n%s' "$flags"; fi
    } >> "$tmp" || { rm -f -- "$tmp"; echo "redaction: cannot append to the temporary copy" >&2; return 4; }

    # Read it back with the resolver the hook uses. The answer and the carried
    # class flags must both come out as intended before the original is touched.
    expect_mode="on"; [ "$choice" = "off" ] && expect_mode="off"
    if [ "$(nexus_redaction_output_mode "$tmp" 2>/dev/null)" != "$expect_mode" ] \
       || [ "$(nexus_pii_config_flags "$tmp")" != "${expect_flags%$'\n'}" ]; then
        rm -f -- "$tmp"
        echo "redaction: the block did not read back as written; $new left unchanged" >&2
        return 4
    fi

    if ! mv -- "$tmp" "$new"; then
        rm -f -- "$tmp"; echo "redaction: cannot move the new file into place" >&2; return 4
    fi
    echo "REDACTION_BLOCK=written"
    return 0
}
