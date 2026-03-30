---
paths:
  - "**/*.php"
---

# Database & Doctrine Guidelines

## Repository Pattern

Repositories handle data access:

```php
/**
 * @extends ServiceEntityRepository<User>
 */
final class UserRepository extends ServiceEntityRepository
{
    public function __construct(ManagerRegistry $registry)
    {
        parent::__construct($registry, User::class);
    }

    public function save(User $user): void
    {
        $this->getEntityManager()->persist($user);
        $this->getEntityManager()->flush();
    }

    public function remove(User $user): void
    {
        $this->getEntityManager()->remove($user);
        $this->getEntityManager()->flush();
    }

    public function findByEmail(string $email): ?User
    {
        return $this->findOneBy(['email' => $email]);
    }

    public function existsByEmail(string $email): bool
    {
        return $this->count(['email' => $email]) > 0;
    }

    /**
     * @return User[]
     */
    public function findActiveUsers(): array
    {
        return $this->createQueryBuilder('u')
            ->where('u.status = :status')
            ->setParameter('status', UserStatus::ACTIVE)
            ->orderBy('u.createdAt', 'DESC')
            ->getQuery()
            ->getResult();
    }
}
```

## Migrations

Always use migrations for schema changes:

```bash
php bin/console make:migration
php bin/console doctrine:migrations:migrate
```

**Never** use `doctrine:schema:update` in production.

## Avoid N+1 Queries

Use joins or fetch joins:

```php
// ✅ GOOD
public function findUsersWithOrders(): array
{
    return $this->createQueryBuilder('u')
        ->leftJoin('u.orders', 'o')
        ->addSelect('o')
        ->getQuery()
        ->getResult();
}

// ❌ BAD - Will trigger N+1
public function findUsersWithOrders(): array
{
    return $this->findAll(); // Then accessing $user->getOrders() in loop
}
```

## Entity Relationships

Be explicit with relationship mappings:

```php
#[ORM\Entity]
class Order
{
    #[ORM\ManyToOne(targetEntity: User::class, inversedBy: 'orders')]
    #[ORM\JoinColumn(nullable: false, onDelete: 'CASCADE')]
    private User $user;

    #[ORM\OneToMany(
        targetEntity: OrderItem::class,
        mappedBy: 'order',
        cascade: ['persist', 'remove'],
        orphanRemoval: true
    )]
    private Collection $items;

    public function __construct()
    {
        $this->items = new ArrayCollection();
    }
}
```

## Database Transactions

Use transactions for multiple operations:

```php
final readonly class OrderService
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private OrderRepository $orderRepository,
    ) {
    }

    public function createOrderWithItems(CreateOrderRequest $request): OrderDTO
    {
        return $this->entityManager->wrapInTransaction(function () use ($request) {
            $order = new Order();
            // ... create order

            foreach ($request->items as $itemData) {
                $item = new OrderItem();
                // ... create item
                $order->addItem($item);
            }

            $this->orderRepository->save($order);

            return OrderDTO::fromEntity($order);
        });
    }
}
```

## Parameterized Queries

Always use parameterized queries:

```php
// ✅ GOOD
$qb->where('u.email = :email')
    ->setParameter('email', $email);

// ❌ BAD - SQL injection risk
$qb->where("u.email = '$email'");
```

## Lazy Loading

Be cautious with lazy loading - prefer explicit fetching:

```php
// ✅ GOOD - Explicit join
$users = $this->repository->createQueryBuilder('u')
    ->leftJoin('u.profile', 'p')
    ->addSelect('p')
    ->getQuery()
    ->getResult();

// ⚠️ CAREFUL - Lazy loading may cause N+1
$users = $this->repository->findAll();
foreach ($users as $user) {
    echo $user->getProfile()->getName(); // Additional query
}
```

## Raw SQL

Avoid raw SQL unless necessary:

```php
// ✅ GOOD
$users = $userRepository->findBy(['email' => $email]);

// ✅ OK for complex queries with parameters
$sql = "SELECT u.*, COUNT(o.id) as order_count
        FROM users u
        LEFT JOIN orders o ON u.id = o.user_id
        WHERE u.status = :status
        GROUP BY u.id";
$result = $connection->executeQuery($sql, ['status' => 'active']);

// ❌ BAD - SQL injection
$sql = "SELECT * FROM users WHERE email = '$email'";
```
