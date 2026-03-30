---
description: Workflow orchestration principles for effective Claude Code task execution
---

# Workflow Orchestration

### 1. Plan Mode Default

- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately — don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy

- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop

- After ANY correction from the user: update the project's `CLAUDE.md` or memory file with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done

- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)

- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes — don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing

- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests — then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

### 7. Orchestration Discipline

- **Branch first, read after** — always create/switch to the target branch before reading files that will be edited. Files on different branches diverge. Sequence: (1) branch, (2) read, (3) edit.
- **Pre-flight Glob before Write** — before writing any file, Glob the target paths to check which already exist. Read existing files before overwriting. Discovering this at write-time wastes a round-trip.
- **Challenge plan vs. current behavior** — before implementing a plan, compare its stated behavior against the existing code. If the plan changes how the system currently works, surface the discrepancy: "The plan says X, but the current code does Y — which is intended?"
- **Producer-first rule** — when researching service chains (Service → SQS → Lambda → Service), trace the producer first. Extract the consumer identifier (queue name, endpoint URL) from its output, then search for the consumer. Never search for downstream consumers in parallel with tracing the producer when the consumer's identity depends on the producer's output.
- **Direct tool for targeted lookups** — once you have a specific filename, queue name, or pattern, use Glob/Grep directly. Don't delegate single-query lookups to subagents. A Glob resolves in <1s; a subagent takes 30-200s for the same result.
- **Proactive save after research** — after completing a multi-round research session that produces substantial output (workflow maps, pipeline docs, context documents), save to brainstorm or context storage without waiting for a manual prompt.

### 8. Phase Handoff

- **Structured file index** — when Explore or deep-dive agents complete a research phase, end the output with a Key File Index:
  ```
  ## Key File Index
  | File | Purpose | Key Methods/Interfaces | Lines Read |
  |------|---------|----------------------|------------|
  ```
  Downstream agents receive this index with the instruction: "Consult the Key File Index. Only re-read a file if you need detail the index doesn't provide."

- **Non-overlapping scopes** — before launching parallel agents, define each agent's exclusive domain. Split by system/component, not by feature keyword.

- **Deduplication** — when cross-pollination makes earlier findings available, later agents should reference those findings, not re-analyze the same files.

---

## Task Management

1. **Plan First**: Write plan using the TodoWrite tool with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review notes to the todo list when done
6. **Capture Lessons**: Update the project's `CLAUDE.md` or memory file after corrections

---

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.
