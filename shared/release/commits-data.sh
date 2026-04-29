#!/usr/bin/env bash
# plugin/shared/release/commits-data.sh
#
# Pure data emitter: given two refs, emit JSON describing the commits
# between them. Used by /create-release (PR body authoring) and /release
# (release-notes authoring) to give the LLM a structured input instead of
# making it re-derive the data from raw git output.
#
# Usage:
#   bash commits-data.sh --base=<ref> --head=<ref> [--json]
#
# Output (with --json — default and only mode for now):
#   {
#     "base": "master",
#     "head": "release/v1.2.0",
#     "commit_count": 12,
#     "file_count": 47,
#     "tickets": ["JIRA-123", "JIRA-456"],
#     "breakdown": { "feat": 4, "fix": 6, "chore": 1, "docs": 1, "other": 0 },
#     "has_breaking_change": false,
#     "commits": [
#       { "sha": "abcd1234", "subject": "feat: ...", "type": "feat",
#         "scope": "...", "tickets": [...], "breaking": false }
#     ]
#   }
#
# Conventional commit detection follows the standard regex
# `^<type>(\(<scope>\))?(!)?: <subject>` with `!` or a `BREAKING CHANGE:`
# trailer marking a breaking change.
#
# Ticket extraction matches `[JIRA-123]`, `JIRA-123:`, `jira-123:` (case-
# insensitive on the project key, dedup'd uppercase in output).
#
# Exit codes:
#   0  EX_OK
#   20 EX_USER     — bad args (missing refs, refs don't resolve)
#   30 EX_SYSTEM   — git failure
set -euo pipefail

PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PLUGIN_RELEASE_DIR/lib.sh"

base=""
head=""

while (( $# > 0 )); do
  case "$1" in
    --base=*) base="${1#--base=}"; shift ;;
    --base)   base="${2:-}"; shift 2 ;;
    --head=*) head="${1#--head=}"; shift ;;
    --head)   head="${2:-}"; shift 2 ;;
    --json)   shift ;;
    *) _die "$EX_SYSTEM" "commits-data.sh: unknown arg '$1'" ;;
  esac
done

[[ -z "$base" ]] && _die "$EX_USER" "commits-data.sh: --base is required"
[[ -z "$head" ]] && _die "$EX_USER" "commits-data.sh: --head is required"

# Defensive: reject leading-dash refs.
if [[ "$base" == -* ]]; then _die "$EX_USER" "Invalid --base: '$base' must not start with '-'"; fi
if [[ "$head" == -* ]]; then _die "$EX_USER" "Invalid --head: '$head' must not start with '-'"; fi

_require_git_repo
if ! _have_jq; then _die "$EX_SYSTEM" "commits-data.sh: jq is required"; fi

# Resolve refs.
base_resolved=""
if base_resolved=$(_resolve_branch_ref "$base" 2>/dev/null); then
  : # ok
elif git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
  base_resolved="$base"
else
  _die "$EX_USER" "Cannot resolve --base ref: '$base'"
fi

head_resolved=""
if head_resolved=$(_resolve_branch_ref "$head" 2>/dev/null); then
  :
elif git rev-parse --verify --quiet "$head" >/dev/null 2>&1; then
  head_resolved="$head"
else
  _die "$EX_USER" "Cannot resolve --head ref: '$head'"
fi

# Build a JSON array of commit records using a single git log invocation
# with %x1f as a field separator (RS) and %x1e between records (FS).
# Format: <sha>\x1f<subject>\x1f<body>\x1e
RS=$'\x1e'
FS=$'\x1f'

raw=$(git log --format="%H${FS}%s${FS}%B${RS}" "${base_resolved}..${head_resolved}" 2>&1) \
  || _die "$EX_SYSTEM" "git log failed: $raw"

# File count for the diff range.
file_count=0
if [[ -n "$raw" ]]; then
  file_count=$(git diff --name-only "${base_resolved}..${head_resolved}" 2>/dev/null | grep -c . || true)
fi

# Ticket regex: capture project key + number. Examples that match:
#   [JIRA-123] subject       — anchored to leading bracket
#   JIRA-123: subject        — at start of subject
#   ... see JIRA-123 ...     — anywhere in body
# Single-digit tickets (PROJ-1, JIRA-9) are included. Algorithm names like
# SHA-1 and SHA-256 are accepted false positives.
TICKET_RE='[A-Za-z][A-Za-z0-9]+-[0-9]+'

# Walk the records.
commits_jsonl=""
all_tickets=""
breakdown_feat=0
breakdown_fix=0
breakdown_chore=0
breakdown_docs=0
breakdown_refactor=0
breakdown_test=0
breakdown_perf=0
breakdown_style=0
breakdown_build=0
breakdown_ci=0
breakdown_other=0
has_breaking="false"

# Use awk-style splitting via parameter expansion in a loop.
# IFS-based read won't work cleanly here because subjects may contain anything.
# We rely on the unique \x1e/\x1f bytes git can't normally produce.
while IFS= read -r -d "$RS" record; do
  [[ -z "$record" ]] && continue

  # Strip leading and trailing newlines (git log emits \n between records
  # and %B retains its own trailing newline).
  record="${record#$'\n'}"
  record="${record%$'\n'}"

  # Split into sha / subject / body.
  sha="${record%%"${FS}"*}"
  rest="${record#*"${FS}"}"
  subject="${rest%%"${FS}"*}"
  body="${rest#*"${FS}"}"

  # Detect conventional commit type and breaking marker. House style allows
  # an optional `[TICKET] ` prefix before the conventional-commit header.
  type=""
  scope=""
  breaking="false"
  CC_RE='^(\[[A-Z][A-Z0-9]+-[0-9]+\] )?([a-z]+)(\(([^)]+)\))?(!)?: (.*)$'
  if [[ "$subject" =~ $CC_RE ]]; then
    type="${BASH_REMATCH[2]}"
    scope="${BASH_REMATCH[4]}"
    [[ -n "${BASH_REMATCH[5]}" ]] && breaking="true"
  fi
  # `BREAKING CHANGE:` trailer overrides.
  if printf '%s\n' "$body" | grep -qE '^BREAKING CHANGE:'; then
    breaking="true"
  fi
  if [[ "$breaking" == "true" ]]; then has_breaking="true"; fi

  # Increment breakdown counters.
  case "$type" in
    feat)     breakdown_feat=$((breakdown_feat + 1)) ;;
    fix)      breakdown_fix=$((breakdown_fix + 1)) ;;
    chore)    breakdown_chore=$((breakdown_chore + 1)) ;;
    docs)     breakdown_docs=$((breakdown_docs + 1)) ;;
    refactor) breakdown_refactor=$((breakdown_refactor + 1)) ;;
    test)     breakdown_test=$((breakdown_test + 1)) ;;
    perf)     breakdown_perf=$((breakdown_perf + 1)) ;;
    style)    breakdown_style=$((breakdown_style + 1)) ;;
    build)    breakdown_build=$((breakdown_build + 1)) ;;
    ci)       breakdown_ci=$((breakdown_ci + 1)) ;;
    *)        breakdown_other=$((breakdown_other + 1)) ;;
  esac

  # Extract tickets from subject + body.
  msg_combined="$subject"$'\n'"$body"
  commit_tickets=()
  while IFS= read -r match; do
    [[ -n "$match" ]] && commit_tickets+=("$(printf '%s' "$match" | tr '[:lower:]' '[:upper:]')")
  done < <(printf '%s\n' "$msg_combined" | grep -ioE "$TICKET_RE" | sort -u)

  # Append to global tickets list.
  for t in "${commit_tickets[@]+"${commit_tickets[@]}"}"; do
    all_tickets="$all_tickets"$'\n'"$t"
  done

  # Build the per-commit JSON object.
  tickets_json=$(printf '%s\n' "${commit_tickets[@]+"${commit_tickets[@]}"}" \
    | jq -R . | jq -s 'map(select(. != ""))')
  commit_json=$(jq -nc \
    --arg sha      "$sha" \
    --arg short    "${sha:0:7}" \
    --arg subject  "$subject" \
    --arg type     "$type" \
    --arg scope    "$scope" \
    --argjson tickets "$tickets_json" \
    --arg breaking "$breaking" \
    '{
      sha: $sha, short: $short, subject: $subject,
      type:    (if $type    == "" then null else $type    end),
      scope:   (if $scope   == "" then null else $scope   end),
      tickets: $tickets,
      breaking: ($breaking == "true")
    }')
  commits_jsonl="$commits_jsonl$commit_json"$'\n'
done < <(printf '%s' "$raw")

# Build commits array and unique tickets list via jq.
commits_array=$(printf '%s' "$commits_jsonl" | jq -s '.')
commit_count=$(printf '%s' "$commits_array" | jq 'length')

unique_tickets=$(printf '%s' "$all_tickets" \
  | { grep -v '^$' || true; } \
  | sort -u \
  | jq -R . | jq -s '.')
if [[ -z "$unique_tickets" ]]; then
  unique_tickets='[]'
fi

# Final output.
jq -n \
  --arg base "$base_resolved" \
  --arg head "$head_resolved" \
  --argjson commit_count "$commit_count" \
  --argjson file_count   "$file_count" \
  --argjson tickets      "$unique_tickets" \
  --argjson commits      "$commits_array" \
  --arg has_breaking     "$has_breaking" \
  --argjson b_feat       "$breakdown_feat" \
  --argjson b_fix        "$breakdown_fix" \
  --argjson b_chore      "$breakdown_chore" \
  --argjson b_docs       "$breakdown_docs" \
  --argjson b_refactor   "$breakdown_refactor" \
  --argjson b_test       "$breakdown_test" \
  --argjson b_perf       "$breakdown_perf" \
  --argjson b_style      "$breakdown_style" \
  --argjson b_build      "$breakdown_build" \
  --argjson b_ci         "$breakdown_ci" \
  --argjson b_other      "$breakdown_other" \
  '{
    base: $base, head: $head,
    commit_count: $commit_count,
    file_count:   $file_count,
    tickets:      $tickets,
    has_breaking_change: ($has_breaking == "true"),
    breakdown: {
      feat: $b_feat, fix: $b_fix, chore: $b_chore, docs: $b_docs,
      refactor: $b_refactor, test: $b_test, perf: $b_perf, style: $b_style,
      build: $b_build, ci: $b_ci, other: $b_other
    },
    commits: $commits
  }'

exit "$EX_OK"
