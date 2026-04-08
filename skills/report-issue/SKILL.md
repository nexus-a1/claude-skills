---
name: report-issue
model: sonnet
category: analysis
userInvocable: true
description: Draft and submit a bug report or feature request to the nexus plugin repository, using current conversation context to auto-populate details.
argument-hint: "[--feature-request]"
allowed-tools: "Read, Bash(gh issue create:*), Bash(gh auth status:*), Bash(jq:*), Bash(mktemp:*), AskUserQuestion"
---

# Report Issue

Arguments: $ARGUMENTS

Draft a GitHub issue for the nexus plugin repository based on the current conversation context. Invoke this immediately after noticing a bug or wanting to request a feature — while the context is still fresh.

## Usage

```bash
/report-issue                    # Report a bug (default)
/report-issue --feature-request  # Report a feature request
```

---

## Step 1: Determine Issue Type

Parse `$ARGUMENTS`:
- If `--feature-request` is present → `TYPE=feature-request`, label `enhancement`
- Otherwise → `TYPE=bug`, label `bug`

---

## Step 2: Early Auth Check

```bash
gh auth status 2>/dev/null
```

If the command fails (exit code non-zero), stop immediately:

```
⚠️  Not authenticated with GitHub. Run: gh auth login
Issue cannot be submitted without authentication.
```

---

## Step 3: Get Plugin Version

```bash
jq -r '.plugins["nexus@claude-skills"][0].version // "unknown"' \
  ~/.claude/plugins/installed_plugins.json 2>/dev/null || echo "unknown"
```

Store as `PLUGIN_VERSION`.

---

## Step 4: Build Draft from Conversation Context

Using the current conversation context, extract the following. Be concise — aim for enough detail to reproduce or understand the issue, not a full session dump.

### For `TYPE=bug`

Extract:
- **What happened** — the error or unexpected behavior observed
- **Error message** — exact error text if visible in the conversation (quote verbatim)
- **Context** — which skill or agent was running, what the user was trying to do
- **Trigger** — what action or input caused it

Compose the issue body using this template:

```markdown
## Description

{one-sentence summary of the bug}

## Error

{exact error message or observed behavior — quote verbatim if available, otherwise describe}

## Context

{what skill/agent was active, what the user was attempting to do}

## Steps to Reproduce

1. {step 1 derived from conversation context}
2. {step 2}
3. {add more if clear from context, otherwise omit}

## Environment

- Plugin version: {PLUGIN_VERSION}
```

### For `TYPE=feature-request`

Extract:
- **What capability is missing or needed** — derived from what the user was trying to do
- **Problem it solves** — why this matters based on the conversation

Compose the issue body using this template:

```markdown
## Description

{one-sentence summary of the requested feature}

## Problem

{what the user was trying to do and why the current behavior falls short}

## Proposed Behavior

{what the skill/agent/workflow should do instead}

## Context

{which skill or agent this relates to, if applicable}

## Environment

- Plugin version: {PLUGIN_VERSION}
```

Generate a concise issue title:
- Bug: `[bug] {skill-or-agent}: {short description}` — e.g., `[bug] nexus:commit: unknown skill nexus:git-operator error`
- Feature: `[feature] {short description}` — e.g., `[feature] report-issue: support attaching file paths`

---

## Step 5: Sensitivity Check

Before showing the draft, scan it for potentially sensitive content:

- Absolute paths containing personal directories (e.g., `/home/username/`, `/Users/username/myproject/`)
- Strings that look like tokens, API keys, or secrets (long random alphanumeric strings assigned to a variable)
- Internal hostnames or private URLs
- Project-specific names that weren't already part of the error/context

If any are found, flag them clearly:

```
⚠️  Sensitivity warning — the draft contains potentially private content:
  - Absolute path: /home/michal/code/myproject/ (consider omitting or generalizing)
  - [other items]

Review before confirming.
```

Replace or redact flagged items in the draft (e.g., `/home/[user]/code/myproject/` or `[project-path]`).

---

## Step 6: Show Draft and Ask for Additions

Display the full draft:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Issue Draft
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Repo:  nexus-a1/claude-skills
Type:  {bug | feature-request}
Label: {bug | enhancement}

Title: {title}

{body}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then use the AskUserQuestion tool:

```
header: "Add notes"
question: "Anything to add to this issue before sending?"
options: ["No, looks good", "Yes, I want to add a note"]
```

If the user selects "Yes", use AskUserQuestion again with an open prompt to collect their note.

If the user provides input, append it to the body under a `## Additional Notes` section.

---

## Step 7: Confirm and Submit

Use the AskUserQuestion tool to confirm:

```
header: "Confirm"
question: "Submit this issue to nexus-a1/claude-skills?"
options: ["Yes, submit", "No, cancel"]
```

If **No**: stop and display `Issue cancelled. Draft was not submitted.`

If **Yes**: write the body to a temp file and create the issue:

```bash
BODY_FILE=$(mktemp)
ERROR_FILE=$(mktemp)
cat > "$BODY_FILE" << 'ISSUE_BODY'
{full issue body}
ISSUE_BODY

gh issue create \
  --repo "nexus-a1/claude-skills" \
  --title "{title}" \
  --body-file "$BODY_FILE" \
  --label "{bug|enhancement}" 2>"$ERROR_FILE"

if [ $? -ne 0 ]; then
  if grep -qi "label" "$ERROR_FILE"; then
    # Label doesn't exist — retry without it
    gh issue create \
      --repo "nexus-a1/claude-skills" \
      --title "{title}" \
      --body-file "$BODY_FILE"
  else
    # Different error — surface it
    cat "$ERROR_FILE" >&2
    false
  fi
fi

rm -f "$BODY_FILE" "$ERROR_FILE"
```

> Using `--body-file` avoids shell quoting issues with error messages, stack traces, and special characters in the body. Stderr is captured to a temp file so label-not-found errors trigger a no-label fallback, while other errors (network, auth, repo not found) are surfaced to the user.

---

## Step 8: Report Result

On success:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Issue Submitted
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{issue URL}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

On failure:

```
⚠️  Could not create issue. gh error:
{error output}

The draft was not submitted. You can create it manually at:
https://github.com/nexus-a1/claude-skills/issues/new
```

---

## Error Handling

### `gh` not authenticated
```
⚠️  Not authenticated with GitHub. Run: gh auth login
```

### No conversation context to extract
If the conversation has no discernible error or feature request to base the draft on, use the AskUserQuestion tool to ask:

```
header: "Describe issue"
question: "What issue would you like to report?"
```

Use their response as the primary input for the draft.
