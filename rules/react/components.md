---
paths:
  - "src/**/*.tsx"
  - "src/**/*.jsx"
---

# React Components

## Component Definition

### Prefer Function Components
```typescript
// Good - Function component with TypeScript
interface ButtonProps {
  variant?: 'primary' | 'secondary';
  children: React.ReactNode;
  onClick?: () => void;
}

const Button = ({ variant = 'primary', children, onClick }: ButtonProps) => {
  return (
    <button className={styles[variant]} onClick={onClick}>
      {children}
    </button>
  );
};
```

### Export Pattern
```typescript
// Named export for components (enables better refactoring)
export const Button = ({ ... }: ButtonProps) => { ... };

// Default export only for pages/routes
export default function HomePage() { ... }
```

## Props

### Destructure Props
```typescript
// Good
const UserCard = ({ name, email, avatar }: UserCardProps) => { ... };

// Avoid
const UserCard = (props: UserCardProps) => {
  return <div>{props.name}</div>;
};
```

### Children Prop
```typescript
interface CardProps {
  children: React.ReactNode;  // For any renderable content
  title?: string;
}

// For render props
interface ListProps<T> {
  items: T[];
  renderItem: (item: T) => React.ReactNode;
}
```

### Event Handler Props
```typescript
interface ButtonProps {
  onClick?: () => void;                    // Simple handler
  onSubmit?: (data: FormData) => void;     // With data
  onChange?: (value: string) => void;      // Controlled input
}
```

### Spread Props for HTML Elements
```typescript
interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary';
}

const Button = ({ variant, children, ...props }: ButtonProps) => (
  <button className={styles[variant]} {...props}>
    {children}
  </button>
);
```

## Composition

### Prefer Composition Over Prop Drilling
```typescript
// Bad - Prop drilling
<Layout user={user}>
  <Sidebar user={user}>
    <UserMenu user={user} />
  </Sidebar>
</Layout>

// Good - Composition
<Layout>
  <Sidebar>
    <UserMenu user={user} />
  </Sidebar>
</Layout>
```

### Slots Pattern
```typescript
interface PageLayoutProps {
  header: React.ReactNode;
  sidebar?: React.ReactNode;
  children: React.ReactNode;
}

const PageLayout = ({ header, sidebar, children }: PageLayoutProps) => (
  <div className="layout">
    <header>{header}</header>
    {sidebar && <aside>{sidebar}</aside>}
    <main>{children}</main>
  </div>
);

// Usage
<PageLayout
  header={<NavBar />}
  sidebar={<FilterPanel />}
>
  <ProductList />
</PageLayout>
```

## Conditional Rendering

```typescript
// Simple condition
{isLoggedIn && <UserMenu />}

// If/else
{isLoggedIn ? <UserMenu /> : <LoginButton />}

// Multiple conditions - extract to variable or component
const content = (() => {
  if (isLoading) return <Spinner />;
  if (error) return <ErrorMessage error={error} />;
  if (!data) return <EmptyState />;
  return <DataView data={data} />;
})();

return <div>{content}</div>;
```

## Lists

```typescript
// Always use stable keys (never index for dynamic lists)
{users.map(user => (
  <UserCard key={user.id} user={user} />
))}

// Index is OK only for static lists that never reorder
{menuItems.map((item, index) => (
  <MenuItem key={index} {...item} />
))}
```

## Refs

```typescript
// DOM element ref
const inputRef = useRef<HTMLInputElement>(null);

// Mutable value ref (doesn't trigger re-render)
const timerRef = useRef<number | null>(null);

// Forward ref for reusable components
const Input = forwardRef<HTMLInputElement, InputProps>((props, ref) => (
  <input ref={ref} {...props} />
));
```
