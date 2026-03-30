---
paths:
  - "src/**/*.tsx"
  - "src/**/*.ts"
---

# React TypeScript

## Component Props

```typescript
// Interface for props
interface ButtonProps {
  variant?: 'primary' | 'secondary';
  size?: 'sm' | 'md' | 'lg';
  disabled?: boolean;
  children: React.ReactNode;
  onClick?: () => void;
}

// Extend HTML element props
interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary';
}

// Omit specific HTML props
interface InputProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, 'size'> {
  size?: 'sm' | 'md' | 'lg';
}
```

## Children Types

```typescript
// Any renderable content
children: React.ReactNode;

// Single element only
children: React.ReactElement;

// String only
children: string;

// Function as children (render prop)
children: (data: T) => React.ReactNode;
```

## Event Handlers

```typescript
// Click event
onClick: (event: React.MouseEvent<HTMLButtonElement>) => void;

// Change event
onChange: (event: React.ChangeEvent<HTMLInputElement>) => void;

// Form submit
onSubmit: (event: React.FormEvent<HTMLFormElement>) => void;

// Keyboard event
onKeyDown: (event: React.KeyboardEvent<HTMLInputElement>) => void;

// Simplified (when you don't need the event)
onClick: () => void;
onChange: (value: string) => void;
```

## Hooks Types

```typescript
// useState with explicit type
const [user, setUser] = useState<User | null>(null);

// useRef for DOM elements
const inputRef = useRef<HTMLInputElement>(null);
const divRef = useRef<HTMLDivElement>(null);

// useRef for mutable values
const timerRef = useRef<number | null>(null);

// useReducer
type State = { count: number };
type Action = { type: 'increment' } | { type: 'decrement' } | { type: 'set'; payload: number };

const reducer = (state: State, action: Action): State => {
  switch (action.type) {
    case 'increment': return { count: state.count + 1 };
    case 'decrement': return { count: state.count - 1 };
    case 'set': return { count: action.payload };
  }
};

const [state, dispatch] = useReducer(reducer, { count: 0 });
```

## Context Types

```typescript
interface ThemeContextType {
  theme: 'light' | 'dark';
  setTheme: (theme: 'light' | 'dark') => void;
}

const ThemeContext = createContext<ThemeContextType | null>(null);

// Type-safe hook
const useTheme = (): ThemeContextType => {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error('useTheme must be used within ThemeProvider');
  }
  return context;
};
```

## Generic Components

```typescript
// Generic list component
interface ListProps<T> {
  items: T[];
  renderItem: (item: T) => React.ReactNode;
  keyExtractor: (item: T) => string;
}

const List = <T,>({ items, renderItem, keyExtractor }: ListProps<T>) => (
  <ul>
    {items.map(item => (
      <li key={keyExtractor(item)}>{renderItem(item)}</li>
    ))}
  </ul>
);

// Usage
<List
  items={users}
  renderItem={(user) => <span>{user.name}</span>}
  keyExtractor={(user) => user.id}
/>
```

## forwardRef Types

```typescript
interface InputProps extends React.InputHTMLAttributes<HTMLInputElement> {
  label: string;
}

const Input = forwardRef<HTMLInputElement, InputProps>(
  ({ label, ...props }, ref) => (
    <div>
      <label>{label}</label>
      <input ref={ref} {...props} />
    </div>
  )
);
```

## Utility Types

```typescript
// Partial - all props optional
type PartialUser = Partial<User>;

// Required - all props required
type RequiredUser = Required<User>;

// Pick - select specific props
type UserName = Pick<User, 'firstName' | 'lastName'>;

// Omit - exclude specific props
type UserWithoutId = Omit<User, 'id'>;

// Record - typed object
type UserMap = Record<string, User>;

// Extract component props
type ButtonProps = React.ComponentProps<typeof Button>;
type InputProps = React.ComponentPropsWithRef<'input'>;
```

## Type Guards

```typescript
// Type narrowing
const isUser = (value: unknown): value is User => {
  return typeof value === 'object' && value !== null && 'id' in value;
};

// Usage
if (isUser(data)) {
  console.log(data.id); // TypeScript knows data is User
}
```

## Avoid These

```typescript
// Avoid `any`
const handleChange = (e: any) => { ... }  // Bad
const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => { ... }  // Good

// Avoid type assertions when possible
const user = data as User;  // Avoid
const user = isUser(data) ? data : null;  // Better

// Don't use FC (it's been discouraged)
const Button: React.FC<Props> = ({ children }) => { ... }  // Avoid
const Button = ({ children }: Props) => { ... }  // Good
```
