# PROJECT-123: Feature Title

**Status:** Completed
**Created:** YYYY-MM-DD
**Completed:** YYYY-MM-DD
**Branch:** feature/PROJECT-123
**PR:** [#123](https://github.com/org/repo/pull/123)

---

## Overview

Brief description of the feature and its purpose.

**Problem:** What business problem does this solve?

**Solution:** High-level approach taken.

---

## Requirements

### Functional Requirements

- **FR1:** First functional requirement
- **FR2:** Second functional requirement
- **FR3:** Third functional requirement

### Non-Functional Requirements

- **NFR1:** Performance requirement (e.g., response time < 200ms)
- **NFR2:** Security requirement (e.g., authentication required)
- **NFR3:** Scalability requirement (e.g., handle 10k concurrent users)

### Acceptance Criteria

- [ ] Criterion 1 - Specific, testable condition
- [ ] Criterion 2 - Specific, testable condition
- [ ] Criterion 3 - Specific, testable condition

---

## Architecture

### Components Affected

| Component | Change Type | Description |
|-----------|-------------|-------------|
| ComponentName | New | Brief description |
| ExistingComponent | Modified | What changed |

### Data Model

**Tables affected:**
- `table_name` - Description of changes

**Migrations:**
- `YYYY_MM_DD_create_table.php` - What it does

### API Endpoints

**New endpoints:**
- `POST /api/resource` - Create resource
- `GET /api/resource/{id}` - Get resource by ID

**Modified endpoints:**
- `GET /api/existing` - Added filtering capability

### External Integrations

- **AWS S3** - Used for file storage
- **Third-party API** - Purpose and usage

---

## Implementation Approach

### Chosen Approach

Description of the approach selected and why it was chosen over alternatives.

### Alternatives Considered

1. **Alternative 1:** Brief description
   - Pros: Benefits
   - Cons: Drawbacks
   - Decision: Why not chosen

2. **Alternative 2:** Brief description
   - Pros: Benefits
   - Cons: Drawbacks
   - Decision: Why not chosen

### Design Patterns Used

- **Pattern 1:** Where and why used
- **Pattern 2:** Where and why used

---

## Technical Decisions

### Decision 1: Decision Title

**Context:** Background and problem

**Options:**
1. Option A
2. Option B
3. Option C

**Decision:** Chose Option B

**Rationale:** Why this option was selected

**Consequences:** Trade-offs and implications

---

### Decision 2: Decision Title

(Repeat structure for each major decision)

---

## Implementation Notes

### Key Files Changed

```
src/
├── Controller/
│   └── ResourceController.php (new)
├── Service/
│   └── ResourceService.php (new)
├── Entity/
│   └── Resource.php (new)
└── Repository/
    └── ResourceRepository.php (new)
```

### Code Highlights

**Pattern Example:**
```php
// Brief comment explaining the pattern
public function example() {
    // Key implementation detail
}
```

### Gotchas & Considerations

- **Gotcha 1:** Description and how to avoid
- **Gotcha 2:** Description and how to avoid
- **Performance:** Optimization notes

---

## Testing

### Test Coverage

- Unit tests: 95%
- Integration tests: 85%
- E2E tests: Key user flows covered

### Test Scenarios

1. **Scenario 1:** Description
   - Given: Initial state
   - When: Action taken
   - Then: Expected result

2. **Scenario 2:** Description
   - Given: Initial state
   - When: Action taken
   - Then: Expected result

---

## Related Work

### Similar Past Implementations

- **PROJECT-100:** Similar feature description
  - What we learned: Key takeaway
  - What we reused: Patterns or code

### Dependencies

- **Blocks:** PROJECT-456 (needs this feature to proceed)
- **Blocked by:** None
- **Related:** PROJECT-789 (complementary feature)

---

## References

- [Original ticket](https://jira.company.com/PROJECT-123)
- [Technical design doc](link)
- [API documentation](link)
- [Related RFC](link)

---

## Lessons Learned

### What Went Well

- Success 1
- Success 2

### What Could Be Improved

- Area for improvement 1
- Area for improvement 2

### Recommendations for Similar Work

- Recommendation 1: Specific advice
- Recommendation 2: Specific advice

---

**Tags:** feature-type, domain, technology, pattern

**Archived by:** Archivist Agent
**Archived on:** YYYY-MM-DD
