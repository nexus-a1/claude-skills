---
paths:
  - "**/*.php"
---

# PHP Code Style Guidelines

**PHP Version:** 8.2+
**Standard:** PSR-12

## Strict Types

Always declare strict types at the top of every PHP file:

```php
<?php

declare(strict_types=1);

namespace App\Service;
```

## Type Declarations

Use type hints for everything:

```php
// ✅ GOOD
public function createUser(string $email, int $age): User

// ❌ BAD
public function createUser($email, $age)
```

## Constructor Property Promotion

Use modern constructor syntax:

```php
// ✅ GOOD
final readonly class CreateUserRequest
{
    public function __construct(
        public string $email,
        public string $password,
        public ?string $name = null,
    ) {
    }
}
```

## Readonly Properties

Use `readonly` for immutable data:

```php
final readonly class UserDTO
{
    public function __construct(
        public int $id,
        public string $email,
        public \DateTimeImmutable $createdAt,
    ) {
    }
}
```

## Enums Over Constants

```php
// ✅ GOOD
enum UserStatus: string
{
    case ACTIVE = 'active';
    case INACTIVE = 'inactive';
    case BANNED = 'banned';
}

// ❌ BAD - use enums instead
class UserStatus
{
    public const ACTIVE = 'active';
}
```

## Attributes Over Annotations

```php
// ✅ GOOD
#[ORM\Entity(repositoryClass: UserRepository::class)]
#[ORM\Table(name: 'users')]
class User
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: 'integer')]
    private ?int $id = null;
}
```

## Named Arguments

Use for clarity with multiple parameters:

```php
$user = $userService->createUser(
    email: 'user@example.com',
    password: 'secret',
    sendWelcomeEmail: true,
);
```

## Match Over Switch

```php
// ✅ GOOD
$statusLabel = match($user->getStatus()) {
    UserStatus::ACTIVE => 'Active User',
    UserStatus::INACTIVE => 'Inactive User',
    UserStatus::BANNED => 'Banned User',
};
```

## Null Safe Operator

```php
// ✅ GOOD
$country = $user?->getAddress()?->getCountry();

// ❌ BAD
$country = null;
if ($user !== null && $user->getAddress() !== null) {
    $country = $user->getAddress()->getCountry();
}
```

## Final Classes by Default

```php
// ✅ GOOD - Classes are final unless designed for extension
final class UserService
{
    // ...
}
```

## Strict Comparison

Always use strict comparison:

```php
// ✅ GOOD
if ($value === null) { }
if ($count === 0) { }
if (in_array($item, $array, true)) { }

// ❌ BAD
if ($value == null) { }
if (!$count) { }
if (in_array($item, $array)) { }
```

## No Magic Numbers/Strings

```php
// ✅ GOOD
private const MAX_LOGIN_ATTEMPTS = 5;

if ($attempts >= self::MAX_LOGIN_ATTEMPTS) { }

// ❌ BAD
if ($attempts >= 5) { }
```

## Early Returns

Prefer early returns over nested conditions:

```php
// ✅ GOOD
public function processUser(User $user): void
{
    if (!$user->isActive()) {
        return;
    }

    if (!$user->isVerified()) {
        return;
    }

    // Process active, verified user
}
```

## Method Length

- Aim for 10-20 lines
- Max 50 lines
- If longer, extract to private methods

## Class Responsibility

One class, one responsibility:

```php
// ✅ GOOD - Separate concerns
final readonly class UserService { }
final readonly class EmailService { }
final readonly class NotificationService { }
```
