#!/bin/bash
# PreToolUse Hook: Enforce git-mutation policy directly on Bash commands.
#
# Policy (enforced regardless of caller):
#   1. Block pushes to protected branches (main, master, release/*).
#   2. Scan staged files for credentials before every commit.
#   3. Block push unless security-auditor confirmed the current HEAD
#      (state file at .claude/session-state/git-audit.json).
#
# Explicit bypasses (logged to stderr, never silent):
#   GIT_AUTHORIZED=1             — legacy bypass. Skips ALL checks below.
#                                  Kept for backward compatibility with existing
#                                  git-operator callers and release skills.
#   SECURITY_AUDITOR_BYPASS=1    — skip only the security-auditor state check
#                                  (branch protection + credential scan still run).
#
# Scope: this guard only inspects Bash tool calls. Other tools are untouched.

set -u

input="${CLAUDE_TOOL_INPUT:-}"

# Fast exit: not a git command.
if [[ ! "$input" =~ (^|[[:space:]])git[[:space:]] ]]; then
    exit 0
fi

# Legacy bypass — keep commands issued by existing git-operator callers and
# the release skills working without rewriting every caller at once.
if [[ "$input" =~ ^GIT_AUTHORIZED=1[[:space:]]+git[[:space:]] ]]; then
    exit 0
fi

# Strip leading env assignments (KEY=val ... git <subcmd>) we know about so
# the mutation regexes below see the git invocation cleanly.
cmd="$input"
while [[ "$cmd" =~ ^[[:space:]]*(GIT_AUTHORIZED|SECURITY_AUDITOR_BYPASS)=[^[:space:]]+[[:space:]]+(.*)$ ]]; do
    cmd="${BASH_REMATCH[2]}"
done

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)

# ---------------------------------------------------------------------------
# 1. Branch protection + security-auditor gate on push
# ---------------------------------------------------------------------------
if [[ "$cmd" =~ ^[[:space:]]*git[[:space:]]+push([[:space:]]|$) ]]; then
    current_branch=$(git branch --show-current 2>/dev/null || true)
    case "$current_branch" in
        main|master|release/*)
            # Allow the initial creating push (remote branch doesn't exist yet).
            # Subsequent pushes to an existing protected branch must go through a PR.
            if git ls-remote --exit-code --heads origin "$current_branch" >/dev/null 2>&1; then
                echo "BLOCKED: direct push to protected branch '$current_branch'." >&2
                echo "Remote branch already exists — subsequent changes must go through a PR." >&2
                exit 2
            fi
            ;;
    esac

    if [[ "${SECURITY_AUDITOR_BYPASS:-}" != "1" ]]; then
        state_file="$repo_root/.claude/session-state/git-audit.json"
        head_sha=$(git rev-parse HEAD 2>/dev/null || true)
        if [[ ! -f "$state_file" ]]; then
            echo "BLOCKED: push requires a security-auditor confirmation." >&2
            echo "Run the security-auditor agent on the staged/committed changes first." >&2
            echo "State file expected at: $state_file" >&2
            exit 2
        fi
        recorded_sha=$(grep -o '"head_sha": *"[^"]*"' "$state_file" | grep -o '[^"]*"$' | tr -d '"' 2>/dev/null || true)
        recorded_branch=$(grep -o '"branch": *"[^"]*"' "$state_file" | grep -o '[^"]*"$' | tr -d '"' 2>/dev/null || true)
        if [[ "$recorded_sha" != "$head_sha" || "$recorded_branch" != "$current_branch" ]]; then
            echo "BLOCKED: security-auditor confirmation is stale." >&2
            echo "  Audited: ${recorded_branch:-<unknown>} @ ${recorded_sha:-<unknown>}" >&2
            echo "  Current: $current_branch @ $head_sha" >&2
            echo "Re-run security-auditor on the current HEAD before pushing." >&2
            exit 2
        fi
    else
        echo "WARN: SECURITY_AUDITOR_BYPASS=1 — skipping audit state check." >&2
    fi
fi

# ---------------------------------------------------------------------------
# 2. Credential scan on commit
# ---------------------------------------------------------------------------
if [[ "$cmd" =~ ^[[:space:]]*git[[:space:]]+commit([[:space:]]|$) ]]; then
    mapfile -t staged < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
    extra=()
    # `git commit -a` / `--all` also stages all modified tracked files.
    if [[ "$cmd" =~ git[[:space:]]+commit[[:space:]]+(-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|$) ]]; then
        mapfile -t extra < <(git diff --name-only --diff-filter=ACM 2>/dev/null)
    fi
    targets=()
    for f in "${staged[@]}" "${extra[@]}"; do
        [[ -n "$f" && -f "$repo_root/$f" ]] && targets+=("$repo_root/$f")
    done

    if (( ${#targets[@]} > 0 )); then
        scanner="$(dirname "$0")/credential-scan.sh"
        if [[ -x "$scanner" ]]; then
            if ! "$scanner" "${targets[@]}" >&2; then
                echo "BLOCKED: credential-scan findings above. Commit refused." >&2
                echo "Resolve the finding, or use GIT_AUTHORIZED=1 git commit … to bypass all checks (legacy; document the reason in the commit body)." >&2
                exit 2
            fi
        fi
    fi
fi

exit 0
