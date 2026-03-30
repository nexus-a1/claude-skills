---
name: debug
category: implementation
model: opus
userInvocable: true
description: Systematically debug a failing feature or error. Discovers code, investigates root cause, applies fix, verifies with tests, and commits. Use when something isn't working as expected.
argument-hint: <error-or-description>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage
---

# Debug Skill

Arguments: $ARGUMENTS

Systematically debug issues through multi-agent orchestration: discover → investigate → fix → verify → commit.

## Configuration

```bash
# BEGIN_SHARED: resolve-config
# Shared configuration resolution for Claude Code skills.
# Source this script to get config discovery and artifact resolution functions.
#
# Usage in SKILL.md bash blocks:
#   source ~/.claude/shared/resolve-config.sh
#   WORK_DIR=$(resolve_artifact work work)
#   EXEC_MODE=$(resolve_exec_mode qa_review team)

# --- Config discovery ---
# Walks up from CWD to find .claude/configuration.yml
CONFIG=""
_d="$PWD"
while [[ "$_d" != "/" ]]; do
  if [[ -f "$_d/.claude/configuration.yml" ]]; then
    CONFIG="$_d/.claude/configuration.yml"
    break
  fi
  _d="$(dirname "$_d")"
done

# --- Artifact resolution ---
# Resolves an artifact path from configuration, with fallback defaults.
# Usage: resolve_artifact <artifact_name> <default_subdir> [default_base]
# Returns: resolved path (e.g., ".claude/work" or "/abs/path/to/requirements")
resolve_artifact() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    echo "${_BASE}/${_SUB}"
  else
    echo "${default_base}/${default_subdir}"
  fi
}

# --- Artifact resolution with type ---
# Like resolve_artifact but also returns the storage type (git|directory).
# Usage: IFS='|' read -r PATH TYPE <<< "$(resolve_artifact_typed work work)"
resolve_artifact_typed() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    local _TYPE=$(yq -r ".storage.locations.${_LOC}.type // \"directory\"" "$CONFIG")
    echo "${_BASE}/${_SUB}|${_TYPE}"
  else
    echo "${default_base}/${default_subdir}|directory"
  fi
}

# --- Execution mode resolution ---
# Resolves execution mode for a specific phase from configuration.
# Usage: resolve_exec_mode <phase_name> [default_mode]
# Returns: "team" or "subagent"
resolve_exec_mode() {
  local phase="$1"
  local default="${2:-team}"

  if [[ -f "$CONFIG" ]]; then
    local _raw=$(yq -r '.execution_mode' "$CONFIG" 2>/dev/null)
    if [[ "$_raw" == "subagent" || "$_raw" == "team" ]]; then
      echo "$_raw"
    elif [[ "$_raw" != "null" && -n "$_raw" ]]; then
      yq -r ".execution_mode.overrides.${phase} // .execution_mode.default // \"${default}\"" "$CONFIG"
    else
      echo "$default"
    fi
  else
    echo "$default"
  fi
}
# END_SHARED: resolve-config
DEBUG_EXEC_MODE=$(resolve_exec_mode debug team)
```

Use `$DEBUG_EXEC_MODE` to determine team vs sub-agent behavior in Phase 6 (verify fix).

## Write Safety

When running verification agents in parallel (Phase 6), agents MUST NOT write to the same file:

- **security-auditor**: Writes only to its own scoped output (returned via Task result)
- **quality-guard**: Writes only to its own scoped output (returned via Task result)
- **Source code fixes**: Only the lead applies fixes (Phase 5), sequentially, never in parallel

See `~/.claude/shared/write-safety.md` for the full conventions.

## Usage

```bash
/debug "Endpoint /api/users returns 202 instead of 200"
/debug "Login fails when password contains special characters"
/debug "Database query times out on large datasets"
```

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

**Agent delegation:**
```
Task(Explore, "Find /api/users endpoint definition and trace the code flow through controllers and services")
```

**Explore agent returns:**
- File paths and line numbers
- Call chain
- Dependencies
- Related tests

**If code is complex or legacy:**
```
Task(archaeologist, "Deep dive into /api/users endpoint - understand why it returns 202 status")
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

**Execution mode**: Determined by `$DEBUG_EXEC_MODE`.

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

**If `$DEBUG_EXEC_MODE` = `"subagent"`:**

Run verification agents in parallel:

```
[PARALLEL EXECUTION - Single message with multiple Task calls]

Task 1: subagent_type: "security-auditor"
Prompt: Quick security audit of {endpoint/component} after {change description}.
Check for: injection risks, auth bypass, data exposure from the fix.

Task 2: subagent_type: "quality-guard"
Prompt: Verify the debug fix (Level 2 — Implementation Validation).
Fix diff: {git_diff}
Root cause: {root_cause_analysis}
Verify:
1. Does the fix actually address the root cause, or just the symptom?
2. Are there other code paths with the same bug pattern?
3. Do the tests cover the specific condition that triggered the bug?
Produce a Quality Review Gates report.
```

If skeptic raises BLOCKING gates, address them before committing.

**Deadlock protocol**: If the skeptic rejects the fix 3 times, STOP iterating. Escalate to the user with: (a) the fix diff, (b) the skeptic's objections across all rounds, (c) your attempts to address them. The user decides: override, provide guidance, or abort.

---

**If `$DEBUG_EXEC_MODE` = `"team"` (default):**

```
TeamCreate(team_name="debug-verify")

TaskCreate: "Security audit of fix" (T1)
TaskCreate: "Challenge the fix" (T2) — depends on T1

[PARALLEL]
Task tool: name: "debug-security", subagent_type: "security-auditor", team_name: "debug-verify"
Task tool: name: "debug-skeptic", subagent_type: "quality-guard", team_name: "debug-verify"
```

Skeptic waits for security-auditor, then challenges. Agents resolve via SendMessage. Collect results and TeamDelete.

**Deadlock protocol**: Max 3 rejection cycles. After 3 rejections from the skeptic, stop iterating and escalate to the user with all objections and attempted fixes. The user decides: override, provide guidance, or abort.

---

**Output to user:**
```
## Verification

✓ Tests passing: 15/15
✓ Security audit: {No issues | Issues found}
✓ Skeptic validation: {APPROVED | CONDITIONAL}
✓ Manual verification: Endpoint returns 200

Fix verified successfully.
```

---

## Phase 7: Commit

**Goal:** Save the fix with proper documentation.

**Delegate to git-operator:**
```
Task(git-operator, "Commit and push: Fix /api/users to return 200 instead of 202")
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
| Review | security-auditor, quality-guard | Validate fix quality and security |
| Commit | git-operator | Save and document fix |

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
/debug "Login endpoint returns 500 when password is empty
Error: Call to a member function hash() on null
Stack trace shows error in AuthService::validatePassword()
Expected: 400 Bad Request with validation error
Actual: 500 Internal Server Error"
```

---

## Quality Checklist

Before completing debug session:

- [ ] Root cause identified and documented
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
/debug "Endpoint /api/users returns 202 instead of 200"
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
   - Task(git-operator) → Committed fix

**Result:** Issue resolved, tests passing, fix committed.
