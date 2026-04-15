# Brainstorm Display Templates

User-facing display formats for Phase 3 (approaches) and Phase 4 (refined implementation picture).

## Phase 3.2: Approach Presentation Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Implementation Approaches: {feature}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### Approach 1: {Name}
Complexity: {Simple|Moderate|Complex} | Timeline: {estimate}

**Architecture:**
{high-level description}

**Pros:**
✓ {benefit 1}
✓ {benefit 2}

**Cons:**
✗ {drawback 1}
✗ {drawback 2}

**Best for:** {when to choose this approach}

---

### Approach 2: {Name}
...

---

### Approach 3: {Name}
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Phase 4.3: Implementation Picture Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Implementation Picture: {approach_name}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Components

**Controllers:**
- {Controller1} - {purpose}
- {Controller2} - {purpose}

**Services:**
- {Service1} - {business logic}
- {Service2} - {business logic}

**Entities:**
- {Entity1} - {table/fields}
- {Entity2} - {table/fields}

**External APIs:**
- {API1} - {integration points}

## Data Flow

1. {Step 1}
2. {Step 2}
3. {Step 3}
...

## Database Changes

- Migration: Create {table_name}
  - field1: type
  - field2: type
  - index on (field1, field2)

## API Endpoints

### POST /api/path
Request: {...}
Response: {...}
Errors: {...}

## Security

- {Security consideration 1}
- {Security consideration 2}

## Testing

- Unit: {what to test}
- Integration: {what to test}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
