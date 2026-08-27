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
# Exit:
#   0 — clean
#   1 — findings (printed to stderr as `credential-scan: <file>:<line> — <label>`)
#   2 — usage error

set -u

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <file1> [file2 ...]" >&2
    exit 2
fi

# Prefer gitleaks when available with a project config.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if command -v gitleaks >/dev/null 2>&1 && [[ -n "$repo_root" && -f "$repo_root/.gitleaks.toml" ]]; then
    any_findings=0
    for f in "$@"; do
        [[ -f "$f" && -s "$f" ]] || continue
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
    for entry in "${patterns[@]}"; do
        label="${entry%%|*}"
        pattern="${entry#*|}"
        while IFS=: read -r fname lineno _rest; do
            [[ -z "$lineno" ]] && continue
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
