# Subagent-Context Discipline

Baseline for any orchestrator (skill or agent) that dispatches a research/analysis sub-agent. The orchestrator holds semantic context the sub-agent lacks: the sub-agent sees only the literal query, not the *purpose* behind it. A query without purpose produces output scoped to the words, not the need. Close that gap on every dispatch.

## Pass Purpose, Not Just a Query

When you dispatch a sub-agent, the prompt must carry — beyond the literal query:

- **Objective** — *why* this work exists and what decision its output feeds (e.g. "this inventory feeds Stage-4 synthesis; flag gaps explicitly", "this is a REFACTORING analysis, not a PR review").
- **Downstream consumer** — who reads the result next and in what form they need it.
- **Skill conventions** — the dispatching skill's output-format expectations and scope constraints, so the result lands usable without a second pass.

A dispatch that states only the query is incomplete. If a dispatch site has no meaningful convention or downstream to convey, say so rather than emitting boilerplate.

## Iterative Retrieval (thin-output recovery)

When a dispatched agent returns output too thin to act on, do not proceed on an empty result and do not guess. Re-dispatch with a refined query.

- **Emptiness threshold** — output is "thin" when it contains no concrete anchors: no `file:line` references, no class/function/symbol names, no API signatures or table/column identifiers. Subjective summaries without anchors count as thin.
- **The loop** — *dispatch → evaluate → refine*. On a thin result, narrow or re-frame the query (add the missing objective, point at a specific area, ask for concrete anchors) and dispatch again.
- **Hard cap: 3 cycles.** On the third still-thin result, stop looping and escalate to the user with what was tried and what is still missing — do not iterate further (mirrors the troubleshoot Deadlock Protocol).

## Boundary With Direct Lookups (workflow.md §7)

This protocol governs *agent dispatch when output lacks actionable specifics*. It does **not** override §7 "Direct tool for targeted lookups": once you hold a concrete identifier — a filename, symbol, queue name, or `file:line` — use Glob/Grep directly rather than re-dispatching an agent. Iterative re-dispatch applies only *while* discovery output still lacks those specifics; the moment concrete anchors return, §7 takes over.
