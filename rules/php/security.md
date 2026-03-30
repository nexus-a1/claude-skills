---
paths:
  - "**/*.php"
---

# PHP Security Guidelines

## Input Validation

Always validate input at the controller level:

```php
final readonly class CreateUserRequest
{
    public function __construct(
        #[Assert\NotBlank]
        #[Assert\Email]
        #[Assert\Length(max: 180)]
        public string $email,

        #[Assert\NotBlank]
        #[Assert\Length(min: 8, max: 4096)]
        #[Assert\PasswordStrength]
        public string $password,
    ) {
    }
}
```

## Password Hashing

Use Symfony's password hasher:

```php
$hashedPassword = $this->passwordHasher->hashPassword(
    $user,
    $plainPassword
);
```

## Secrets Management

Never commit secrets to repository:

```env
# .env.local (not committed)
DATABASE_URL="mysql://user:password@127.0.0.1:3306/db"
JWT_SECRET_KEY=%kernel.project_dir%/config/jwt/private.pem
```

## Rate Limiting

Implement rate limiting for sensitive endpoints:

```php
#[Route('/api/auth/login', methods: ['POST'])]
#[RateLimit(limit: 5, period: 60)] // 5 attempts per minute
public function login(LoginRequest $request): JsonResponse
{
    // ...
}
```

## CORS Configuration

Configure CORS properly:

```yaml
# config/packages/nelmio_cors.yaml
nelmio_cors:
    defaults:
        origin_regex: true
        allow_origin: ['^https?://localhost(:[0-9]+)?$']
        allow_methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']
        allow_headers: ['Content-Type', 'Authorization']
        expose_headers: ['Link']
        max_age: 3600
```

## Authorization with Voters

Use Voters for complex authorization logic:

```php
final class UserVoter extends Voter
{
    private const EDIT = 'USER_EDIT';
    private const DELETE = 'USER_DELETE';

    protected function supports(string $attribute, mixed $subject): bool
    {
        return in_array($attribute, [self::EDIT, self::DELETE], true)
            && $subject instanceof User;
    }

    protected function voteOnAttribute(
        string $attribute,
        mixed $subject,
        TokenInterface $token
    ): bool {
        $user = $token->getUser();

        if (!$user instanceof User) {
            return false;
        }

        /** @var User $targetUser */
        $targetUser = $subject;

        return match($attribute) {
            self::EDIT => $this->canEdit($user, $targetUser),
            self::DELETE => $this->canDelete($user, $targetUser),
            default => false,
        };
    }
}
```

## SQL Injection Prevention

Always use parameterized queries:

```php
// ✅ GOOD
$qb->where('u.email = :email')
    ->setParameter('email', $email);

// ❌ BAD - SQL injection risk
$qb->where("u.email = '$email'");
```

## Exception Handling

Never expose internal errors:

```php
private function handleGenericException(\Throwable $exception): JsonResponse
{
    $this->logger->error($exception->getMessage(), [
        'exception' => $exception,
    ]);

    return new JsonResponse(
        data: [
            'error' => [
                'message' => 'An unexpected error occurred',
                'code' => 'INTERNAL_ERROR',
            ],
        ],
        status: Response::HTTP_INTERNAL_SERVER_ERROR,
    );
}
```

## Security Anti-Patterns

- ❌ Never catch generic exceptions without re-throwing
- ❌ Never expose stack traces or internal paths in responses
- ❌ Never store plain-text passwords
- ❌ Never trust user input without validation
- ❌ Never use `md5()` or `sha1()` for passwords
- ❌ Never disable CSRF protection
- ❌ Never log sensitive data (passwords, tokens, PII)
