# Epic Plan Template

Markdown template for `$WORK_DIR/{epic-id}/EPIC_PLAN.md`.

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

### {epic-ticket}-001-{slug}: {Title}
**Type**: {Database|Backend|Frontend|etc}
**Estimate**: {Small|Medium|Large}
**Dependencies**: None
**Status**: Pending

{Brief description}

### {epic-ticket}-002-{slug}: {Title}
**Type**: {Database|Backend|Frontend|etc}
**Estimate**: {Small|Medium|Large}
**Dependencies**: Blocked by {epic-ticket}-001-{slug}
**Status**: Pending

{Brief description}

...

## Implementation Order

### Wave 1 (Start first - no dependencies)
- {epic-ticket}-001-{slug}: {Title}
- {epic-ticket}-003-{slug}: {Title} *(can run in parallel)*

### Wave 2 (After Wave 1)
- {epic-ticket}-002-{slug}: {Title}
- {epic-ticket}-004-{slug}: {Title}

### Wave 3 (After Wave 2)
- {epic-ticket}-005-{slug}: {Title}

...

## Progress Tracking

- [ ] {epic-ticket}-001-{slug}: {Title}
- [ ] {epic-ticket}-002-{slug}: {Title}
- [ ] {epic-ticket}-003-{slug}: {Title}
...

## Notes
{Any important considerations, risks, or decisions made}
```
