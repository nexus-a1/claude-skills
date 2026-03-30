---
paths:
  - "src/**/*.test.tsx"
  - "src/**/*.test.ts"
  - "src/**/*.spec.tsx"
  - "src/**/*.spec.ts"
  - "**/__tests__/**/*"
---

# React Testing

## Testing Library Philosophy

- Test behavior, not implementation
- Query elements like users do (by role, label, text)
- Avoid testing internal state or props directly

## Test Structure

```typescript
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

describe('ComponentName', () => {
  it('should describe expected behavior', async () => {
    // Arrange
    const user = userEvent.setup();
    render(<Component prop="value" />);

    // Act
    await user.click(screen.getByRole('button', { name: /submit/i }));

    // Assert
    expect(screen.getByText('Success')).toBeInTheDocument();
  });
});
```

## Queries Priority

Use in this order (most to least preferred):

```typescript
// 1. Accessible to everyone
screen.getByRole('button', { name: /submit/i });
screen.getByLabelText('Email');
screen.getByPlaceholderText('Enter email');
screen.getByText('Welcome');

// 2. Semantic queries
screen.getByAltText('Profile photo');
screen.getByTitle('Close');

// 3. Test IDs (last resort)
screen.getByTestId('custom-element');
```

## Query Types

```typescript
// getBy - throws if not found (use for elements that should exist)
screen.getByRole('button');

// queryBy - returns null if not found (use for asserting absence)
expect(screen.queryByText('Error')).not.toBeInTheDocument();

// findBy - async, waits for element (use for elements that appear after async)
await screen.findByText('Loaded data');
```

## User Events

```typescript
import userEvent from '@testing-library/user-event';

it('handles user interactions', async () => {
  const user = userEvent.setup();

  // Click
  await user.click(screen.getByRole('button'));

  // Type
  await user.type(screen.getByLabelText('Email'), 'test@example.com');

  // Clear and type
  await user.clear(screen.getByLabelText('Email'));
  await user.type(screen.getByLabelText('Email'), 'new@example.com');

  // Select
  await user.selectOptions(screen.getByRole('combobox'), 'option1');

  // Keyboard
  await user.keyboard('{Enter}');
});
```

## Testing Async Behavior

```typescript
// waitFor - wait for assertion to pass
await waitFor(() => {
  expect(screen.getByText('Loaded')).toBeInTheDocument();
});

// findBy - built-in waiting
const element = await screen.findByText('Loaded');

// waitForElementToBeRemoved
await waitForElementToBeRemoved(() => screen.queryByText('Loading...'));
```

## Mocking

### Mock Functions
```typescript
const handleClick = vi.fn();
render(<Button onClick={handleClick}>Click</Button>);

await user.click(screen.getByRole('button'));
expect(handleClick).toHaveBeenCalledTimes(1);
```

### Mock API Calls (MSW)
```typescript
import { rest } from 'msw';
import { setupServer } from 'msw/node';

const server = setupServer(
  rest.get('/api/users', (req, res, ctx) => {
    return res(ctx.json([{ id: 1, name: 'John' }]));
  })
);

beforeAll(() => server.listen());
afterEach(() => server.resetHandlers());
afterAll(() => server.close());

it('loads users', async () => {
  render(<UserList />);
  expect(await screen.findByText('John')).toBeInTheDocument();
});

// Override for specific test
it('handles error', async () => {
  server.use(
    rest.get('/api/users', (req, res, ctx) => res(ctx.status(500)))
  );
  render(<UserList />);
  expect(await screen.findByText('Error loading users')).toBeInTheDocument();
});
```

### Mock Modules
```typescript
vi.mock('@/services/api', () => ({
  fetchUsers: vi.fn(() => Promise.resolve([{ id: 1, name: 'John' }])),
}));
```

## Testing with Providers

```typescript
const renderWithProviders = (ui: React.ReactElement) => {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <ThemeProvider>
        <AuthProvider>
          {ui}
        </AuthProvider>
      </ThemeProvider>
    </QueryClientProvider>
  );
};

it('renders with providers', () => {
  renderWithProviders(<Dashboard />);
});
```

## Testing Custom Hooks

```typescript
import { renderHook, act } from '@testing-library/react';

it('useCounter increments', () => {
  const { result } = renderHook(() => useCounter());

  expect(result.current.count).toBe(0);

  act(() => {
    result.current.increment();
  });

  expect(result.current.count).toBe(1);
});

// With wrapper for context
const { result } = renderHook(() => useAuth(), {
  wrapper: AuthProvider,
});
```

## What to Test

- User interactions
- Component rendering with different props
- Error states
- Loading states
- Conditional rendering
- Form validation and submission

## What NOT to Test

- Implementation details (internal state, private methods)
- Third-party libraries
- Styling (unless critical)
- Constants
