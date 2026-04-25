# {Feature Title}

> **Layer: SPEC** — WHAT & WHY. Product-facing. No file paths, no class names, no HOW.

## Summary

{One paragraph describing WHAT the feature is and WHY it matters. Problem → Impact → Intended outcome. Do not describe HOW.}

## User Stories

- **US-1**: As a {role}, I want {capability}, so that {outcome}.
- **US-2**: As a {role}, I want {capability}, so that {outcome}.

## Acceptance Criteria

All AC are Given/When/Then scenarios with stable IDs (`AC-{story}.{n}`). Every AC must be observable/testable.

### AC for US-1

- **AC-1.1**
  - Given {precondition}
  - When {action}
  - Then {observable outcome}
- **AC-1.2**
  - Given ...
  - When ...
  - Then ...

### AC for US-2

- **AC-2.1**
  - Given ...
  - When ...
  - Then ...

## Security & Compliance Criteria

Security AC contributed by `security-requirements` agent. Expressed as Given/When/Then with IDs `AC-SEC-N`.

- **AC-SEC-1**
  - Given {security precondition — e.g., authenticated user lacks role X}
  - When {sensitive action attempted}
  - Then {access denied / audit logged / etc.}

## Out of Scope

- {Explicit exclusion}
- {Explicit exclusion}

## Open Questions

- {Unresolved product/business question — or "None"}
