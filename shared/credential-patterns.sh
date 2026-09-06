#!/bin/bash
# credential-patterns.sh
# Single source of truth for the baseline credential pattern list, plus a
# redaction helper for text that is about to be written to disk.
#
# Two consumers today:
#   - plugin/hooks/credential-scan.sh   — detects, blocks a commit
#   - the /pr-review report writer       — redacts, before the file is written
#
# Extracted from credential-scan.sh so the second consumer does not have to
# duplicate the list. Duplicated patterns drift; a drifted redaction list is
# worse than no redaction, because it reads as protection.
#
# Usage:
#   source /path/to/credential-patterns.sh
#   "${NEXUS_CREDENTIAL_PATTERNS[@]}"        # entries are 'Label|regex'
#   redact_credentials <<<"$text"            # stdin -> stdout, matches masked
#
# Sourcing contract: this file MUST be sourced with a hard failure on absence.
# A consumer that skips it silently ends up with an empty pattern list and
# reports clean on every input. See the note in credential-scan.sh.

# Baseline list (conservative). Format is 'Label|regex' — label up to the first
# pipe, ERE pattern after it. No pattern below may itself contain a pipe.
NEXUS_CREDENTIAL_PATTERNS=(
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

# Files whose CONTENT is assumed sensitive by name alone. Consumed by
# plugin/hooks/read-guard.sh, which refuses the Read tool on them and points
# the model at `cat`, whose output the redact-output hook filters. Shell
# globs, matched against the basename with `case`; an entry containing `/`
# is matched against the full path instead.
#
# Name-based, so it is a floor, not the check: the credential scan and the
# stream redactor match on content and catch a key in an innocently named
# file. Keep this list to files that exist to hold secrets.
NEXUS_SENSITIVE_PATH_GLOBS=(
    '.env'
    '.env.*'
    '*.env'
    '.envrc'
    '*.pem'
    '*.key'
    '*.p12'
    '*.pfx'
    '*.jks'
    '*.keystore'
    'id_rsa*'
    'id_dsa*'
    'id_ecdsa*'
    'id_ed25519*'
    '*credentials*'
    '.netrc'
    '_netrc'
    '.npmrc'
    '.pypirc'
    '.git-credentials'
    'dataSources.xml'
    'secrets.yml'
    'secrets.yaml'
    'secrets.json'
    '*/.aws/config'
    '*/.docker/config.json'
    '*/.kube/config'
    # The redaction session map: every value the redact-output hook replaced,
    # in clear. Reading it with the Read tool would undo the whole layer.
    'redaction-map.tsv'
    '*/.claude/session-state'
    '*/.claude/session-state/*'
)

# Emit the ERE patterns this project should redact with.
#
# Mirrors the two-tier resolution credential-scan.sh uses at detection time:
# a project carrying its own .gitleaks.toml has custom rules, and redaction
# that ignored them would leave that project's real secrets in a report while
# its commit hook blocks them — protection at one gate and none at the other.
#
# LIMITATION, stated rather than hidden: gitleaks rules are TOML and may use
# features an ERE grep cannot express (allowlists, entropy thresholds,
# multiline). This extracts single-line `regex = "..."` / `regex = '...'`
# values and unions them with the baseline. It is strictly additive — a
# .gitleaks.toml can only widen redaction here, never narrow it — so a rule
# that fails to extract degrades to baseline coverage rather than to none.
nexus_redaction_patterns() {
    local entry
    for entry in "${NEXUS_CREDENTIAL_PATTERNS[@]}"; do
        printf '%s\n' "${entry#*|}"
    done

    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    [[ -n "$repo_root" && -f "$repo_root/.gitleaks.toml" ]] || return 0

    # Single-line regex = "..." or regex = '...' assignments.
    sed -nE "s/^[[:space:]]*regex[[:space:]]*=[[:space:]]*[\"'](.*)[\"'][[:space:]]*$/\1/p" \
        "$repo_root/.gitleaks.toml" 2>/dev/null || true
}

# Redact credential matches on stdin, writing to stdout.
#
# Each match is replaced with the literal [REDACTED] so a reader can see that
# something was removed rather than silently reading altered evidence. Text
# that matches nothing passes through unchanged.
#
# Fails closed: with no patterns available it returns non-zero and emits
# nothing, so a caller that ignores the status still does not get unredacted
# text on stdout. The alternative — passing input through on failure — would
# turn a broken redactor into a leak.
redact_credentials() {
    local -a pats=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && pats+=("$p")
    done < <(nexus_redaction_patterns)

    if [[ ${#pats[@]} -eq 0 ]]; then
        echo "redact_credentials: no patterns available — refusing to emit unredacted text" >&2
        return 1
    fi

    # One -e per pattern. `@` is the delimiter, so any `@` inside a pattern is
    # escaped first; otherwise a pattern containing one would terminate the
    # s/// expression early and sed would fail or, worse, substitute wrongly.
    local -a sed_args=()
    for p in "${pats[@]}"; do
        sed_args+=(-e "s@${p//@/\\@}@[REDACTED]@g")
    done
    sed -E "${sed_args[@]}"
}
