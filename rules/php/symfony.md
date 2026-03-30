---
paths:
  - "**/*.php"
---

# Symfony Conventions

**Symfony Version:** 6.x+

## Service Configuration

Prefer autowiring and autoconfiguration:

```yaml
# config/services.yaml
services:
    _defaults:
        autowire: true
        autoconfigure: true

    App\:
        resource: '../src/'
        exclude:
            - '../src/DependencyInjection/'
            - '../src/Entity/'
            - '../src/Kernel.php'
```

## Controller Best Practices

Controllers should be **thin** - only handle HTTP concerns:

```php
#[Route('/api/users', name: 'api_users_')]
final class UserController extends AbstractController
{
    public function __construct(
        private readonly UserService $userService,
    ) {
    }

    #[Route('', name: 'create', methods: ['POST'])]
    public function create(
        #[MapRequestPayload] CreateUserRequest $request,
    ): JsonResponse {
        $user = $this->userService->createUser($request);

        return $this->json($user, Response::HTTP_CREATED);
    }

    #[Route('/{id}', name: 'get', methods: ['GET'])]
    public function get(int $id): JsonResponse
    {
        $user = $this->userService->getUserById($id);

        return $this->json($user);
    }
}
```

## Service Layer

Business logic lives here:

```php
final readonly class UserService
{
    public function __construct(
        private UserRepository $userRepository,
        private PasswordHasherInterface $passwordHasher,
        private EventDispatcherInterface $eventDispatcher,
    ) {
    }

    public function createUser(CreateUserRequest $request): UserDTO
    {
        // Validate business rules
        if ($this->userRepository->existsByEmail($request->email)) {
            throw new UserAlreadyExistsException($request->email);
        }

        // Create entity
        $user = new User();
        $user->setEmail($request->email);
        $user->setPassword(
            $this->passwordHasher->hashPassword($user, $request->password)
        );

        // Persist
        $this->userRepository->save($user);

        // Dispatch event
        $this->eventDispatcher->dispatch(
            new UserCreatedEvent($user->getId())
        );

        // Return DTO
        return UserDTO::fromEntity($user);
    }
}
```

## DTOs (Data Transfer Objects)

Use DTOs for input and output:

```php
// Input DTO
final readonly class CreateUserRequest
{
    public function __construct(
        #[Assert\NotBlank]
        #[Assert\Email]
        public string $email,

        #[Assert\NotBlank]
        #[Assert\Length(min: 8)]
        public string $password,

        #[Assert\Length(max: 255)]
        public ?string $name = null,
    ) {
    }
}

// Output DTO
final readonly class UserDTO
{
    public function __construct(
        public int $id,
        public string $email,
        public ?string $name,
        public string $status,
        public \DateTimeImmutable $createdAt,
    ) {
    }

    public static function fromEntity(User $user): self
    {
        return new self(
            id: $user->getId(),
            email: $user->getEmail(),
            name: $user->getName(),
            status: $user->getStatus()->value,
            createdAt: $user->getCreatedAt(),
        );
    }
}
```

## Entity Guidelines

Entities are data structures with minimal logic:

```php
#[ORM\Entity(repositoryClass: UserRepository::class)]
#[ORM\Table(name: 'users')]
#[ORM\HasLifecycleCallbacks]
class User
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: 'integer')]
    private ?int $id = null;

    #[ORM\Column(type: 'string', length: 180, unique: true)]
    private string $email;

    #[ORM\Column(type: 'string', enumType: UserStatus::class)]
    private UserStatus $status = UserStatus::ACTIVE;

    #[ORM\Column(type: 'datetime_immutable')]
    private \DateTimeImmutable $createdAt;

    #[ORM\PrePersist]
    public function onPrePersist(): void
    {
        $this->createdAt = new \DateTimeImmutable();
    }

    // Domain behavior is OK in entities
    public function activate(): void
    {
        $this->status = UserStatus::ACTIVE;
    }

    public function ban(): void
    {
        $this->status = UserStatus::BANNED;
    }
}
```

## What NOT to Do

- ❌ Never call Repository from Controller directly
- ❌ Never return Entities from Controllers (use DTOs)
- ❌ Never put logic in Templates
- ❌ Never use global state (`$_SESSION`, `$GLOBALS`)
- ❌ Never use `exit()` or `die()`
- ❌ Never use static methods for business logic
- ❌ Never modify input DTOs (use readonly)
