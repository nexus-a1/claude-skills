#!/bin/bash
# credential-scan.sh
# Scan files for embedded credentials. Filename-based exclusion (.env, etc.)
# is not enough — this catches tokens, API keys, private keys, and webhooks
# embedded in otherwise-innocuous files.
#
# Usage:
#   credential-scan.sh <file1> [file2 ...]
#
# Prefers `gitleaks` + repo-local `.gitleaks.toml` when both are present.
# Otherwise runs the inline pattern list.
#
# TEST-FIXTURE MARKER (CL-114). A line under a `tests/` directory that carries
#   nexus-credential-scan:fixture
# is not reported. Both halves are required and both are deliberate:
#
#   * PER LINE, not per file or per path. A `tests/**` allowlist would make every
#     line of every test file a place a real key could sit unnoticed. Marking the
#     exact line keeps the exemption visible in any diff that adds one.
#   * ONLY under tests/, measured RELATIVE TO THE REPOSITORY ROOT. Without the
#     marker the scanner would be silenced anywhere the string was pasted —
#     including a .env or a plugin source file, which is the one thing this hook
#     exists to stop. And without the *relative* part, a checkout sitting under
#     any directory named `tests` would make its whole repository eligible,
#     which is the same hole one level up.
#
# It exists because the scanner's OWN test corpus is credential-shaped by
# necessity: tests/hooks/*.test hold invented AKIA-shaped strings so the
# aws-access-key-id rule has something to match. Before this, editing a comment
# in one of those files required CREDENTIAL_SCAN_BYPASS=1, which trains the habit
# of overriding a gate whose whole value is that overriding it feels significant.
#
# A real credential in a test file is still reported unless someone marks that
# exact line. That residual is the accepted cost of this direction; the
# alternative considered was scanning the diff rather than the file, which fixes
# more and risks more (a credential already committed and merely moved would stop
# being flagged). See CL-114 for the tradeoff as decided.
#
# Exit:
#   0 — clean
#   1 — findings (printed to stderr as `credential-scan: <file>:<line> — <label>`)
#   2 — usage error

set -u

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <file1> [file2 ...]" >&2
    exit 2
fi

# The fixture marker. Defined before either scanning path so both can see it.
NEXUS_CRED_FIXTURE_MARKER='nexus-credential-scan:fixture'

# Prefer gitleaks when available with a project config.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if command -v gitleaks >/dev/null 2>&1 && [[ -n "$repo_root" && -f "$repo_root/.gitleaks.toml" ]]; then
    any_findings=0
    for f in "$@"; do
        [[ -f "$f" && -s "$f" ]] || continue
        # gitleaks has its own allowlist mechanism and does not know about our
        # marker. Say so rather than letting it look effective: a marker that is
        # silently ignored is worse than no marker, because the author believes
        # the line is covered. Warn once per file that carries one.
        if grep -qF -- "$NEXUS_CRED_FIXTURE_MARKER" "$f" 2>/dev/null; then
            echo "credential-scan: NOTE — $f carries ${NEXUS_CRED_FIXTURE_MARKER}, which the gitleaks path does not honour. Add an allowlist entry to $repo_root/.gitleaks.toml if gitleaks reports it." >&2
        fi
        if ! gitleaks detect --no-git --redact --config "$repo_root/.gitleaks.toml" --source "$f" >&2; then
            any_findings=1
        fi
    done
    exit "$any_findings"
fi

# Inline pattern list (conservative baseline), sourced from the shared library
# so the /pr-review report redactor uses the same list rather than a copy.
#
# HARD FAIL on absence, deliberately. This is a security control: if the
# library is missing or unreadable and we continued, `patterns` would be empty,
# every loop below would match nothing, and the hook would exit 0 on a file
# full of live credentials — reporting clean because it checked nothing. The
# permissive `[[ -x ... ]] || skip` pattern used elsewhere for optional tooling
# is wrong here for exactly that reason.
_cred_lib="$(dirname "${BASH_SOURCE[0]}")/../shared/credential-patterns.sh"
if [[ ! -r "$_cred_lib" ]]; then
    echo "credential-scan: FATAL — cannot read $_cred_lib" >&2
    echo "credential-scan: refusing to scan with an empty pattern list." >&2
    exit 2
fi
# shellcheck source=../shared/credential-patterns.sh
source "$_cred_lib"

if [[ ${#NEXUS_CREDENTIAL_PATTERNS[@]} -eq 0 ]]; then
    echo "credential-scan: FATAL — pattern list loaded but empty." >&2
    exit 2
fi

patterns=("${NEXUS_CREDENTIAL_PATTERNS[@]}")

total=0
for f in "$@"; do
    [[ -f "$f" && -s "$f" ]] || continue
    # Is this file eligible for the fixture marker at all? Decided once per file,
    # before any line is examined, from the path RELATIVE TO ITS REPOSITORY.
    #
    # THE RELATIVE PART IS THE WHOLE GUARD. git-mutation-guard.sh:427 hands this
    # scanner "$repo_root/$f" — an absolute path. Testing that absolutely made
    # every file in the repository eligible for anyone whose checkout happens to
    # sit under a directory named `tests` (~/tests/myrepo/, a CI workspace for a
    # repo named `tests`), which is exactly the repository-wide allowlist this
    # design rejected. Caught by a Fable second-opinion review before merge.
    #
    # Fails closed in every uncertain case: no git, not inside a repository, or
    # a path we cannot place under its own root leaves the marker inert and the
    # fixture reported. A nuisance is the safe direction here; a missed
    # credential is not.
    _fixtures_allowed=0
    case "$f" in
        # Cheap pre-filter so the common case costs no subprocess at all: a path
        # with no `tests` component anywhere cannot qualify however it resolves.
        *tests*)
            # ${f%/*}, not $(dirname): dirname is external, and a PATH without
            # it would make the directory empty and the git call answer for the
            # wrong tree.
            _f_dir="${f%/*}"
            _f_root=$(git -C "$_f_dir" rev-parse --show-toplevel 2>/dev/null || true)
            if [[ -n "$_f_root" && "$f" == "$_f_root"/* ]]; then
                case "${f#"$_f_root"/}" in
                    tests/*|*/tests/*) _fixtures_allowed=1 ;;
                esac
            fi
            ;;
    esac
    for entry in "${patterns[@]}"; do
        label="${entry%%|*}"
        pattern="${entry#*|}"
        while IFS=: read -r fname lineno _rest; do
            [[ -z "$lineno" ]] && continue
            # `_rest` is everything grep printed after file:line — the matching
            # line itself. Checked with a literal comparison, never a regex, so
            # nothing in the marker is interpreted.
            if (( _fixtures_allowed )) && [[ "$_rest" == *"$NEXUS_CRED_FIXTURE_MARKER"* ]]; then
                continue
            fi
            echo "credential-scan: ${fname}:${lineno} — ${label}" >&2
            total=$((total + 1))
        done < <(grep -InHE -- "$pattern" "$f" 2>/dev/null || true)
    done
done

if (( total > 0 )); then
    echo "credential-scan: ${total} match(es) detected." >&2
    exit 1
fi
exit 0
