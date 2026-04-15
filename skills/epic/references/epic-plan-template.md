# Epic Plan Template

Markdown template for `$WORK_DIR/{epic-slug}/EPIC_PLAN.md`.

```markdown
# Epic: {Title}

## Overview
{What this epic accomplishes}

## Business Context
**Problem**: {Current state/pain point}
**Goal**: {Desired outcome}
**Impact**: {Who benefits and how}

## Technical Scope
- **Frontend**: {Yes/No - what components}
- **Backend**: {Yes/No - what services}
- **Database**: {Yes/No - what changes}
- **Infrastructure**: {Yes/No - what resources}
- **Integrations**: {Yes/No - what APIs}

## Tickets ({count})

### {epic-slug}-001: {Title}
**Type**: {Database|Backend|Frontend|etc}
**Estimate**: {Small|Medium|Large}
**Dependencies**: None
**Status**: Pending

{Brief description}

### {epic-slug}-002: {Title}
**Type**: {Database|Backend|Frontend|etc}
**Estimate**: {Small|Medium|Large}
**Dependencies**: Blocked by {epic-slug}-001
**Status**: Pending

{Brief description}

...

## Implementation Order

### Wave 1 (Start first - no dependencies)
- {epic-slug}-001: {Title}
- {epic-slug}-003: {Title} *(can run in parallel)*

### Wave 2 (After Wave 1)
- {epic-slug}-002: {Title}
- {epic-slug}-004: {Title}

### Wave 3 (After Wave 2)
- {epic-slug}-005: {Title}

...

## Progress Tracking

- [ ] {epic-slug}-001: {Title}
- [ ] {epic-slug}-002: {Title}
- [ ] {epic-slug}-003: {Title}
...

## Notes
{Any important considerations, risks, or decisions made}
```
