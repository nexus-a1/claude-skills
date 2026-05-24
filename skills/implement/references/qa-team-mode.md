# QA Team Mode (Phase 4.1)

When `$QA_EXEC_MODE` = `"team"`, create a QA team where agents can read each other's findings, cross-pollinate, and challenge each other's work. This is more expensive but produces higher-quality results — code-reviewer can suggest tests, test-writer can flag issues found during test design, security-auditor can inform both, and quality-guard challenges everyone.

## Step 1: Create the team and task list

```
Use TeamCreate tool:
  team_name: "qa-{identifier}"
  description: "QA review for {identifier}"
```

## Step 2: Create tasks for the team

```
TaskCreate: "Write tests for implementation" (T1)
  description: |
    Implemented files: {implemented_files}
    Context: {what_was_implemented}
    Requirements: Follow existing test patterns, cover happy path and error cases.
    Share findings with teammates — flag any logic concerns discovered during test design.

TaskCreate: "Review implementation code" (T2)
  description: |
    Diff: {git_diff}
    Categorize issues as CRITICAL/IMPORTANT/MINOR.
    Focus on logic errors, performance, code quality.
    Coordinate with test-writer — suggest specific test cases for issues found.

TaskCreate: "Security review and PII scan" (T3)
  description: |
    Diff: {git_diff}
    Check for vulnerabilities, PII/secrets exposure, input validation, injection risks.
    Share findings with code-reviewer — security issues may have broader code quality implications.

TaskCreate (only if INCLUDE_ARCHITECT=true): "Review architecture" (T3b)
  description: |
    Diff: {git_diff}
    Intended plan: $WORK_DIR/{identifier}/plan.md
    Validate finished code against established architecture and patterns — boundaries,
    dependency direction, SOLID, design-pattern consistency, drift from the Phase 2.3 plan.
    Design-level findings only (CRITICAL/IMPORTANT/MINOR). Share findings with teammates.

TaskCreate: "Challenge and validate QA findings" (T4) — depends on T1, T2, T3{if INCLUDE_ARCHITECT: , T3b}
  description: |
    Requirements: $WORK_DIR/{identifier}/{identifier}-TECHNICAL_REQUIREMENTS.md
    Implementation diff: {git_diff}
    Wait for test-writer, code-reviewer, security-auditor{if INCLUDE_ARCHITECT: , and architect} to complete their initial findings.
    Then, in this order:
    1. Independent pass FIRST: trace the code paths in the diff yourself and surface what the agents missed — your primary value.
    2. Verify implementation matches requirements.
    3. Check test coverage: do the tests actually cover critical paths?
    4. Reconcile the agents' findings: verify each CRITICAL finding against the actual code; flag over/under-stated ones.
    5. Cross-reference findings for contradictions between agents.
    Terminal review before PR — report all severities (BLOCKING/IMPORTANT/ADVISORY); do not suppress medium/low findings.
    Produce a Quality Review Gates report. Use SendMessage to share gates with specific agents.
```

Use TaskUpdate to set T4 dependency on T1, T2, T3 completion.

## Step 3: Spawn teammates

```
[PARALLEL - Single message with multiple Task calls]

Task tool: name: "qa-tester", subagent_type: "test-writer", team_name: "qa-{identifier}"
Task tool: name: "qa-reviewer", subagent_type: "code-reviewer", team_name: "qa-{identifier}"
Task tool: name: "qa-security", subagent_type: "security-auditor", team_name: "qa-{identifier}"
[only if INCLUDE_ARCHITECT=true] Task tool: name: "qa-architect", subagent_type: "architect", team_name: "qa-{identifier}"
Task tool: name: "qa-skeptic", subagent_type: "quality-guard", team_name: "qa-{identifier}"
```

## Step 4: Assign tasks and monitor

Assign tasks to teammates via TaskUpdate (set owner):
- T1 → qa-tester
- T2 → qa-reviewer
- T3 → qa-security
- T3b → qa-architect (only if INCLUDE_ARCHITECT=true)
- T4 → qa-skeptic

Monitor TaskList for progress. T1-T3 (and T3b when present) run in parallel. T4 (skeptic) starts after they complete.

## Step 5: Skeptic challenge and agent resolution (in-team)

When quality-guard produces gates, it uses SendMessage to challenge specific agents:

```
SendMessage(recipient="qa-reviewer", message="GATE: Line 45 of UserService.php — you said no issues but findById() returns ?User and line 45 dereferences without null check. Verify.")
SendMessage(recipient="qa-tester", message="GATE: Your tests don't cover the empty-result case for the activity endpoint. The UNION ALL query returns different UUID formats. Add a test.")
SendMessage(recipient="qa-security", message="GATE: FeatureOverrideRequest.expires_at uses datetime.now() without timezone — verify timezone handling.")
```

Agents respond via SendMessage with evidence. Skeptic verifies responses and issues final verdict.

**Message size discipline**: Each `SendMessage` payload is capped at **5 lines / ~80 words** (see `shared/principles.md` #8). Every challenge and response must cite `file:line`. Do NOT paste full findings reports, full test output, or full diffs into messages — agents write full reports to their role-scoped files and reference the path instead. The `GATE:` examples above are the target shape.

**Max resolution rounds**: 2. After two rounds, remaining open gates are documented and escalated to user.

## Step 6: Collect results and shut down team

Gather findings from all teammates including skeptic verdict. Send shutdown_request to each teammate. Use TeamDelete to clean up.

```
SendMessage(type="shutdown_request", recipient="qa-tester", message="QA complete. Shut down.")
SendMessage(type="shutdown_request", recipient="qa-reviewer", message="QA complete. Shut down.")
SendMessage(type="shutdown_request", recipient="qa-security", message="QA complete. Shut down.")
[only if INCLUDE_ARCHITECT=true] SendMessage(type="shutdown_request", recipient="qa-architect", message="QA complete. Shut down.")
SendMessage(type="shutdown_request", recipient="qa-skeptic", message="QA complete. Shut down.")
TeamDelete()
```

**IMPORTANT**: Regardless of mode, the output of Phase 4.1 is the same — a set of QA findings categorized by severity, plus test files written, PLUS a skeptic validation report. Subsequent phases (4.2 onward) process these findings identically.
