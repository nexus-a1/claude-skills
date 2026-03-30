---
paths:
  - "**/*.php"
---

# PHP Architecture Guidelines

**Architecture:** Pragmatic Layered + Services
**Application Type:** REST API Services

## Layered Architecture Pattern

```
┌─────────────────────────────────────┐
│  Controller Layer                   │  ← HTTP concerns only
│  (Request validation, Response)     │
└──────────────┬──────────────────────┘
               ↓
┌─────────────────────────────────────┐
│  Service Layer                      │  ← Business logic
│  (Domain operations, orchestration) │
└──────────────┬──────────────────────┘
               ↓
┌─────────────────────────────────────┐
│  Repository Layer                   │  ← Data access
│  (Queries, persistence)             │
└──────────────┬──────────────────────┘
               ↓
┌─────────────────────────────────────┐
│  Entity Layer                       │  ← Data structures
│  (Domain models, constraints)       │
└─────────────────────────────────────┘
```

## Supporting Components

- **DTOs (Data Transfer Objects)**: For input/output, separate from entities
- **Value Objects**: For complex types (Email, Money, UUID)
- **Events**: For side effects and decoupling
- **Factories**: For complex object creation
- **Validators**: Custom validation logic

## Layer Responsibilities

### Controller Layer
- HTTP concerns only (Request/Response)
- Max 20-30 lines per action
- No business logic
- No repository calls directly
- No complex transformations
- Use attributes for routing and validation
- Use `MapRequestPayload` for automatic DTO mapping

### Service Layer
- One service per domain concept (UserService, OrderService, etc.)
- No HTTP knowledge (no Request/Response objects)
- Return DTOs, not entities
- Use dependency injection
- Keep methods focused and testable
- Use events for side effects

### Repository Layer
- No business logic
- Return entities or collections
- Use QueryBuilder for complex queries
- Type-hint return values
- Flush in repository methods for convenience

### Entity Layer
- Data structures with minimal logic
- Domain behavior is OK (activate(), ban(), etc.)
- Use lifecycle callbacks for timestamps
