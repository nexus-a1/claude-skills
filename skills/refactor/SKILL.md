---
name: refactor
model: claude-sonnet-5
category: code-quality
userInvocable: true
description: Analyze code and suggest refactoring improvements with agent-driven analysis. Runs in the current working tree by default — set `worktree.enabled: true` in `.claude/configuration.yml` to isolate work in a git worktree.
argument-hint: "[file|directory]"
allowed-tools: "Read, Write, Edit, Grep, Glob, Bash(source:*), Bash(echo:*), Bash(pwd:*), Bash(mkdir:*), Bash(git:*), Task, AskUserQuestion, TeamCreate, TeamDelete, TaskCreate, TaskUpdate, TaskList, TaskGet, SendMessage, EnterWorktree, ExitWorktree"
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
REFACTOR_EXEC_MODE=$(resolve_exec_mode refactor team)
REFACTOR_WORKFLOW_ENABLED=$(resolve_refactor_workflow_enabled)
echo "REFACTOR_WORKFLOW_ENABLED=$REFACTOR_WORKFLOW_ENABLED"
```

Use `$REFACTOR_EXEC_MODE` to determine team vs sub-agent behavior in Steps 3 and 5.1.
Use the printed `REFACTOR_WORKFLOW_ENABLED` to decide whether Step 5.1 attempts the
orchestrated path.

## Write Safety

When running QA agents in parallel (Step 5.1 quality gate loop), agents MUST NOT write to the same file:

- **code-reviewer**: Returns findings via Task result only
- **test-writer**: Writes test files — on the CLASSIC path only. On the orchestrated
  quality-gate path it reports coverage gaps and writes nothing; the lead authors them
  at Loop Exit, because a file write inside that fan-out is a race (scoped to test directories)
- **quality-guard**: Returns validation via Task result only
- **refactorer**: The only agent that modifies source code, runs sequentially (not in parallel with reviewers)

See `${CLAUDE_PLUGIN_ROOT}/shared/write-safety.md` (or `~/.claude/shared/write-safety.md` for local/dev copies) for the full conventions.

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
  # A rejected service NAME returns 1 with EMPTY stdout (a rejected PATH is
  # different: it falls back to the name-is-the-directory convention). `git -C ""`
  # is a documented no-op that runs in the CURRENT repo, so an unguarded empty
  # value here creates the worktree in whatever repository the session is in.
  [ -n "$svc_path" ] || { echo "skipping $svc: no usable path" >&2; continue; }
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

**Use Task tool with `subagent_type: "Explore"`:** Pass purpose, not just a query — the prompt below states this is a REFACTORING analysis (structural patterns to preserve), not a bug hunt or PR review, so the agent scopes its report accordingly. If it returns no concrete anchors (`file:line`, symbols), re-dispatch with a refined query (≤3 cycles). See `${CLAUDE_PLUGIN_ROOT}/shared/subagent-context-discipline.md` (or `~/.claude/shared/subagent-context-discipline.md` for local/dev copies).

```
Prompt: Analyze the codebase context for refactoring the following files. PURPOSE: this feeds a refactoring-opportunity analysis — surface structural patterns, conventions, and coupling to preserve; this is NOT a bug hunt.

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

#### 5.1.0 Path selection

Two paths through **Iteration Step A only**. The orchestrated one runs the three reviewers
blind and puts every finding through adversarial verification; the classic one is everything
below it and remains fully supported.

**Attempt the orchestrated path when both hold:**
- `<REFACTOR_WORKFLOW_ENABLED printed above>` is `true` (the default), and
- the `Workflow` tool is available in this session.

**If so, read `references/workflow-quality-gate.md` and follow it.** It replaces Iteration
Step A and changes what `Loop Exit` and `Present Results` receive. Pass the diff, the file
list, the issues Step 5 set out to fix, a one-line summary of the refactoring, the current
round number, the cap, and a timestamp as `args` — the script cannot read files or shell
out, so anything it needs must arrive that way.

**Three things it does NOT replace. All of them stay here, in the lead:**

1. **Iteration Step B in full.** `refactorer` edits source files, and a file write inside a
   fan-out is a race.
2. **The loop, the round cap and `Loop Exit`.** The script runs once per round and reports a
   verdict for the state it was given; it does not know when to stop.
3. **Authoring any tests the `coverage` dimension names.** On this path `test-writer`
   reports gaps and writes nothing, for the same race reason. They are authored at **Loop
   Exit's PASS branch**, not in Step B — a coverage gap is usually `important` or `minor`,
   which does not hold the gate, so the round passes and Step B never runs. Pinning them to
   Step B loses them on the commonest shape of run.

**Take the classic path — silently, it is not an error — when:**
- the config disables it, or
- the `Workflow` tool is not available, or
- the orchestrated run fails, does not complete, or returns `ok: false`.

**On any of those, run Iteration Step A below in full.** Do not merge a partial orchestrated
result into a classic round, and do not present a partial round as complete. Name the path
taken in `Present Results` either way.

> Detection is attempt-and-observe: nothing in the tool's contract describes how absence
> manifests, so do not write logic that depends on a specific error shape. If the
> orchestrated path does not produce a result, take the fallback.

Execution mode is not consulted on the orchestrated path. `workflow` is not a third value of
`execution_mode`; it replaces the choice for this step, because a script has no teammate
protocol.

---

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

#### 5.1.9 Consume the orchestrated result (orchestrated path only)

Skip this step entirely on the classic path.

The script returned typed data. **Do not re-summarise it** — the aggregation already
happened, mechanically, where it could not be renegotiated. Render it; do not re-judge it.

1. **The verdict drives the loop, and it has THREE values.** `pass` exits. `fail` goes to
   Iteration Step B and then another round if under the cap. **`unverified` is neither** — a
   panel was short, so nothing was tallied. Treat it as a round that did not conclude: say so
   plainly, mark every finding `[UNVERIFIED]`, and never report it as a pass. It still counts
   against the round cap, because the alternative is an unbounded retry on a broken panel.
2. **Report every surviving finding**, with its file, line, severity and the verbatim
   evidence. Dropping one here would undo the verification.
3. **Dropped findings go in their own section**, each with the lenses that refuted it and
   their reasons. A dropped finding that vanishes silently is indistinguishable from one that
   was never found — and on a quality gate, the reader needs to see what was considered and
   rejected, not only what remains.
4. **Name every dimension in `coverage` that produced nothing**, and separately any that did
   not run at all (`reviewIntegrity.missing`). Silence from a dimension is not a clean bill
   from it.
5. **Author the tests the `coverage` dimension named** — at **Loop Exit**, on the PASS
   branch, not in Step B. Step B runs only on `fail`, and a coverage gap rarely fails the
   gate, so Step B is the one place that would reliably miss them.
6. **Only a VERIFIED `blocking` finding holds the gate.** A finding no challenger judged comes back `verified: false` and the round's verdict is `unverified`, not `fail`. Important and minor ones are reported and do
   not force another round — the loop exists to stop regressions, not to reach zero findings.
   A gate that never passes burns all three rounds and reports failure regardless of what was
   actually fixed.

---

#### Loop Exit

**On PASS — orchestrated path only, BEFORE exiting:** author any surviving finding whose
`dimension` is `coverage`. On this path `test-writer` reported those gaps and wrote nothing,
and a coverage gap is normally `important` or `minor` — which does not hold the gate, so the
round passes and the loop ends here. Pinning the authoring to Iteration Step B would lose
them entirely in the single most likely shape of a run: refactoring sound, one coverage gap,
verdict `pass`, Step B never runs. The classic path would have written those tests, so
skipping them is a real regression against it, on the common path rather than a rare one.

Author them, re-run the project's test command, and only then exit. If authoring them changes
source or test files, say so in the results — the user approved a refactoring, and these are
additional edits made after the gate passed.

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
