---
paths:
  - "src/**/*.tsx"
  - "src/**/*.jsx"
  - "src/**/*.ts"
  - "src/**/*.js"
---

# React Architecture

## Project Structure

```
src/
├── components/          # Reusable UI components
│   ├── ui/              # Base components (Button, Input, Modal)
│   └── features/        # Feature-specific components
├── hooks/               # Custom hooks
├── pages/               # Page/route components
├── services/            # API calls, external services
├── stores/              # State management (if using Zustand/Redux)
├── types/               # TypeScript types/interfaces
├── utils/               # Helper functions
└── constants/           # App constants, config
```

## Component Organization

### Colocation
Keep related files together:
```
components/UserProfile/
├── UserProfile.tsx      # Main component
├── UserProfile.test.tsx # Tests
├── UserProfile.styles.ts # Styled components / CSS modules
├── useUserProfile.ts    # Component-specific hook
└── index.ts             # Public export
```

### Barrel Exports
Use index.ts for clean imports:
```typescript
// components/index.ts
export { Button } from './Button';
export { Input } from './Input';

// Usage
import { Button, Input } from '@/components';
```

## Component Patterns

### Container/Presenter Pattern
Separate logic from presentation:
```typescript
// UserListContainer.tsx - handles data/logic
const UserListContainer = () => {
  const { users, isLoading } = useUsers();
  return <UserList users={users} isLoading={isLoading} />;
};

// UserList.tsx - pure presentation
const UserList = ({ users, isLoading }: UserListProps) => {
  if (isLoading) return <Spinner />;
  return <ul>{users.map(user => <UserItem key={user.id} user={user} />)}</ul>;
};
```

### Compound Components
For complex, related components:
```typescript
<Select>
  <Select.Trigger>Choose option</Select.Trigger>
  <Select.Content>
    <Select.Item value="1">Option 1</Select.Item>
    <Select.Item value="2">Option 2</Select.Item>
  </Select.Content>
</Select>
```

## Import Order

1. React and React-related
2. Third-party libraries
3. Internal aliases (@/components, @/hooks)
4. Relative imports
5. Types
6. Styles

```typescript
import { useState, useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';

import { Button } from '@/components';
import { useAuth } from '@/hooks';

import { UserAvatar } from './UserAvatar';

import type { User } from '@/types';

import styles from './Profile.module.css';
```
