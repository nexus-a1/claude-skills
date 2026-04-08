---
name: troubleshoot
category: implementation
model: opus
userInvocable: true
description: Systematically troubleshoot a failing feature or error. Discovers code, investigates root cause, applies fix, verifies with tests, and commits. Use when something isn't working as expected. Runs in the current working tree by default — set `worktree.enabled: true` in `.claude/configuration.yml` to isolate work in a git worktree.
argument-hint: <error-or-description>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage, EnterWorktree, ExitWorktree
---

# Troubleshoot Skill

Arguments: $ARGUMENTS

Systematically troubleshoot issues through multi-agent orchestration: discover → investigate → fix → verify → commit.

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

# --- Workspace root ---
# The directory where .claude/configuration.yml lives.
# All relative paths anchor here. Works from worktrees, subdirs, anywhere.
WORKSPACE_ROOT=""
if [[ -n "$CONFIG" ]]; then
  WORKSPACE_ROOT="$(cd "$(dirname "$CONFIG")/.." && pwd)"
fi
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$PWD}"

# --- Workspace mode (auto-detect) ---
# "single" = inside a git repo; "multi" = aggregate directory with git repos as subdirs
WORKSPACE_MODE="single"
DISCOVERED_SERVICES=()

if git -C "$WORKSPACE_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
  WORKSPACE_MODE="single"
else
  for dir in "${WORKSPACE_ROOT}"/*/; do
    if [[ -d "${dir}.git" ]]; then
      DISCOVERED_SERVICES+=("$(basename "$dir")")
    fi
  done
  [[ ${#DISCOVERED_SERVICES[@]} -gt 0 ]] && WORKSPACE_MODE="multi"
fi

# Config override: if workspace.services defined, use that instead of auto-discovery
if [[ -f "$CONFIG" ]]; then
  _svc_count=$(yq -r '.workspace.services | length // 0' "$CONFIG" 2>/dev/null)
  if [[ "$_svc_count" -gt 0 ]]; then
    WORKSPACE_MODE="multi"
    DISCOVERED_SERVICES=()
  fi
fi

# --- Artifact resolution ---
# Resolves an artifact path from configuration, with fallback defaults.
# Usage: resolve_artifact <artifact_name> <default_subdir> [default_base]
# Returns: absolute path anchored to WORKSPACE_ROOT
resolve_artifact() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  local result_path
  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    result_path="${_BASE}/${_SUB}"
  else
    result_path="${default_base}/${default_subdir}"
  fi

  if [[ "$result_path" != /* ]]; then
    echo "${WORKSPACE_ROOT}/${result_path}"
  else
    echo "$result_path"
  fi
}

# --- Artifact resolution with type ---
# Like resolve_artifact but also returns the storage type (git|directory).
# Usage: IFS='|' read -r PATH TYPE <<< "$(resolve_artifact_typed work work)"
resolve_artifact_typed() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  local result_path _TYPE
  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    _TYPE=$(yq -r ".storage.locations.${_LOC}.type // \"directory\"" "$CONFIG")
    result_path="${_BASE}/${_SUB}"
  else
    result_path="${default_base}/${default_subdir}"
    _TYPE="directory"
  fi

  if [[ "$result_path" != /* ]]; then
    echo "${WORKSPACE_ROOT}/${result_path}|${_TYPE}"
  else
    echo "${result_path}|${_TYPE}"
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

# --- Worktree helpers ---
resolve_worktree_enabled() {
  if [[ -f "$CONFIG" ]]; then
    yq -r '.worktree.enabled // "false"' "$CONFIG"
  else
    echo "false"
  fi
}

resolve_worktree_root() {
  local default=".worktrees"
  local root
  if [[ -f "$CONFIG" ]]; then
    root=$(yq -r ".worktree.root // \"${default}\"" "$CONFIG")
  else
    root="$default"
  fi
  [[ "$root" != /* ]] && echo "${WORKSPACE_ROOT}/${root}" || echo "$root"
}

# --- Service helpers (multi-mode) ---
resolve_services() {
  if [[ -f "$CONFIG" ]]; then
    local _count=$(yq -r '.workspace.services | length // 0' "$CONFIG" 2>/dev/null)
    if [[ "$_count" -gt 0 ]]; then
      yq -r '.workspace.services[].name' "$CONFIG"
      return
    fi
  fi
  printf '%s\n' "${DISCOVERED_SERVICES[@]}"
}

resolve_service_path() {
  local svc="$1"
  if [[ -f "$CONFIG" ]]; then
    local rel
    rel=$(yq -r ".workspace.services[] | select(.name == \"${svc}\") | .path // empty" "$CONFIG" 2>/dev/null)
    if [[ -n "$rel" ]]; then
      [[ "$rel" != /* ]] && echo "${WORKSPACE_ROOT}/${rel}" || echo "$rel"
      return
    fi
  fi
  echo "${WORKSPACE_ROOT}/${svc}"
}
# END_SHARED: resolve-config
TROUBLESHOOT_EXEC_MODE=$(resolve_exec_mode troubleshoot team)
```

Use `$TROUBLESHOOT_EXEC_MODE` to determine team vs sub-agent behavior in Phase 6 (verify fix).

## Write Safety

When running verification agents in parallel (Phase 6), agents MUST NOT write to the same file:

- **security-auditor**: Writes only to its own scoped output (returned via Task result)
- **quality-guard**: Writes only to its own scoped output (returned via Task result)
- **Source code fixes**: Only the lead applies fixes (Phase 5), sequentially, never in parallel

See `~/.claude/shared/write-safety.md` for the full conventions.

## Usage

```bash
/troubleshoot "Endpoint /api/users returns 202 instead of 200"
/troubleshoot "Login fails when password contains special characters"
/troubleshoot "Database query times out on large datasets"
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

## Phase 0: Enter Worktree (Conditional)

Skip if `resolve_worktree_enabled` returns `"false"`.

**Single mode** (`WORKSPACE_MODE == "single"`):
1. Call `EnterWorktree(name: "troubleshoot-{short_slug}")` where `{short_slug}` is derived from the issue description (e.g., `troubleshoot-login-500`)
2. CWD moves to worktree; `$WORK_DIR` still resolves to original workspace root

**Multi mode** (`WORKSPACE_MODE == "multi"`):
1. Create per-service worktrees using each service's current branch:
```bash
WT_ROOT=$(resolve_worktree_root)
TROUBLESHOOT_WORKSPACE="${WT_ROOT}/troubleshoot-{short_slug}"
mkdir -p "$TROUBLESHOOT_WORKSPACE"

for svc in $(resolve_services); do
  svc_path=$(resolve_service_path "$svc")
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
for svc in $(resolve_services); do
  svc_path=$(resolve_service_path "$svc")
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
Produce a Quality Review Gates report.
```

If skeptic raises BLOCKING gates, address them before committing.

**Deadlock protocol**: If the skeptic rejects the fix 3 times, STOP iterating. Escalate to the user with: (a) the fix diff, (b) the skeptic's objections across all rounds, (c) your attempts to address them. The user decides: override, provide guidance, or abort.

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

**Use Task tool with `subagent_type: "git-operator"`:**

```
Prompt: Commit and push: Fix /api/users to return 200 instead of 202
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
   - Task(git-operator) → Committed fix

**Result:** Issue resolved, tests passing, fix committed.
