---
paths:
  - "**/*.php"
---

# REST API Best Practices

## HTTP Status Codes

Use appropriate status codes:

| Code | Meaning | When to Use |
|------|---------|-------------|
| `200 OK` | Success | GET, PUT, PATCH |
| `201 Created` | Resource created | POST |
| `204 No Content` | Success, no body | DELETE |
| `400 Bad Request` | Validation errors | Invalid input |
| `401 Unauthorized` | Auth required | Missing/invalid token |
| `403 Forbidden` | Not authorized | Valid auth, no permission |
| `404 Not Found` | Resource missing | Entity doesn't exist |
| `409 Conflict` | Business rule violation | Duplicate, state conflict |
| `422 Unprocessable Entity` | Semantic errors | Valid syntax, invalid semantics |
| `500 Internal Server Error` | Unexpected | Unhandled exceptions |

## Response Format

### Success Response

```json
{
    "id": 123,
    "email": "user@example.com",
    "name": "John Doe",
    "createdAt": "2024-01-08T10:30:00+00:00"
}
```

### Error Response

```json
{
    "error": {
        "message": "User already exists",
        "code": "USER_ALREADY_EXISTS"
    }
}
```

### Validation Error Response

```json
{
    "error": {
        "message": "Validation failed",
        "code": "VALIDATION_ERROR",
        "details": [
            {
                "field": "email",
                "message": "This value is not a valid email address."
            },
            {
                "field": "password",
                "message": "This value is too short. It should have 8 characters or more."
            }
        ]
    }
}
```

### Collection Response

```json
{
    "data": [
        {"id": 1, "email": "user1@example.com"},
        {"id": 2, "email": "user2@example.com"}
    ],
    "meta": {
        "total": 2,
        "page": 1,
        "perPage": 20
    }
}
```

## Endpoint Naming

Follow RESTful conventions:

```
GET    /api/users              - List users
GET    /api/users/{id}         - Get single user
POST   /api/users              - Create user
PUT    /api/users/{id}         - Full update
PATCH  /api/users/{id}         - Partial update
DELETE /api/users/{id}         - Delete user

POST   /api/users/{id}/activate   - RPC-style actions
POST   /api/users/{id}/ban
```

## Date/Time Format

Always use ISO 8601 format with timezone:

```php
// ✅ GOOD
"createdAt": "2024-01-08T10:30:00+00:00"

// ❌ BAD
"createdAt": "2024-01-08 10:30:00"
"createdAt": "08/01/2024"
```

Use `DateTimeImmutable` in PHP:

```php
private \DateTimeImmutable $createdAt;
```

## Pagination

Always paginate large collections:

```php
public function findPaginated(int $page = 1, int $perPage = 20): PaginatedResult
{
    $qb = $this->createQueryBuilder('u')
        ->orderBy('u.createdAt', 'DESC')
        ->setFirstResult(($page - 1) * $perPage)
        ->setMaxResults($perPage);

    $query = $qb->getQuery();
    $paginator = new Paginator($query);

    return new PaginatedResult(
        data: iterator_to_array($paginator),
        total: count($paginator),
        page: $page,
        perPage: $perPage,
    );
}
```
