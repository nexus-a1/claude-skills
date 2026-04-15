# Epic Error Handling

## No description provided

```
Error: Epic description required.

Usage: /epic "description of what to build"

Examples:
  /epic "Implement user authentication with JWT"
  /epic "Add Stripe payment processing"
  /epic "Migrate from monolith to microservices"
```

## Epic too small

```
Analysis: This work is simple enough for a single ticket.

Recommendation: Use /create-requirements instead.

This epic feature is for complex, multi-ticket initiatives.
```

## Epic already exists

```
Warning: Epic '{epic-slug}' already exists.

Options:
  1. Continue with existing epic
  2. Create new epic with different name
  3. Delete existing and recreate

[Select 1-3]:
```
