---
name: refactor
model: claude-sonnet-4-6
category: code-quality
userInvocable: true
description: Analyze code and suggest refactoring improvements with agent-driven analysis. Runs in the current working tree by default — set `worktree.enabled: true` in `.claude/configuration.yml` to isolate work in a git worktree.
argument-hint: "[file|directory]"
allowed-tools: "Read, Write, Edit, Grep, Glob, Bash(git diff:*), Bash(git log:*), Bash(git status:*), Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage, EnterWorktree, ExitWorktree"
---

# Refactor Command

## Context

Git status: !`git status --short 2>/dev/null || echo "Not a git repository"`

Recently modified files: !`git diff --name-only HEAD 2>/dev/null || echo "No recent changes"`

Current directory: !`pwd`

Arguments: $ARGUMENTS

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
REFACTOR_EXEC_MODE=$(resolve_exec_mode refactor team)
```

Use `$REFACTOR_EXEC_MODE` to determine team vs sub-agent behavior in Steps 3 and 5.1.

## Write Safety

When running QA agents in parallel (Step 5.1 quality gate loop), agents MUST NOT write to the same file:

- **code-reviewer**: Returns findings via Task result only
- **test-writer**: Writes test files (scoped to test directories)
- **quality-guard**: Returns validation via Task result only
- **refactorer**: The only agent that modifies source code, runs sequentially (not in parallel with reviewers)

See `~/.claude/shared/write-safety.md` for the full conventions.

## Worktree Isolation (Conditional)

If `resolve_worktree_enabled` returns `"true"`, enter a worktree before making changes:

**Single mode** (`WORKSPACE_MODE == "single"`):
- Call `EnterWorktree(name: "refactor-{short_slug}")` before Step 5 (Apply Fixes)
- No need to enter worktree for analysis-only steps (1-3)
- After Step 5.1 (Quality Gate Loop): `ExitWorktree(action: "keep")`

**Multi mode** (`WORKSPACE_MODE == "multi"`):
- Before Step 5, create per-service worktrees for affected services only (identified during analysis):
```bash
WT_ROOT=$(resolve_worktree_root)
REFACTOR_WORKSPACE="${WT_ROOT}/refactor-{short_slug}"
mkdir -p "$REFACTOR_WORKSPACE"
# Create worktree only for services that need changes
for svc in {affected_services}; do
  svc_path=$(resolve_service_path "$svc")
  wt_path="${REFACTOR_WORKSPACE}/${svc}"
  [[ -d "$wt_path" ]] && continue
  git -C "$svc_path" worktree add "$wt_path" HEAD
done
```
- Refactorer agent works in worktree paths
- Worktrees persist after completion

## Your Task

Analyze code for refactoring opportunities and optionally apply fixes using the `refactorer` agent. Analysis is delegated to specialized agents for higher-quality findings.

---

### 1. Determine Target Files

**From $ARGUMENTS:**
- Empty → Analyze recently modified files from git
- `src/Controller/UserController.php` → Specific file
- `src/Service` → Directory (all source files)
- `src/**/*.ts` → Pattern match

**Language Detection:**

Detect the primary language from file extensions:

| Extension | Language | Framework Detection |
|-----------|----------|-------------------|
| `.php` | PHP | Symfony (if `composer.json` has `symfony/*`) |
| `.ts`, `.tsx` | TypeScript | React (if `.tsx` or `react` in `package.json`) |
| `.js`, `.jsx` | JavaScript | React, Node.js, Express |
| `.py` | Python | Django, Flask, FastAPI |
| `.go` | Go | Standard library patterns |
| `.rs` | Rust | Cargo project structure |
| Other | Generic | Universal analysis only |

**Filtering:**
- Source files only (match detected language extension)
- Skip common non-source dirs: `vendor/`, `node_modules/`, `var/cache/`, `dist/`, `build/`, `.next/`, `__pycache__/`, `target/`
- Skip test files unless explicitly targeted
- Limit: 20 files max

**No files found:**
```
No source files found to analyze

Suggestions:
  - Provide a specific file: /refactor src/Controller/UserController.php
  - Provide a directory: /refactor src/Service
```

---

### 2. Explore Context

**Use Task tool with `subagent_type: "Explore"`:**

```
Prompt: Analyze the codebase context for refactoring the following files.

Target files:
{file_list}

Language: {detected_language}
Framework: {detected_framework or "none"}

Research and document:
1. Architecture patterns used (layered, hexagonal, MVC, etc.)
2. Coding conventions and style
3. Dependency injection / dependency management patterns
4. Test patterns and approximate coverage
5. Related files that may be affected by changes to the target files
6. Framework-specific conventions (if any)

Return a structured context report.
```

---

### 3. Analyze for Issues

**Use Task tool with `subagent_type: "code-reviewer"`:**

```
Prompt: Analyze the following files for refactoring opportunities. This is a REFACTORING analysis, NOT a PR review — focus on structural improvements, not bugs.

Target files:
{file_list}

Codebase context:
{exploration_results}

Language: {detected_language}
Framework: {detected_framework}

Analyze for:

A. SOLID Principles
- Single Responsibility: classes/methods doing too much
- Open/Closed: hard-coded values, excessive conditionals
- Liskov Substitution: concrete types instead of interfaces
- Interface Segregation: large interfaces
- Dependency Inversion: direct instantiation, concrete dependencies

B. Code Smells
- Long methods (>30 lines)
- Large classes (>300 lines, >10 methods)
- Deep nesting (>3 levels)
- Duplicate code
- Dead code (unused methods/properties/functions)
- Magic numbers/strings
- Data clumps (repeated parameter groups)

C. Language-Specific Improvements
- Missing type annotations / type hints
- Outdated syntax patterns that have modern equivalents
- Framework best practice violations
- Idiomatic improvements for {detected_language}

Categorize each finding as:
- CRITICAL: significant design issues, high-impact improvements
- IMPORTANT: meaningful improvements, moderate impact
- SUGGESTION: nice-to-haves, low impact

For each finding, provide:
- File path and line number
- Problem description
- Specific refactoring recommendation
- Estimated impact (high/medium/low)
```

---

### 3.1 Present Report

Present findings from the code-reviewer analysis.

For each file:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{file_path}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Overview:
  Language: {language}
  Lines: {count}
  Methods/Functions: {count}

CRITICAL:

  Line {N}: {description}
  Problem: {problem}
  Suggestion: {how to fix}

IMPORTANT:

  Line {N}: {description}
  Problem: {problem}
  Fix: {specific change}

SUGGESTIONS:

  Line {N}: {description}
  Improvement: {improvement}

Priority Actions:
  1. {most important}
  2. {next}
  3. {etc}
```

Summary across all files:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Refactoring Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Files Analyzed: {count}
Language: {detected_language}
Total Issues: {count}
  CRITICAL: {count}
  IMPORTANT: {count}
  SUGGESTIONS: {count}

Top Priorities:
1. {highest impact issue}
2. {next}
3. {etc}
```

---

### 4. Offer to Apply Fixes

After presenting the report:

Use AskUserQuestion:

- header: "Action"
- question: "Would you like me to apply any of these refactorings?"
- options:
  - "Apply all safe" / "Apply all safe refactorings (type annotations, modern syntax, etc.)"
  - "Apply specific" / "Tell me which specific issue to fix"
  - "Show example" / "Show example code for a specific fix"
  - "No changes" / "Keep the analysis only, don't modify any files"
- multiSelect: false

---

### 5. Apply Fixes (if requested)

For each selected fix, use Task tool with `subagent_type: "refactorer"`:

```
Prompt: Apply the following refactoring to {file_path}:

Issue: {description}
Location: Line {N}
Refactoring: {specific change to make}

Requirements:
- Preserve exact behavior
- Follow existing code style
- Run tests after changes
```

Report results:
```
Applied: {description}
  File: {file_path}
  Lines changed: {N}
  Tests: {passed|failed}
```

---

### 5.1 Quality Gate Loop (Conditional)

**Only run if fixes were applied in Step 5.**

After fixes are applied, enter a review→fix loop (max 3 iterations) to ensure quality.

**Execution mode**: Determined by `$REFACTOR_EXEC_MODE`.

```
┌──────────────────────────────────────────────────┐
│  QUALITY GATE LOOP (max 3 iterations)            │
│                                                  │
│  ┌─► code-reviewer validates changes             │
│  │   test-writer checks coverage                 │
│  │   quality-guard challenges both             │
│  │        │                                      │
│  │   All gates passed?                           │
│  │   YES → PASS → exit loop                     │
│  │   NO ↓                                       │
│  │   refactorer fixes issues (autonomous)        │
│  └───────┘                                       │
│                                                  │
│  Max iterations reached → report to user         │
└──────────────────────────────────────────────────┘
```

#### Iteration Step A — Review

**If `$REFACTOR_EXEC_MODE` = `"subagent"`:**

**Execute in a single message with multiple Task tool calls:**

**Task 1 — Use Task tool with `subagent_type: "code-reviewer"`:**

```
Prompt: Validate the refactoring changes just applied. This is a POST-REFACTORING validation — check that changes are structurally sound.

Diff of changes:
{git_diff_of_refactoring}

Original issues that were fixed:
{list_of_fixed_issues}

Check:
1. Were the original issues properly resolved?
2. Were any NEW structural issues introduced by the refactoring?
3. Is the code structurally better than before?

Return: Validation result with verdict:
- PASS: all issues resolved, no new issues
- FAIL: list each new issue with file, line, description, and fix suggestion
```

**Task 2 — Use Task tool with `subagent_type: "test-writer"`:**

```
Prompt: Check test coverage for the refactored files and add tests if needed.

Refactored files:
{list_of_modified_files}

Changes made:
{summary_of_refactorings}

Requirements:
- Verify existing tests still cover the refactored code
- Add tests for any logic paths that lost coverage due to structural changes
- Follow existing test patterns in the codebase
- Do NOT add tests for trivial changes (type hints, syntax updates, renames)
- Only add tests where refactoring introduced new code paths (e.g., extracted classes/methods)
```

After both complete, run the skeptic:

**Task 3 — Use Task tool with `subagent_type: "quality-guard"`:**

```
Prompt: Challenge the refactoring review findings (Level 2 — Implementation Validation).

Refactoring diff: {git_diff_of_refactoring}
Code-reviewer findings: {code_reviewer_output}
Test-writer findings: {test_writer_output}

Verify:
1. Did code-reviewer catch all structural regressions? Check the diff yourself.
2. Do the new tests actually cover the refactored paths, or are they trivial?
3. Are there behavioral changes disguised as "refactoring"?

Produce a Quality Review Gates report.
```

---

**If `$REFACTOR_EXEC_MODE` = `"team"` (default):**

Create a team for the quality gate review:

```
TeamCreate(team_name="refactor-qa")

TaskCreate: "Validate refactoring changes" (T1)
  description: |
    Diff: {git_diff_of_refactoring}. Original issues: {list_of_fixed_issues}.
    Check structural soundness. Share findings with teammates.

TaskCreate: "Check test coverage" (T2)
  description: |
    Refactored files: {list_of_modified_files}. Changes: {summary_of_refactorings}.
    Add tests for new code paths. Share coverage gaps with teammates.

TaskCreate: "Challenge review findings" (T3) — depends on T1, T2
  description: |
    Wait for code-reviewer and test-writer. Then verify their findings against actual code.
    Use SendMessage to challenge specific agents with evidence.

[PARALLEL - Single message with multiple Task calls]
Task tool: name: "refactor-reviewer", subagent_type: "code-reviewer", team_name: "refactor-qa"
Task tool: name: "refactor-tester", subagent_type: "test-writer", team_name: "refactor-qa"
Task tool: name: "refactor-skeptic", subagent_type: "quality-guard", team_name: "refactor-qa"
```

Assign tasks. Monitor. Skeptic challenges via SendMessage. Agents resolve gates autonomously. Collect results and TeamDelete.

---

#### Iteration Step B — Fix (if needed)

If code-reviewer returns FAIL or skeptic raises BLOCKING gates, dispatch the refactorer agent to fix them:

**Use Task tool with `subagent_type: "refactorer"`:**

```
Prompt: Fix the following issues found during post-refactoring review:

{list_of_new_issues_from_reviewer_and_skeptic}

These issues were introduced during the previous refactoring pass. Fix them while preserving the improvements already made.

Requirements:
- Fix each listed issue
- Preserve exact behavior
- Follow existing code style
- Run tests after changes
```

Then return to **Iteration Step A** (review again).

#### Loop Exit

**On PASS:** Present results and exit. In team mode, send shutdown_request to all teammates and TeamDelete.

**On max iterations (3) reached:** Present current state and remaining issues to the user. Do NOT continue looping. Clean up team if in team mode.

#### Present Results

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Quality Gate Result
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Iterations: {count}/3
Verdict: {PASS | NEEDS_ATTENTION}

Code Review:
  Original issues resolved: {count}/{total}
  New issues introduced and fixed: {count}
  Remaining issues: {count or "none"}

Skeptic Validation:
  Verdict: {APPROVED | CONDITIONAL}
  Gates: {resolved}/{raised}

Test Coverage:
  Tests passing: {yes/no}
  New tests added: {count}
  Coverage gaps: {none | list}
```

---

### 6. No Issues Found

If analysis finds no significant issues:

```
{file_path}

Code follows best practices:
  - Clean separation of concerns
  - Proper dependency management
  - Strong typing
  - Appropriate method length

No refactoring needed.
```

---

## Error Handling

**File too large (>1000 lines):**
```
{file} is very large ({N} lines)

This itself is a code smell - consider splitting.
Analyzing anyway...
```

**Too many files:**
```
Found {N} source files in {path}

Analyzing the 20 most recently modified.
Run /refactor on specific directories for full coverage.
```

---

## Important Notes

- **Read-only by default** - Analysis only unless user requests changes
- **Language-agnostic** - Detects language from file extensions, applies appropriate analysis
- **Agent-driven analysis** - Uses Explore for context and code-reviewer for issue detection
- **Post-fix validation** - Code-reviewer validates fixes, test-writer ensures coverage
- **Incremental** - Apply one change at a time via refactorer agent
- **Educational** - Explain WHY something is a code smell
