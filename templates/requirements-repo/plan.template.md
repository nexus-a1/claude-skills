# Technical Plan — {Feature Title}

> **Layer: PLAN** — HOW. Implementer-facing. Reference AC IDs from `spec.md`; do not restate criteria.

## Approach

{2–3 paragraphs. Narrative of the chosen technical approach and WHY it fits the existing architecture. Reference AC IDs the approach satisfies.}

## Files to Touch

(From `archaeologist`. Format: `path — purpose`.)

- `src/path/to/file.ext` — {what this file's role in the change is}
- `src/...` — ...

## Architecture Constraints

(From `architect`: layer rules, DI patterns, SOLID concerns, dependency direction. Cite existing conventions being followed.)

- {constraint 1}
- {constraint 2}

## Data Model

(From `data-modeler` — omit entire section if no DB changes.)

### Entity Changes
- {Entity}: {field/index/relation change}

### Migration Safety
- {backward compat notes, rollout order}

### Query Patterns
- {read/write paths affected}

## External Integrations

(From `integration-analyst` — omit if no external APIs involved.)

- **{API/service}**: {endpoint, contract changes, resilience pattern}

## Security & Infrastructure Notes

(Implementation-level notes. Do NOT restate AC — cross-reference by ID.)

- Implementation for `AC-SEC-1`: {auth middleware, encryption choice, audit hook location}
- Infrastructure (from `aws-architect` if applicable): {IAM, networking, cost considerations}

## Risks & Mitigations (MoSCoW)

| Priority | Risk | Mitigation |
|----------|------|------------|
| Must | {risk} | {mitigation} |
| Should | {risk} | {mitigation} |
| Could | {risk} | {mitigation} |

### Deferred Security Items

(Any security finding descoped from this ticket. Include finding, original severity, reason for deferral. Omit section if none.)

## Decision Log

(Conflict resolutions from synthesis.)

| Decision | Options | Chosen | Rationale |
|----------|---------|--------|-----------|
| {decision} | A / B / C | B | {why B wins — reference agent findings by path} |
