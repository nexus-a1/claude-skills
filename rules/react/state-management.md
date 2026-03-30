---
paths:
  - "src/**/*.tsx"
  - "src/**/*.jsx"
  - "src/**/*.ts"
  - "src/stores/**/*"
---

# React State Management

## State Location Decision

```
Local State (useState)
  ↓ Need to share with siblings?
Context (useContext)
  ↓ Complex state logic? Global app state?
External Store (Zustand, Redux, Jotai)
```

## Local State (useState)

Use for:
- UI state (open/closed, selected, hover)
- Form inputs
- Component-specific data

```typescript
const [isOpen, setIsOpen] = useState(false);
const [selectedId, setSelectedId] = useState<string | null>(null);
```

## Lifting State Up

When siblings need to share state:
```typescript
// Parent owns the state
const Parent = () => {
  const [selected, setSelected] = useState<string | null>(null);

  return (
    <>
      <List items={items} selected={selected} onSelect={setSelected} />
      <Details itemId={selected} />
    </>
  );
};
```

## Context API

### When to Use
- Theme, locale, auth user
- Data needed by many components at different nesting levels
- Avoiding prop drilling (3+ levels)

### Pattern
```typescript
// 1. Create context with type
interface AuthContextType {
  user: User | null;
  login: (credentials: Credentials) => Promise<void>;
  logout: () => void;
}

const AuthContext = createContext<AuthContextType | null>(null);

// 2. Create provider
export const AuthProvider = ({ children }: { children: React.ReactNode }) => {
  const [user, setUser] = useState<User | null>(null);

  const login = async (credentials: Credentials) => {
    const user = await authService.login(credentials);
    setUser(user);
  };

  const logout = () => {
    authService.logout();
    setUser(null);
  };

  return (
    <AuthContext.Provider value={{ user, login, logout }}>
      {children}
    </AuthContext.Provider>
  );
};

// 3. Create custom hook
export const useAuth = () => {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within AuthProvider');
  }
  return context;
};
```

### Avoid Context Pitfalls
```typescript
// Bad - Object created every render, all consumers re-render
<ThemeContext.Provider value={{ theme, setTheme }}>

// Good - Memoize the value
const value = useMemo(() => ({ theme, setTheme }), [theme]);
<ThemeContext.Provider value={value}>
```

## Zustand (Recommended for Global State)

```typescript
import { create } from 'zustand';

interface CartStore {
  items: CartItem[];
  addItem: (item: Product) => void;
  removeItem: (id: string) => void;
  clearCart: () => void;
  total: () => number;
}

export const useCartStore = create<CartStore>((set, get) => ({
  items: [],

  addItem: (product) => set((state) => ({
    items: [...state.items, { ...product, quantity: 1 }]
  })),

  removeItem: (id) => set((state) => ({
    items: state.items.filter(item => item.id !== id)
  })),

  clearCart: () => set({ items: [] }),

  total: () => get().items.reduce((sum, item) => sum + item.price * item.quantity, 0),
}));

// Usage - only subscribes to selected state
const items = useCartStore((state) => state.items);
const addItem = useCartStore((state) => state.addItem);
```

### Zustand with Persistence
```typescript
import { persist } from 'zustand/middleware';

export const useCartStore = create<CartStore>()(
  persist(
    (set, get) => ({
      // ... store definition
    }),
    { name: 'cart-storage' }
  )
);
```

## Server State (React Query)

For data from APIs - separate from UI state:

```typescript
// Queries (GET)
const { data: users, isLoading } = useQuery({
  queryKey: ['users', filters],
  queryFn: () => api.getUsers(filters),
  staleTime: 5 * 60 * 1000, // 5 minutes
});

// Mutations (POST/PUT/DELETE)
const mutation = useMutation({
  mutationFn: api.createUser,
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ['users'] });
    toast.success('User created');
  },
  onError: (error) => {
    toast.error(error.message);
  },
});

// Optimistic updates
const mutation = useMutation({
  mutationFn: api.updateUser,
  onMutate: async (newUser) => {
    await queryClient.cancelQueries({ queryKey: ['user', newUser.id] });
    const previous = queryClient.getQueryData(['user', newUser.id]);
    queryClient.setQueryData(['user', newUser.id], newUser);
    return { previous };
  },
  onError: (err, newUser, context) => {
    queryClient.setQueryData(['user', newUser.id], context?.previous);
  },
});
```

## Form State

### Controlled Components
```typescript
const [email, setEmail] = useState('');
<input value={email} onChange={(e) => setEmail(e.target.value)} />
```

### React Hook Form (Recommended)
```typescript
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';

const schema = z.object({
  email: z.string().email(),
  password: z.string().min(8),
});

const LoginForm = () => {
  const { register, handleSubmit, formState: { errors } } = useForm({
    resolver: zodResolver(schema),
  });

  const onSubmit = (data: z.infer<typeof schema>) => {
    // Handle submit
  };

  return (
    <form onSubmit={handleSubmit(onSubmit)}>
      <input {...register('email')} />
      {errors.email && <span>{errors.email.message}</span>}
    </form>
  );
};
```
