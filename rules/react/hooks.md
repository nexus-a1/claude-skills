---
paths:
  - "src/**/*.tsx"
  - "src/**/*.jsx"
  - "src/**/*.ts"
  - "src/hooks/**/*"
---

# React Hooks

## Memoization Hooks

### useCallback
```typescript
// Memoize callback (when passing to optimized child components)
const handleClick = useCallback(() => {
  doSomething(id);
}, [id]);

// Don't overuse - only when needed for:
// 1. Passing to React.memo components
// 2. useEffect dependencies
// 3. Other hooks dependencies
```

### useMemo
```typescript
// Memoize expensive computations
const sortedItems = useMemo(
  () => [...items].sort((a, b) => a.name.localeCompare(b.name)),
  [items]
);

// Memoize object/array references
const config = useMemo(() => ({ theme, locale }), [theme, locale]);
```

## Custom Hooks

### Naming Convention
```typescript
// Always prefix with 'use'
const useLocalStorage = <T>(key: string, initialValue: T) => { ... };
const useDebounce = <T>(value: T, delay: number) => { ... };
const useMediaQuery = (query: string) => { ... };
```

### Return Patterns
```typescript
// Tuple (like useState)
const useToggle = (initial = false) => {
  const [value, setValue] = useState(initial);
  const toggle = useCallback(() => setValue(v => !v), []);
  return [value, toggle] as const;
};

// Object (for multiple values)
const useUser = (id: string) => {
  return { user, isLoading, error, refetch };
};
```

### Common Custom Hooks
```typescript
// useLocalStorage
const useLocalStorage = <T>(key: string, initialValue: T) => {
  const [value, setValue] = useState<T>(() => {
    const stored = localStorage.getItem(key);
    return stored ? JSON.parse(stored) : initialValue;
  });

  useEffect(() => {
    localStorage.setItem(key, JSON.stringify(value));
  }, [key, value]);

  return [value, setValue] as const;
};

// useDebounce
const useDebounce = <T>(value: T, delay: number): T => {
  const [debouncedValue, setDebouncedValue] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedValue(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);

  return debouncedValue;
};

// useOnClickOutside
const useOnClickOutside = (
  ref: RefObject<HTMLElement>,
  handler: () => void
) => {
  useEffect(() => {
    const listener = (event: MouseEvent) => {
      if (!ref.current?.contains(event.target as Node)) {
        handler();
      }
    };
    document.addEventListener('mousedown', listener);
    return () => document.removeEventListener('mousedown', listener);
  }, [ref, handler]);
};
```

## Data Fetching

### Prefer React Query / SWR
```typescript
// With React Query
const { data, isLoading, error } = useQuery({
  queryKey: ['user', userId],
  queryFn: () => fetchUser(userId),
});

// Mutations
const mutation = useMutation({
  mutationFn: updateUser,
  onSuccess: () => queryClient.invalidateQueries({ queryKey: ['user'] }),
});
```

### Manual Fetch (when libraries aren't available)
```typescript
const useUser = (id: string) => {
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    let cancelled = false;

    setIsLoading(true);
    fetchUser(id)
      .then(data => !cancelled && setUser(data))
      .catch(err => !cancelled && setError(err))
      .finally(() => !cancelled && setIsLoading(false));

    return () => { cancelled = true; };
  }, [id]);

  return { user, isLoading, error };
};
```
