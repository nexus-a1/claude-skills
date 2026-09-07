---
name: troubleshoot
category: implementation
model: claude-opus-5
userInvocable: true
description: Systematically troubleshoot a failing feature or error. Discovers code, investigates root cause, applies fix, verifies with tests, and commits. Use when something isn't working as expected. Runs in the current working tree by default — set `worktree.enabled: true` in `.claude/configuration.yml` to isolate work in a git worktree.
argument-hint: <error-or-description>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, Workflow, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage, EnterWorktree, ExitWorktree
---

# Troubleshoot Skill

Arguments: $ARGUMENTS

Systematically troubleshoot issues through multi-agent orchestration: discover → investigate → fix → verify → commit.

## Configuration

```bash
# Source resolve-config: marketplace installs get ${CLAUDE_PLUGIN_ROOT} substituted
# inline before bash runs; legacy local copies fall back to ~/.claude. If neither
# path resolves, fail loudly rather than letting resolve_artifact be undefined.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
  exit 1
fi
TROUBLESHOOT_EXEC_MODE=$(resolve_exec_mode troubleshoot team)
TROUBLESHOOT_WORKFLOW_ENABLED=$(resolve_troubleshoot_workflow_enabled)

# Optional --spec PATH: opt-in source for per-AC verification (Phase 6.3).
# Troubleshoot is ticket-agnostic by default; this flag is the ONLY way a spec
# enters the run — no inference from CWD, ticket, or work dir.
# Quote-aware parse: handles `--spec PATH`, `--spec=PATH`, and quoted paths
# with spaces; a bare `--spec` (no value) resolves to empty and is ignored.
SPEC=""
case " $ARGUMENTS " in
  *" --spec "*|*" --spec="*)
    rest=${ARGUMENTS#*--spec}; rest=${rest#[ =]}    # text after the flag, minus one space/=
    case $rest in
      \"*) SPEC=${rest#\"}; SPEC=${SPEC%%\"*} ;;     # double-quoted path (allows spaces)
      \'*) SPEC=${rest#\'}; SPEC=${SPEC%%\'*} ;;     # single-quoted path
      *)   SPEC=${rest%% *} ;;                        # bare token, up to next space
    esac
    ;;
esac
if [ -n "$SPEC" ] && [ ! -f "$SPEC" ]; then
  echo "WARNING: --spec '$SPEC' not found; per-AC verification skipped." >&2
  SPEC=""
fi
```

Use `$TROUBLESHOOT_EXEC_MODE` to determine team vs sub-agent behavior in Phase 6 (verify fix).
Use `$TROUBLESHOOT_WORKFLOW_ENABLED` to decide whether Phase 6.3 attempts the orchestrated path.

## Write Safety

When running verification agents in parallel (Phase 6), agents MUST NOT write to the same file:

- **security-auditor**: Writes only to its own scoped output (returned via Task result)
- **quality-guard**: Writes only to its own scoped output (returned via Task result)
- **Source code fixes**: Only the lead applies fixes (Phase 5), sequentially, never in parallel
- **The orchestrated 6.3 script**: writes nothing itself — it has no filesystem and no shell —
  and dispatches no agent whose role is to write. `quality-guard` and `code-reviewer` do hold
  unscoped `Bash` in their own definitions, so the precise claim is that no dispatched agent can
  write or edit a file, and any `git` verb one reached for still meets `git-mutation-guard.sh`;
  subagent tool calls go through the same PreToolUse hooks as the main loop.
  `tests/troubleshoot/01-workflow-script.test` pins the roster and its tool grants

See `${CLAUDE_PLUGIN_ROOT}/shared/write-safety.md` (or `~/.claude/shared/write-safety.md` for local/dev copies) for the full conventions.

## Usage

```bash
/troubleshoot "Endpoint /api/users returns 202 instead of 200"
/troubleshoot "Login fails when password contains special characters"
/troubleshoot "Database query times out on large datasets"
/troubleshoot "Endpoint returns 500 after deploy" --spec .claude/work/PROJ-1-login/spec.md
```

`--spec PATH` (optional) opts into per-AC verification: when supplied, Phase 6.3 verifies the fix against the spec's acceptance criteria and appends a per-AC PASS/FAIL section. Omit it for an ordinary ad-hoc run — troubleshoot stays ticket-agnostic and infers no spec on its own.

## When to Use This Skill

- Endpoint returns wrong status code
- Feature not working as expected
- Error/exception being thrown
- Performance issue
- Data inconsistency
- Test failing unexpectedly

---

## Workflow Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│ Phase 1: Parse Issue              → Extract what's wrong             │
│ Phase 2: Discover Code            → Find relevant code               │
│ Phase 3: Investigate              → Root cause analysis              │
│ Phase 4: Determine Fix Strategy   → Code fix, test fix, or clarify   │
│ Phase 5: Apply Fix                → Apply fix (code or tests)        │
│ Phase 6: Verify                   → Run tests, ensure fix works      │
│ Phase 7: Commit                   → Save the fix                     │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Phase 0: Enter Worktree (Conditional)

Skip if `resolve_worktree_enabled` returns `"false"`.

**Single mode** (`WORKSPACE_MODE == "single"`):
1. Call `EnterWorktree(name: "troubleshoot-{short_slug}")` where `{short_slug}` is derived from the issue description (e.g., `troubleshoot-login-500`)
2. CWD moves to worktree; `$WORK_DIR` still resolves to original workspace root

**Where these values come from.** Shell state does not survive between Bash tool
calls, so `WT_ROOT` and `TROUBLESHOOT_WORKSPACE` are re-derived in each block
that uses them.

**Multi mode** (`WORKSPACE_MODE == "multi"`):
1. Create per-service worktrees using each service's current branch:
```bash
WT_ROOT=$(resolve_worktree_root)
TROUBLESHOOT_WORKSPACE="${WT_ROOT}/troubleshoot-{short_slug}"
mkdir -p "$TROUBLESHOOT_WORKSPACE"

for svc in $(resolve_services); do
  svc_path=$(resolve_service_path "$svc")
  # A rejected service NAME returns 1 with EMPTY stdout (a rejected PATH is
  # different: it falls back to the name-is-the-directory convention). `git -C ""`
  # is a documented no-op that runs in the CURRENT repo, so an unguarded empty
  # value here creates the worktree in whatever repository the session is in.
  [ -n "$svc_path" ] || { echo "skipping $svc: no usable path" >&2; continue; }
  wt_path="${TROUBLESHOOT_WORKSPACE}/${svc}"
  [[ -d "$wt_path" ]] && continue
  CURRENT_BRANCH=$(git -C "$svc_path" branch --show-current 2>/dev/null || echo "HEAD")
  git -C "$svc_path" worktree add "$wt_path" -b "troubleshoot/{short_slug}" 2>/dev/null \
    || git -C "$svc_path" worktree add "$wt_path" "$CURRENT_BRANCH"
  echo "Created worktree: ${svc}/ → ${wt_path}"
done
```
2. All subsequent agent prompts use `$TROUBLESHOOT_WORKSPACE/{service}/` paths

**After Phase 7 (Commit)**: Single mode → `ExitWorktree(action: "remove")`. Multi mode → remove worktrees:
```bash
# Re-derived here: shell state does not survive between Bash tool calls.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
  exit 1
fi
WT_ROOT=$(resolve_worktree_root)
TROUBLESHOOT_WORKSPACE="${WT_ROOT}/troubleshoot-{short_slug}"
for svc in $(resolve_services); do
  svc_path=$(resolve_service_path "$svc")
  # A rejected service NAME returns 1 with EMPTY stdout (a rejected PATH is
  # different: it falls back to the name-is-the-directory convention). `git -C ""`
  # is a documented no-op that runs in the CURRENT repo, so an unguarded empty
  # value here creates the worktree in whatever repository the session is in.
  [ -n "$svc_path" ] || { echo "skipping $svc: no usable path" >&2; continue; }
  wt_path="${TROUBLESHOOT_WORKSPACE}/${svc}"
  [[ -d "$wt_path" ]] && git -C "$svc_path" worktree remove "$wt_path" --force 2>/dev/null
done
rmdir "$TROUBLESHOOT_WORKSPACE" 2>/dev/null
```

---

## Phase 1: Parse Issue

**Goal:** Understand what's wrong and what's expected.

**Extract from user description:**
- **What:** What component/endpoint/feature is broken?
- **Expected:** What should happen?
- **Actual:** What actually happens?
- **Context:** Error messages, reproduction steps

**Example:**
```
Input: "Endpoint /api/users returns 202 instead of 200"

Parsed:
  Component: /api/users endpoint
  Expected: HTTP 200 status
  Actual: HTTP 202 status
  Type: Response status mismatch
```

**Confirm understanding with user if unclear.**

---

## Phase 2: Discover Code

**Goal:** Find the relevant code and understand the flow.

**Use Explore agent to locate:**
- Entry point (controller, route, handler)
- Business logic (services, repositories)
- Related tests
- Configuration files

**Agent delegation:** Pass purpose, not just a query — state the symptom and that the result feeds root-cause investigation, so the agent scopes its trace accordingly. If it returns no concrete anchors (`file:line`, symbols), re-dispatch with a refined query (≤3 cycles). See `${CLAUDE_PLUGIN_ROOT}/shared/subagent-context-discipline.md` (or `~/.claude/shared/subagent-context-discipline.md` for local/dev copies).
```
Task(Explore, "Troubleshooting: /api/users returns 202 instead of 200. Find the endpoint definition and trace the code flow through controllers and services so we can locate where the status is set. Return file:line anchors.")
```

**Explore agent returns:**
- File paths and line numbers
- Call chain
- Dependencies
- Related tests

**If code is complex or legacy:** (same dispatch discipline — carry the symptom and the investigation goal, not just the endpoint name)
```
Task(archaeologist, "Troubleshooting why /api/users returns 202: deep-dive the endpoint and its call chain to find what sets the status. Return file:line anchors and any historical clues (TODOs, workarounds).")
```

**Output to user:**
```
## Code Discovery

Found endpoint: src/Controller/UserController.php:45
Route: GET /api/users → UserController::index()
Service: UserService::getUsers()
Tests: tests/Feature/UserApiTest.php

Call chain:
  Route → Controller → Service → Repository → Database
```

---

## Phase 3: Investigate Root Cause

**Goal:** Understand WHY the issue occurs.

**Investigation steps:**

### 3.1 Read the code
- Read controller/handler
- Read service methods
- Check conditional logic (if/else that might trigger different responses)

### 3.2 Check git history
```bash
# When did this start?
git log -p --all -S "202" -- path/to/controller

# Recent changes to this file
git log --oneline -10 -- path/to/controller
```

### 3.3 Check existing tests
```bash
# What do tests expect?
grep -r "api/users" tests/ -A 5 -B 5
```

### 3.4 Perform systematic investigation

**Investigate the root cause:**
1. Reproduce - Identify exact conditions
2. Isolate - When did it last work?
3. Investigate - Trace through code
4. Hypothesize - Form theory about cause
5. Document - Provide root cause analysis

**Output to user:**
```
## Root Cause Analysis

Issue: UserController returns HTTP 202 (Accepted) for async processing
Location: UserController.php:45
Introduced: commit abc123f (3 days ago)

Root Cause:
  Code was changed to use async job processing, which returns 202
  to indicate request was accepted but not yet processed.

Decision needed:
  ☐ Keep 202 (correct for async) and update tests
  ☐ Revert to 200 (synchronous processing)
```

---

## Phase 4: Determine Fix Strategy

**Goal:** Decide what needs to be fixed.

**Three scenarios:**

### Scenario A: Code is wrong
- Bug in implementation
- Logic error
- Regression from recent change

**Action:** Fix the code

### Scenario B: Test is wrong
- Code change was intentional
- Test expectations outdated
- Requirements changed

**Action:** Update tests

### Scenario C: Unclear
- Ambiguous requirements
- Missing documentation

**Action:** Ask user for clarification

**Use AskUserQuestion if decision needed:**
```
AskUserQuestion:
  Question: "Should /api/users be synchronous (200) or asynchronous (202)?"
  Options:
    1. Synchronous (200) - Users wait for result
    2. Asynchronous (202) - Background processing
```

---

## Phase 5: Apply Fix

**Goal:** Implement the solution.

### 5.1 Code Fix (Scenario A)

**If code needs fixing:**
- Apply the fix directly using Edit tool
- Keep changes minimal and focused
- Add comments if logic is complex

**Example:**
```php
// Before
return new JsonResponse($data, 202); // Async processing

// After
return new JsonResponse($data, 200); // Synchronous response
```

### 5.2 Test Fix (Scenario B)

**If tests need updating:**
- Update test expectations
- Add new test cases if edge case was missed

**Example:**
```php
// Before
$response->assertStatus(200);

// After
$response->assertStatus(202); // Updated for async processing
```

### 5.3 Write Missing Tests

**If tests are missing:**
```
Task(test-writer, "Write test for /api/users endpoint expecting 200 status code for successful response")
```

---

## Phase 6: Verify Fix

**Goal:** Ensure the fix works and doesn't break anything.

**Execution mode**: Determined by `$TROUBLESHOOT_EXEC_MODE`.

### 6.1 Run relevant tests
```bash
# Run specific test file
./vendor/bin/phpunit tests/Feature/UserApiTest.php

# Or run all tests
./vendor/bin/phpunit
```

### 6.2 If tests fail
**Delegate to test-fixer:**
```
Task(test-fixer, "Fix failing test after changing /api/users to return 200 instead of 202")
```

### 6.3 Verification review

This step decides whether the fix addressed the **root cause** or the **symptom**. It is the
most consequential judgment `/troubleshoot` makes, so it has two paths.

#### Path selection

**Attempt the orchestrated path when both hold:**
- `$TROUBLESHOOT_WORKFLOW_ENABLED` is `true` (the default), and
- the `Workflow` tool is available in this session.

**If so, read `references/workflow-verify.md` and follow it.** It replaces the agent dispatch
in the rest of 6.3 and changes what the `## Verification` output block receives. What it adds
is one inversion: the root-cause analysis from Phase 3 stops being *context* the skeptic
reasons from and becomes the *claim under test*, refutable by every agent that sees it.

**Gather these in the lead first and pass them as `args`.** The script has no filesystem and
no shell, so anything it needs must arrive that way, verbatim:

| `args` field | Where the lead gets it |
|---|---|
| `symptom` | Phase 1's parsed What/Expected/Actual, verbatim |
| `rootCauseClaim` | Phase 3's root-cause analysis, verbatim — this is the claim under test |
| `diff` | `git diff` of the fix Phase 5 applied |
| `fileList` | the paths that diff touches |
| `testResults` | 6.1's results as `[{name, status, exitCode, summary}]`; `[]` when no suite ran |
| `specAcs` | the AC text read from `$SPEC` when `--spec` was supplied, else `""` |
| `priorRejections` | rejections so far — see *The rejection counter* below. **Never omit it**: the script refuses a missing count rather than defaulting it to `0`, because that default is the reset |
| `maxRejections` | `3` |
| `timestamp` | the current time; `Date.now()` throws inside the script |

**Five things it does NOT replace. All five stay here, in the lead:**

1. **Phase 5's fix application.** Only the lead applies fixes, sequentially, never in parallel.
   The script dispatches read-only judgment and returns records; it applies nothing.
2. **Phase 7's commit.** A mutation reachable from a fan-out is a mutation reachable more than
   once. The script cannot reach it, and a test asserts so — over the script's own text and over
   the tool grants of every agent it dispatches.
3. **The worktree** (Phase 0 and its teardown).
4. **The rejection counter and the escalation `AskUserQuestion`.** See below.
5. **Reading `$SPEC`.** The lead reads the file; the script receives the text.

**Fall back to the classic path below — silently, it is not an error — when:**
- the config disables it, or
- the `Workflow` tool is not available, or
- the orchestrated run fails, does not complete, or returns `ok: false`.

**On any of those, run the classic 6.3 in full.** Do not merge a partial orchestrated result
into a classic run, and do not present a partial run as complete. Name the path taken in the
`## Verification` block either way.

> Detection is attempt-and-observe: nothing in the tool's contract describes how absence
> manifests, so do not write logic that depends on a specific error shape. If the orchestrated
> path does not produce a result, take the fallback.

`$TROUBLESHOOT_EXEC_MODE` is not consulted on the orchestrated path. `workflow` is not a third
value of `execution_mode`; it replaces the choice for this step, because a script has no
teammate protocol to run.

#### Consume the orchestrated result (orchestrated path only)

Skip this entirely on the classic path.

The script returned typed data and the aggregation already happened, mechanically, where it
could not be renegotiated. **Render it; do not re-judge it.** Rules that are not stylistic:

- **Lead with `reach.verdict`.** It is the answer to the question this step exists to ask:

  | `reach.verdict` | Report it as |
  |---|---|
  | `root-cause` | The fix addresses the cause. Show `interceptPoint` and the traced path anyway |
  | `symptom` | **SYMPTOM FIX** — the change stops the failure being observed while the behaviour that produces it is untouched |
  | `cannot-trace` | Nothing walkable was established. When `downgraded` is true, a verdict was *claimed* and thrown out for citing nothing — say that, and never report the discarded verdict as the finding |
  | `contested` | Two or more lenses refuted the verifier's verdict and no replacement was established |

- **Always print `reach.failurePath`**, one `file:line` per step with its role and quoted line,
  alongside `reach.rootCauseSite` (where the failure is produced) and `reach.interceptPoint`
  (where this change intervenes instead). Those three together are what makes a symptom verdict
  actionable; the script refuses to emit the verdict without them, so do not undo that by
  summarising the path away.
- **Print `reach.siblingSites` and `reach.guardTest`.** A fix that repairs one of four call
  sites is not a root-cause fix, and a fix with no test covering the triggering condition is
  one regression away from returning.
- **Print each lens's reason from `reach.verdicts`**, refuting or not. The reasons are what
  make the verdict arguable; the verdict alone is a number of votes.
- **When `reach.judged` is fewer than three, say so** and say which direction it cuts: a lens
  that returned no reach judgment could not refute the verdict, so the verdict was upheld over
  fewer challenges than the panel was asked for. Never present it as a full panel.
- **Report every surviving finding**, and label any with `verified: false` as `[UNVERIFIED]` —
  they were not judged by all three lenses.
- **Dropped findings get their own section**, with each lens's reason. A finding that vanishes
  silently is indistinguishable from one never found.
- **Print every `unresolved` record.** Those are the items still open: uncited path steps,
  uncited findings, a downgraded verdict, a contested verdict, and — at the cap — the deadlock
  and every objection still standing.
- **When `uncitedBlocking` is above zero, say so and treat the round as rejected.** A blocking
  finding arrived with no usable citation: it was never judged, and it is not an approval. It is
  in `unresolved` with its index and severity.
- **When any `forgedMarkers` count is non-zero, say so.** Text that tried to forge a content
  boundary reached this run; report the counts, never the text. `returned` above zero means the
  script redacted marker shapes from the very fields you are about to print — say that it did,
  so a `[REDACTED-FORGED-MARKER]` in the output is not mistaken for something an agent wrote.
- **Fill the `✓ Skeptic validation:` line from `reach.verdict`**, since there is no skeptic on
  this path: `root-cause` with no surviving blocking finding is `APPROVED`; anything else is
  `CONDITIONAL`, named — `SYMPTOM FIX`, `CANNOT TRACE`, `CONTESTED`, or `BLOCKING REGRESSION`.
- **Never present an `ok: false` result at all.** It is not a verdict. Run the classic path.

Then continue to the `## Verification` output block below.

#### The rejection counter (both paths)

The three-rejection deadlock protocol is the lead's, on both paths, and it is deliberately not
in the script: the script is re-entered from scratch every round, so any counter it owned would
start at zero every time and the third rejection would look like the first.

- Start at `0`. Increment by one for every **rejected** round, whichever path produced it.
- On the orchestrated path a round is rejected when the result has `rejected: true`. Pass the
  returned `rejectionCount` back as the next round's `priorRejections`. There is no separate
  round number to keep in step — the script derives the round from the count, so the two cannot
  drift apart.
- An `ok: false` round is **not** a rejection — a dispatch failure is not the fix being
  refused — so carry `priorRejections` forward unchanged when you fall back. Run the classic
  6.3 for that round and do **not** re-enter the script within the same round: a second attempt
  at the same `round` either double-counts or is refused, and neither is a verification.
- **Falling back to the classic path does not reset it.** A run that alternates between the two
  paths still stops at three.
- The script refuses a `priorRejections` that is missing or malformed (`ok: false`,
  `rejection-count-not-a-count`) rather than defaulting it to `0`. **This is the only reset it
  can catch.** A lead that genuinely restarts its count passes `0`, and `0` is what an honest
  first round passes; nothing inside a stateless script distinguishes them. Holding the count
  across the rounds of this run is therefore your obligation, not the script's — and it is the
  one that makes the three-rejection protocol mean anything.

#### Classic path

**If `$TROUBLESHOOT_EXEC_MODE` = `"subagent"`:**

Run verification agents in parallel:

```
[PARALLEL EXECUTION - Single message with multiple Task calls]

Task 1: subagent_type: "security-auditor"
Prompt: Quick security audit of {endpoint/component} after {change description}.
Check for: injection risks, auth bypass, data exposure from the fix.

Task 2: subagent_type: "quality-guard"
Prompt: Verify the troubleshoot fix (Level 2 — Implementation Validation).
Fix diff: {git_diff}
Root cause: {root_cause_analysis}
Verify:
1. Does the fix actually address the root cause, or just the symptom?
2. Are there other code paths with the same bug pattern?
3. Do the tests cover the specific condition that triggered the bug?
When `--spec` was supplied (`$SPEC` resolved to a file): also read `$SPEC`, verify the fix against each acceptance criterion, and prefix every gate that maps to an AC with its AC ID(s) — e.g., `GATE 2: AC-3.1 — ...` — citing grader-typed evidence per `${CLAUDE_PLUGIN_ROOT}/shared/eval-concepts.md` (or `~/.claude/shared/eval-concepts.md` for local/dev copies).
Produce a Quality Review Gates report.
```

If skeptic raises BLOCKING gates, address them before committing.

**Deadlock protocol**: If the fix is rejected 3 times, STOP iterating. Escalate to the user with: (a) the fix diff, (b) the objections across all rounds, (c) your attempts to address them. The user decides: override, provide guidance, or abort. The count is the shared one from *The rejection counter* above — it spans both paths and is not reset by falling back to this one.

---

**If `$TROUBLESHOOT_EXEC_MODE` = `"team"` (default):**

```
TeamCreate(team_name="troubleshoot-verify")

TaskCreate: "Security audit of fix" (T1)
TaskCreate: "Challenge the fix" (T2) — depends on T1

[PARALLEL]
Task tool: name: "troubleshoot-security", subagent_type: "security-auditor", team_name: "troubleshoot-verify"
Task tool: name: "troubleshoot-skeptic", subagent_type: "quality-guard", team_name: "troubleshoot-verify"
```

Skeptic waits for security-auditor, then challenges. Agents resolve via SendMessage. Collect results and TeamDelete.

**Deadlock protocol**: Max 3 rejection cycles, counted by *The rejection counter* above and shared with the orchestrated path. After 3 rejections, stop iterating and escalate to the user with all objections and attempted fixes. The user decides: override, provide guidance, or abort.

---

**Output to user:**
```
## Verification

Path: {orchestrated | classic}

✓ Tests passing: 15/15
✓ Security audit: {No issues | Issues found}
✓ Skeptic validation: {APPROVED | CONDITIONAL}
✓ Manual verification: Endpoint returns 200

Per-AC Verification (--spec only — one row per AC):
  | AC ID  | Verdict | Grader | Evidence                      |
  |--------|---------|--------|-------------------------------|
  | AC-3.1 | PASS    | code   | UserApiTest::testStatus → 200 |

Fix verified successfully.
```

**Per-AC section** (only when `--spec PATH` was supplied and `$SPEC` resolved to a file): assemble one row per AC from the quality-guard gate output (AC-tagged) against the spec's AC list — same rules as `/implement` Phase 4.5; source is the quality-guard output and evidence follows the grader type. Re-verification reliability matters here: a fix that passes once is **pass@1, not pass^k** — flag a re-verified flaky fix as such (see `${CLAUDE_PLUGIN_ROOT}/shared/eval-concepts.md`, or `~/.claude/shared/eval-concepts.md` for local/dev copies). When no `--spec` is supplied (the default ad-hoc run), omit this section entirely — no error, no placeholder.

---

## Phase 7: Commit

**Goal:** Save the fix with proper documentation.

Run inline — the hook enforces credential scan and branch protection automatically:

```bash
git add <files>
```

> The verb below leads its own call: the mutation guard anchors on
> `^git commit` / `^git push`, so anything ahead of it in the same call
> skips the credential scan and the push gate.

```bash
git commit -m "$(cat <<'EOF'
[TICKET-123] fix(scope): description
EOF
)"
```

If pushing, record the security-auditor confirmation first, after a clean scan:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-audit.sh"
```

> The push gets its OWN call. Sharing a block with the commit means the guard
> sees one input starting with `git commit`, scans that, and lets the push
> through with no audit check, no branch protection and no WARNs.

```bash
git push
```

**Commit message format:**
```
[TICKET-123] fix(api): change /api/users to return 200 instead of 202

- Changed UserController to use synchronous processing
- Updated tests to expect 200 status code
- Root cause: Async processing was unintended change in commit abc123f
```

**Output to user:**
```
## Debug Complete ✓

Issue: /api/users returns 202 instead of 200
Root Cause: Unintended async processing change
Fix Applied: Reverted to synchronous response
Tests: All passing
Commit: abc123f
Status: RESOLVED
```

---

## Error Handling

### If code location not found
```
❌ Could not locate /api/users endpoint

Suggestions:
  • Check if route exists: grep -r "api/users" routes/
  • Check if endpoint was removed
  • Try broader search: grep -r "users" src/Controller/
```

### If root cause unclear after investigation
```
⚠️ Root cause not definitively identified

Next steps:
  1. Add debug logging around suspected code
  2. Check production logs for error patterns
  3. Reproduce issue locally with debugging enabled
  4. Consider pairing with developer familiar with this code
```

### If fix breaks other tests
```
⚠️ Fix broke 3 other tests

Rolling back change...
Delegating to test-fixer for comprehensive test fix...

Task(test-fixer, "Fix all failing tests after changing /api/users status code")
```

---

## Agent Orchestration Summary

| Phase | Agent(s) Used | Purpose |
|-------|---------------|---------|
| Discovery | Explore, archaeologist | Find and understand code |
| Investigation | Direct analysis | Root cause analysis |
| Fix | Direct (Edit tool) | Apply code/test changes |
| Verification | test-writer, test-fixer | Ensure fix works |
| Review (classic) | security-auditor, quality-guard | Validate fix quality and security |
| Review (orchestrated) | quality-guard, security-auditor, code-reviewer | Two blind verifiers on one question each, then three lenses refuting the reach verdict — see `references/workflow-verify.md` |
| Commit | Direct (Bash, hook-guarded) | Save and document fix |

---

## Tips for Effective Debugging

**Provide clear issue descriptions:**
✅ "Login endpoint returns 500 when password is empty"
✅ "User creation fails with unique constraint error on email"
✅ "Dashboard loads slowly (>5s) with 1000+ items"

❌ "It's broken"
❌ "Fix the login"
❌ "Make it faster"

**Include context when available:**
- Error messages
- Stack traces
- Reproduction steps
- Expected vs actual behavior
- Recent changes

**Example:**
```bash
/troubleshoot "Login endpoint returns 500 when password is empty
Error: Call to a member function hash() on null
Stack trace shows error in AuthService::validatePassword()
Expected: 400 Bad Request with validation error
Actual: 500 Internal Server Error"
```

---

## Quality Checklist

Before completing troubleshoot session:

- [ ] Root cause identified and documented
- [ ] The fix reaches the failure path — not a symptom suppressed downstream of it
- [ ] Fix applied (code or tests)
- [ ] Tests passing
- [ ] No regressions (other tests still pass)
- [ ] Security check (if response/auth changed)
- [ ] Committed with descriptive message
- [ ] Issue resolved confirmation

---

## Example Session

**User:**
```bash
/troubleshoot "Endpoint /api/users returns 202 instead of 200"
```

**Skill Workflow:**

1. **Parse:** Endpoint issue, status code mismatch
2. **Discover:**
   - Task(Explore) → Found UserController.php:45
   - Traced to UserService::getUsers()
3. **Investigate:**
   - Direct analysis → Root cause: async processing change
   - Git history shows commit abc123f changed to async
4. **Decide:** User confirms should be synchronous (200)
5. **Fix:** Change response status to 200
6. **Verify:**
   - Run tests → All passing
   - Task(security-auditor) → No issues
7. **Commit:**
   - Inline `git commit` (hook-guarded) → Committed fix

**Result:** Issue resolved, tests passing, fix committed.
