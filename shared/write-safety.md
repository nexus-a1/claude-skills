# Write Safety Conventions

These conventions prevent file write collisions when multiple agents work in parallel (team mode). Every multi-agent skill MUST follow these rules.

## Core Rule

**Agents working in parallel MUST NOT write to the same file.** This is the single most important convention for team-mode execution.

## File Ownership

| Writer | Allowed Files | Example |
|--------|--------------|---------|
| Individual agent | Role-scoped files only | `context/{feature}-{role}.md`, `qa-{role}.md` |
| Team lead only | Shared/aggregated files, final outputs | `{feature}-TECHNICAL_REQUIREMENTS.md`, `qa-gate-report.md` |
| Sequential negotiation | Shared contract files (NOT concurrent) | `api-contract.md` (one agent writes, then the other) |

## Naming Convention

Agent output files follow the pattern:
```
{scope}-{agent-role}.{ext}
```

Examples:
- `context/auth-feature-archaeologist.md`
- `context/qa-code-reviewer.md`
- `context/qa-security-auditor.md`
- `context/qa-quality-guard.md`

## Lead Aggregation Pattern

1. Parallel agents write to their role-scoped files
2. Lead waits for all parallel agents to complete
3. Lead reads all role-scoped files
4. Lead writes the consolidated output to a shared file

**Never**: Have multiple agents write to a shared file during parallel execution.

## Implementation State

Only the skill lead (main orchestrator) writes to:
- `implementation-state.json`
- `requirements-state.json`
- `manifest.json`
- Final output documents

## When to Apply

These rules apply when `execution_mode` is `"team"` (agents use TeamCreate + SendMessage). In `"subagent"` mode, agents are independent processes and cannot collide, but following these conventions is still recommended for consistency.
