---
paths:
  - "src/**/*.tsx"
  - "src/**/*.jsx"
  - "src/**/*.ts"
  - "src/hooks/**/*"
---

# React Hooks

## Rules of Hooks

1. Only call hooks at the top level (not in loops, conditions, or nested functions)
2. Only call hooks from React functions (components or custom hooks)
3. Custom hooks must start with `use`

## Built-in Hooks

### useState
```typescript
// Simple state
const [count, setCount] = useState(0);

// With TypeScript inference
const [user, setUser] = useState<User | null>(null);

// Lazy initialization (for expensive computations)
const [data, setData] = useState(() => computeExpensiveValue());

// Functional updates (when new state depends on previous)
setCount(prev => prev + 1);
```

### useEffect
```typescript
// Run on every render (rarely needed)
useEffect(() => { ... });

// Run once on mount
useEffect(() => { ... }, []);

// Run when dependencies change
useEffect(() => {
  fetchUser(userId);
}, [userId]);

// Cleanup function
useEffect(() => {
  const subscription = subscribe(id);
  return () => subscription.unsubscribe();
}, [id]);
```

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
  () => items.sort((a, b) => a.name.localeCompare(b.name)),
  [items]
);

// Memoize object/array references
const config = useMemo(() => ({ theme, locale }), [theme, locale]);
```

### useRef
```typescript
// DOM reference
const inputRef = useRef<HTMLInputElement>(null);
useEffect(() => inputRef.current?.focus(), []);

// Mutable value that persists across renders
const renderCount = useRef(0);
renderCount.current += 1;
```

### useContext
```typescript
// Create typed context
const ThemeContext = createContext<Theme | null>(null);

// Custom hook for safe context access
const useTheme = () => {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error('useTheme must be used within ThemeProvider');
  }
  return context;
};
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
  onSuccess: () => queryClient.invalidateQueries(['user']),
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
