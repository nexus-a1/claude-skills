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

# Inline pattern list (conservative baseline).
patterns=(
    'Anthropic API key|sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{24,}'
    'OpenAI/generic sk- key|sk-[A-Za-z0-9]{32,}'
    'GitHub PAT|ghp_[A-Za-z0-9]{36}'
    'GitHub OAuth token|gho_[A-Za-z0-9]{36}'
    'GitHub user-to-server token|ghu_[A-Za-z0-9]{36}'
    'GitHub server-to-server token|ghs_[A-Za-z0-9]{36}'
    'GitHub refresh token|ghr_[A-Za-z0-9]{36}'
    'GitHub fine-grained PAT|github_pat_[A-Za-z0-9_]{22}_[A-Za-z0-9]{59}'
    'AWS access key ID|AKIA[0-9A-Z]{16}'
    'AWS temporary access key|ASIA[0-9A-Z]{16}'
    'Slack token|xox[baprs]-[A-Za-z0-9-]{10,}'
    'Discord webhook URL|https://discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+'
    'Google API key|AIza[0-9A-Za-z_-]{35}'
    'Stripe live secret key|sk_live_[A-Za-z0-9]{24,}'
    'Stripe restricted key|rk_live_[A-Za-z0-9]{24,}'
    'Private key (PEM)|-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'JWT token|eyJ[A-Za-z0-9_=-]+\.eyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_.+/=-]{20,}'
)

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
        done < <(grep -InHE "$pattern" "$f" 2>/dev/null || true)
    done
done

if (( total > 0 )); then
    echo "credential-scan: ${total} match(es) detected." >&2
    exit 1
fi
exit 0
