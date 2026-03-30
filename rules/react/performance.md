---
paths:
  - "src/**/*.tsx"
  - "src/**/*.jsx"
---

# React Performance

## Avoid Unnecessary Re-renders

### React.memo
```typescript
// Memoize component - only re-renders when props change
const UserCard = memo(({ user }: { user: User }) => {
  return <div>{user.name}</div>;
});

// With custom comparison
const UserCard = memo(
  ({ user }: Props) => <div>{user.name}</div>,
  (prevProps, nextProps) => prevProps.user.id === nextProps.user.id
);
```

### Stable References
```typescript
// Bad - new object every render
<Child style={{ color: 'red' }} />

// Good - stable reference
const style = useMemo(() => ({ color: 'red' }), []);
<Child style={style} />

// Bad - new function every render
<Button onClick={() => handleClick(id)} />

// Good - stable callback
const handleButtonClick = useCallback(() => handleClick(id), [id]);
<Button onClick={handleButtonClick} />
```

### State Colocation
```typescript
// Bad - state too high, causes unnecessary re-renders
const Parent = () => {
  const [inputValue, setInputValue] = useState('');
  return (
    <>
      <Input value={inputValue} onChange={setInputValue} />
      <ExpensiveComponent /> {/* Re-renders on every keystroke */}
    </>
  );
};

// Good - state colocated with component that needs it
const Parent = () => (
  <>
    <SearchInput /> {/* Manages its own state */}
    <ExpensiveComponent />
  </>
);
```

## Code Splitting

### Lazy Loading Routes
```typescript
import { lazy, Suspense } from 'react';

const Dashboard = lazy(() => import('./pages/Dashboard'));
const Settings = lazy(() => import('./pages/Settings'));

const App = () => (
  <Suspense fallback={<Spinner />}>
    <Routes>
      <Route path="/dashboard" element={<Dashboard />} />
      <Route path="/settings" element={<Settings />} />
    </Routes>
  </Suspense>
);
```

### Lazy Loading Components
```typescript
const HeavyChart = lazy(() => import('./HeavyChart'));

const Dashboard = () => (
  <Suspense fallback={<ChartSkeleton />}>
    <HeavyChart data={data} />
  </Suspense>
);
```

## List Virtualization

For long lists (100+ items):
```typescript
import { useVirtualizer } from '@tanstack/react-virtual';

const VirtualList = ({ items }: { items: Item[] }) => {
  const parentRef = useRef<HTMLDivElement>(null);

  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 50,
  });

  return (
    <div ref={parentRef} style={{ height: 400, overflow: 'auto' }}>
      <div style={{ height: virtualizer.getTotalSize() }}>
        {virtualizer.getVirtualItems().map((virtualItem) => (
          <div
            key={virtualItem.key}
            style={{
              position: 'absolute',
              top: virtualItem.start,
              height: virtualItem.size,
            }}
          >
            <ItemRow item={items[virtualItem.index]} />
          </div>
        ))}
      </div>
    </div>
  );
};
```

## Expensive Computations

```typescript
// Memoize derived data
const sortedItems = useMemo(
  () => [...items].sort((a, b) => a.name.localeCompare(b.name)),
  [items]
);

// Memoize filtered data
const filteredUsers = useMemo(
  () => users.filter(user => user.name.includes(search)),
  [users, search]
);
```

## Debounce User Input

```typescript
const [search, setSearch] = useState('');
const debouncedSearch = useDebounce(search, 300);

// API call only fires when debouncedSearch changes
useEffect(() => {
  if (debouncedSearch) {
    fetchResults(debouncedSearch);
  }
}, [debouncedSearch]);
```

## Image Optimization

```typescript
// Lazy loading images
<img loading="lazy" src={imageSrc} alt="Description" />

// With placeholder
const [loaded, setLoaded] = useState(false);
<>
  {!loaded && <Skeleton />}
  <img
    src={imageSrc}
    onLoad={() => setLoaded(true)}
    style={{ display: loaded ? 'block' : 'none' }}
  />
</>

// Use next/image in Next.js
import Image from 'next/image';
<Image src={src} alt="Description" width={300} height={200} />
```

## Avoid These Patterns

```typescript
// Bad - spreading into dependency array
useEffect(() => { ... }, [...deps]);

// Bad - object/array in dependency (new reference each render)
useEffect(() => { ... }, [{ id, name }]);

// Bad - anonymous function in JSX for memo'd components
<MemoizedChild onClick={() => doSomething()} />

// Bad - inline object styles on every render
<div style={{ margin: 10 }} />
```
