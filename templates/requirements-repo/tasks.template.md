# Implementation Tasks — {Feature Title}

> **Layer: TASKS** — EXECUTE. Dependency-ordered. Every task MUST cite one or more AC IDs from `spec.md`.

## Wave 1 (no dependencies)

- [ ] **T-1** — {Short task title}
  - Scope: {1–2 line description of what this task produces}
  - Covers: AC-1.1, AC-1.2
- [ ] **T-2** — {title}
  - Scope: ...
  - Covers: AC-2.1

## Wave 2 (depends on Wave 1)

- [ ] **T-3** — {title}
  - Scope: ...
  - Depends on: T-1
  - Covers: AC-1.3, AC-SEC-1

## Wave N (...)

- [ ] **T-N** — ...

## Parallelization

Tasks safe to run concurrently:
- Group A: {T-1, T-2}
- Group B: {T-4, T-5}

## Coverage Check

Every AC in `spec.md` maps to at least one task:

| AC ID | Covered by |
|-------|------------|
| AC-1.1 | T-1 |
| AC-1.2 | T-1 |
| AC-1.3 | T-3 |
| AC-2.1 | T-2 |
| AC-SEC-1 | T-3 |
