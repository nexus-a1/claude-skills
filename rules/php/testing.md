---
paths:
  - "**/*.php"
  - "**/tests/**"
---

# PHP Testing Strategy

## Test Types

1. **Unit Tests** - Test individual classes in isolation
2. **Integration Tests** - Test services with real dependencies
3. **Functional Tests** - Test API endpoints end-to-end

## Unit Test Example

```php
final class UserServiceTest extends TestCase
{
    private UserService $service;
    private UserRepository $repository;
    private PasswordHasherInterface $passwordHasher;

    protected function setUp(): void
    {
        $this->repository = $this->createMock(UserRepository::class);
        $this->passwordHasher = $this->createMock(PasswordHasherInterface::class);

        $this->service = new UserService(
            $this->repository,
            $this->passwordHasher,
            $this->createMock(EventDispatcherInterface::class),
        );
    }

    public function testCreateUserSuccess(): void
    {
        $request = new CreateUserRequest(
            email: 'test@example.com',
            password: 'password123',
        );

        $this->repository
            ->expects($this->once())
            ->method('existsByEmail')
            ->with('test@example.com')
            ->willReturn(false);

        $this->passwordHasher
            ->expects($this->once())
            ->method('hashPassword')
            ->willReturn('hashed_password');

        $result = $this->service->createUser($request);

        $this->assertInstanceOf(UserDTO::class, $result);
    }

    public function testCreateUserThrowsWhenEmailExists(): void
    {
        $this->repository
            ->method('existsByEmail')
            ->willReturn(true);

        $this->expectException(UserAlreadyExistsException::class);

        $this->service->createUser(
            new CreateUserRequest('test@example.com', 'password123')
        );
    }
}
```

## Functional Test Example

```php
final class UserControllerTest extends WebTestCase
{
    private KernelBrowser $client;

    protected function setUp(): void
    {
        $this->client = static::createClient();
    }

    public function testCreateUser(): void
    {
        $this->client->request(
            method: 'POST',
            uri: '/api/users',
            server: ['CONTENT_TYPE' => 'application/json'],
            content: json_encode([
                'email' => 'test@example.com',
                'password' => 'password123',
            ]),
        );

        $this->assertResponseStatusCodeSame(Response::HTTP_CREATED);
        $this->assertResponseHeaderSame('content-type', 'application/json');

        $data = json_decode($this->client->getResponse()->getContent(), true);

        $this->assertArrayHasKey('id', $data);
        $this->assertSame('test@example.com', $data['email']);
    }

    public function testCreateUserValidationError(): void
    {
        $this->client->request(
            method: 'POST',
            uri: '/api/users',
            server: ['CONTENT_TYPE' => 'application/json'],
            content: json_encode([
                'email' => 'invalid-email',
                'password' => 'short',
            ]),
        );

        $this->assertResponseStatusCodeSame(Response::HTTP_BAD_REQUEST);
    }
}
```

## Testing Guidelines

- Test business logic thoroughly
- Mock external dependencies (APIs, email services)
- Use real database for integration tests (with fixtures)
- Test happy paths and error cases
- Use data providers for multiple scenarios
- Keep tests fast and isolated

## Test Naming

Use descriptive test names:

```php
// ✅ GOOD
public function testCreateUserThrowsExceptionWhenEmailAlreadyExists(): void
public function testGetUserReturnsNullWhenNotFound(): void

// ❌ BAD
public function testCreate(): void
public function test1(): void
```

## Assertions

Use specific assertions:

```php
// ✅ GOOD
$this->assertSame('expected', $actual);
$this->assertInstanceOf(UserDTO::class, $result);
$this->assertCount(3, $items);

// ❌ BAD
$this->assertTrue($result === 'expected');
$this->assertTrue($result instanceof UserDTO);
```

## Data Providers

Use data providers for multiple test cases:

```php
/**
 * @dataProvider invalidEmailProvider
 */
public function testValidationRejectsInvalidEmails(string $email): void
{
    // test logic
}

public static function invalidEmailProvider(): array
{
    return [
        'missing @' => ['invalid-email'],
        'missing domain' => ['test@'],
        'spaces' => ['test @example.com'],
        'empty' => [''],
    ];
}
```
