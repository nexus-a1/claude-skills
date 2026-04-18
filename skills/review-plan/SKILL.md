---
name: review-plan
model: claude-sonnet-4-6
category: planning
userInvocable: true
description: Validate an ad-hoc implementation plan through architect and quality-guard (and optionally security-auditor), then output a revised plan with adjustments applied.
argument-hint: "[plan text] [--security]"
allowed-tools: "Read, Glob, Grep, Bash, Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage"
---

# Review Plan

## Context

Arguments (if provided): $ARGUMENTS

## Configuration

```bash
# Source resolve-config: marketplace installs get ${CLAUDE_PLUGIN_ROOT} substituted
# inline before bash runs; ./install.sh users fall back to ~/.claude. If neither
# path resolves, fail loudly rather than letting resolve_artifact be undefined.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found. Install via marketplace or run ./install.sh" >&2
  exit 1
fi
REVIEW_EXEC_MODE=$(resolve_exec_mode review_plan team)
```

Use `$REVIEW_EXEC_MODE` to determine team vs sub-agent behavior in Step 3.

## Your Task

Take an ad-hoc implementation plan, run it through design-review agents (`architect`, `quality-guard`, and optionally `security-auditor`), and return a revised plan with their adjustments applied. Fills the gap between `/brainstorm` (ideation) and `/implement` (execution) — lightweight, stateless, no requirements file needed.

---

### 1. Parse Input

**Parse `$ARGUMENTS` into two parts:**

- `--security` flag (anywhere in arguments) → `SECURITY_OPT_IN=1`, strip the flag
- Remaining text → `PLAN_TEXT`

**If `PLAN_TEXT` is empty after stripping flags**, use AskUserQuestion to prompt:

- header: `"Plan"`
- question: `"What plan would you like reviewed?"`
- options:
  - `"Enter plan"` / `"I'll type the plan in the text field below"`
  - `"Cancel"` / `"Never mind, don't run the review"`

If user cancels, stop with: `No plan provided. Review cancelled.`

The user's response via the text input becomes `PLAN_TEXT`. If they enter nothing twice, stop with: `Cannot review an empty plan.`

---

### 2. Decide Which Agents Run

**Always run:** `architect`, `quality-guard`

**Run `security-auditor` if any of the following:**

1. `SECURITY_OPT_IN=1` (user passed `--security`)
2. `PLAN_TEXT` matches security heuristic — check with grep, case-insensitive, for any of: `auth`, `authn`, `authz`, `authentic`, `authoriz`, `password`, `credential`, `token`, `secret`, `permission`, `role`, `session`, `cookie`, `encrypt`, `decrypt`, `PII`, `sensitive`, `personal data`, `payment`, `card number`, `social security`, `SSN`

```bash
if [ "$SECURITY_OPT_IN" = "1" ] || echo "$PLAN_TEXT" | grep -qiE "auth(n|z|entic|oriz)|password|credential|token|secret|permission|role|session|cookie|encrypt|decrypt|pii|sensitive|personal data|payment|card number|social security|ssn"; then
  INCLUDE_SECURITY=1
else
  INCLUDE_SECURITY=0
fi
```

Report the decision to the user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Review Scope
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Agents:  architect, quality-guard{, security-auditor if included}
Trigger: {--security flag | security heuristic matched on "{matched keyword}" | default scope}
Mode:    $REVIEW_EXEC_MODE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

### 3. Run Review Agents

**If `$REVIEW_EXEC_MODE` = `"subagent"`:**

Run agents in parallel via a single message with multiple Task tool calls.

**Task 1 — Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Validate the following ad-hoc implementation plan against architecture patterns, design soundness, and structural concerns. This is a pre-implementation design review — the plan has NOT been implemented yet.

Plan:
{PLAN_TEXT}

Evaluate:
- Does the plan respect module boundaries and separation of concerns?
- Are there architectural anti-patterns or coupling issues?
- Does the approach align with existing patterns in the codebase? (Use Explore/Grep to verify)
- Are there missing steps, hidden dependencies, or unstated prerequisites?
- Is the scope coherent — does it do one thing well, or does it sprawl?
- Are there simpler alternatives that achieve the same outcome?

Return structured findings:
- CRITICAL: architectural flaws that would require rework
- IMPORTANT: design concerns the plan should address
- SUGGESTIONS: improvements that would strengthen the plan
```

**Task 2 — Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Challenge the following ad-hoc implementation plan (Level 1 — Plan Validation). Be adversarial. Push back on unverified assumptions.

Plan:
{PLAN_TEXT}

Verify:
- Does the plan address the actual problem, or a tangential one?
- Which claims in the plan are assumed vs verified against the code?
- Are success criteria concrete and measurable, or vague?
- What edge cases, failure modes, or interactions is the plan silent on?
- Is the plan's scope right — too narrow (misses root cause) or too broad (scope creep)?
- What would the plan break if executed as written?

Return structured findings:
- CRITICAL: claims that appear wrong, missing pieces that would cause the plan to fail
- IMPORTANT: assumptions that need verification before proceeding
- SUGGESTIONS: gaps worth addressing even if not blocking
```

**Task 3 (only if `INCLUDE_SECURITY=1`) — Use Task tool with `subagent_type: "security-auditor"`:**

```
Prompt: Review the following ad-hoc implementation plan for security concerns. This is pre-implementation — no code exists yet.

Plan:
{PLAN_TEXT}

Evaluate:
- Does the plan introduce authentication, authorization, or session-handling changes? Are they sound?
- Input validation, output encoding, injection surfaces
- Sensitive data handling (PII, credentials, tokens)
- Secret storage, key management
- Audit logging, access trails
- OWASP-relevant concerns for the described change

Return structured findings:
- CRITICAL: security flaws that must be fixed before implementation
- IMPORTANT: security concerns the plan should address
- SUGGESTIONS: defensive improvements
```

---

**If `$REVIEW_EXEC_MODE` = `"team"` (default):**

Create a review team for cross-pollination:

```
TeamCreate(team_name="review-plan-{short_hash_of_plan}")

TaskCreate: "Validate architecture" (T1)
  description: |
    Plan: {PLAN_TEXT}
    Review for architectural soundness, pattern alignment, scope coherence.
    Share findings with teammates — quality-guard will challenge claims.

TaskCreate: "Challenge plan assumptions" (T2)
  description: |
    Plan: {PLAN_TEXT}
    Adversarial Level-1 plan validation. Verify claims, surface assumptions,
    identify gaps. Use SendMessage to challenge architect's findings or push
    back on security-auditor if their scope bleeds into design.

[If INCLUDE_SECURITY=1]
TaskCreate: "Security review" (T3)
  description: |
    Plan: {PLAN_TEXT}
    Evaluate auth, data handling, injection surfaces, secrets, logging.
    Share findings with teammates.

[PARALLEL - Single message with multiple Task calls]
Task tool: name: "arch-review", subagent_type: "architect", team_name: "review-plan-{hash}"
Task tool: name: "plan-skeptic", subagent_type: "quality-guard", team_name: "review-plan-{hash}"
[If INCLUDE_SECURITY=1]
Task tool: name: "sec-review", subagent_type: "security-auditor", team_name: "review-plan-{hash}"
```

Assign tasks. Agents cross-pollinate findings via SendMessage. Collect results and TeamDelete.

---

### 4. Render Findings Report

Combine agent outputs into a single structured report:

```markdown
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Plan Review — Findings
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Original Plan

{PLAN_TEXT}

---

## 🔴 Critical

[Concerns that would cause the plan to fail or require rework if ignored]

- **[agent-name]** {finding}
- ...

## 🟡 Important

[Concerns the revised plan should address]

- **[agent-name]** {finding}
- ...

## 🔵 Suggestions

[Improvements worth considering]

- **[agent-name]** {finding}
- ...

{If security-auditor ran:}
## 🔒 Security

[Security-specific findings — may overlap with critical/important above, kept here for visibility]

---

## Verdict

**{One of: Plan is sound | Plan needs adjustments | Plan needs rework}**

{1-2 sentence summary of overall assessment}
```

**Verdict rubric:**
- `Plan is sound` — no critical findings, ≤ 1 important finding
- `Plan needs adjustments` — no critical findings, but multiple important findings to apply
- `Plan needs rework` — one or more critical findings

---

### 5. Produce Revised Plan

Incorporate agent feedback into a revised plan. Apply every CRITICAL finding, every IMPORTANT finding, and SUGGESTIONS where they clearly strengthen the plan without bloating scope.

Render below the findings report:

```markdown
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Revised Plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{Full revised plan — self-contained, ready to paste into /nexus:implement or use as a working spec. Preserve the intent of the original plan; integrate adjustments inline rather than tacking them on at the end.}

---

### Changes from Original

- {bullet per significant change, citing the agent whose finding drove it}
- ...
```

**Rules for the revised plan:**

- **Self-contained** — must stand alone without needing to re-read the findings
- **Preserve intent** — do not redirect the plan to a different problem, only strengthen the stated one
- **No scope creep** — if a finding suggests addressing a separate concern, note it as a follow-up rather than silently expanding scope
- **Flag unresolved concerns** — if a CRITICAL finding cannot be resolved without user input (e.g., a design choice with real trade-offs), call it out explicitly at the end instead of silently picking one

**If the verdict is `Plan needs rework`** and a critical finding requires a design decision the skill cannot make alone, use AskUserQuestion to surface the decision before producing the revised plan. Give the user the option to defer (skill emits an "unresolved" version) or pick an answer that the skill then incorporates.

---

### 6. Close

Display a one-line next-step hint:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Done. Hand the Revised Plan to /nexus:implement, or iterate by re-running /nexus:review-plan with the updated version.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Handling

- **`resolve-config.sh` missing** — handled in the Configuration block; hard-stop with install instructions.
- **Empty plan after flag stripping** — prompt via AskUserQuestion; if still empty twice, stop.
- **Agent failure (Task returns error)** — surface the error, note which agent failed, continue with the others. Only the `architect` path is strictly required; if it fails, stop with a clear error.
- **Security heuristic false positive** — the opt-in decision is reported in Step 2; if the user finds it noisy, they can argue for a tighter heuristic via `/nexus:feedback`.

---

## Important Notes

- **Stateless** — no work files, no state directory, no ticket binding. Everything lives in the conversation output.
- **Pre-implementation only** — agents review the *plan*, not code. They have no implementation to inspect; findings are necessarily about design and assumptions.
- **Parallel agents** — always run in parallel; the skeptic (`quality-guard`) challenges the other agents' findings in team mode.
- **Not a substitute for `/implement` QA** — `/implement` still runs its own code-level review phase. `/nexus:review-plan` catches design problems *before* they become code.
- **Not a replacement for `/brainstorm`** — `/brainstorm` generates options; `/nexus:review-plan` validates a chosen approach. Use them in sequence if the plan is still half-formed.

## Examples

### Example 1: Quick review of a sketched plan

```bash
/nexus:review-plan Extract the auth middleware into its own package so we can share it with the admin app
```

Security-auditor auto-included (heuristic matched `auth`). Output: findings report + revised plan that likely calls out shared-state concerns, versioning of the extracted package, and test coverage gaps.

### Example 2: Explicit security opt-in on a non-obvious plan

```bash
/nexus:review-plan --security Switch our session store from in-memory to Redis so horizontal scaling works
```

Security-auditor included via flag (even though the heuristic would have matched `session` anyway). Findings will cover at-rest encryption, credential handling for the Redis connection, key rotation, and failure modes.

### Example 3: Interactive

```bash
/nexus:review-plan
```

Prompts for plan text, then proceeds.
