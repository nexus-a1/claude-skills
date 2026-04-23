# Shared Principles

These principles apply to all multi-agent skills and their spawned agents. Skills should reference this file to ensure consistent behavior across the ecosystem.

## Quality Standards

1. **Skeptic sign-off is mandatory.** No quality gate passes without explicit approval from the designated reviewer (quality-guard, code-reviewer, or lead-as-skeptic). "Fine for now" is not an approval.

2. **Evidence over claims.** Every finding, approval, or rejection must cite specific file paths, line numbers, or test output. Unsubstantiated claims are rejected.

3. **Fix the root cause.** Workarounds, suppressed warnings, and "temporary" patches are not fixes. Find and resolve the underlying issue.

4. **Minimal, clean solutions.** Write the least code that correctly solves the problem. Prefer framework-provided tools over custom implementations. Every line of code is a liability.

5. **Tests validate behavior, not implementation.** Test what the code does, not how it does it. Meaningful assertions over coverage theater.

## Communication Standards

6. **Terse agent-to-agent communication.** No pleasantries, no filler. State facts, report status, request action. Context windows are precious.

7. **Structured status reporting.** Use consistent format: `[TYPE]: [SUBJECT] | Details: [1-3 sentences] | Action needed: [yes/no]`

8. **SendMessage payload cap: 5 lines / ~80 words.** Hard cap, not a target. Every message must cite `file:line` (or task ID) when referring to findings. Do NOT paste full reports, full diffs, or full agent outputs into SendMessage — if a teammate needs the full context, point them at the shared file path. Share extracts, not dumps.

9. **Report blockers immediately.** If blocked, message the lead or responsible agent without delay. Never wait silently.

## Execution Standards

10. **Delegate mode for leads.** Team leads coordinate, review, and synthesize. They do not implement. If you are a team lead, your job is orchestration, not execution.

11. **Use Sonnet for execution agents, Opus for reasoning agents.** Researchers, architects, and skeptics benefit from deeper reasoning (Opus). Engineers executing well-defined specs can use Sonnet for cost efficiency.

## Write Safety

12. **No concurrent writes to the same file.** When agents run in parallel (team mode), each agent writes ONLY to files scoped to its role. Only the lead writes to shared/aggregated output files, and only after parallel work completes.

13. **Role-scoped file naming.** Agents save their work to `{feature}-{agent-role}.md` or similar role-scoped paths. This prevents write collisions and makes it clear who produced what.

## Deadlock Protocol

14. **Max 3 rejection cycles.** If a skeptic or reviewer rejects the same deliverable 3 times, STOP iterating. Escalate to the user with: (a) summary of all submissions, (b) reviewer's objections across all rounds, (c) agent's attempts to address them. The user decides: override, provide guidance, or abort.

15. **Max 2 auto-fix attempts per issue.** When auto-fixing critical findings, attempt at most 2 fixes per issue. The second attempt includes failure context from the first. If both fail, escalate to the user.

## Skill Composition

When one skill's workflow naturally needs another skill's behavior, prefer **agent delegation** over **skill chaining** in almost every case. Skill chaining is appropriate only for a narrow set of patterns.

16. **Prefer agent delegation.** If you need specialized work (code review, security audit, requirements analysis, documentation), invoke the relevant agent via `Task`. Agents are designed to be composed — they return structured output, accept narrow prompts, and cap their output for inclusion in a larger flow.

17. **Use skill chaining only for pipelines of user-facing commands.** A skill should invoke another skill (via the `Skill` tool in `allowed-tools`) only when:
    - The callee is an atomic user-facing command the user could reasonably have run directly, AND
    - The caller is explicitly orchestrating a multi-step user workflow (e.g., `/release` chains `/create-release-branch` → `/create-release` → `/merge-release`), AND
    - The callee's interactive prompts, state writes, and output format all make sense from inside the calling flow.

    Outside this pattern — "I need a piece of X's behavior" — use an agent instead of calling the skill. Skills assume interactive context; agents don't.

18. **Don't chain a skill just to reuse its internal logic.** If the logic is reusable, extract it into a shared utility (`plugin/shared/`), a `references/*.md` file, or an agent. Chaining a user-facing skill to get at its internals imports its prompts, state writes, and user interactions too — all of which usually don't belong in the caller's flow.

19. **Document chain points.** When a skill does chain another skill, the calling SKILL.md must name the exact skill called, the trigger condition, and why an agent wasn't used. This keeps the composition graph legible as skills evolve.
