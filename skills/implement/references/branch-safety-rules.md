# Branch Safety Rules

**CRITICAL**: These rules MUST be enforced at every stage.

## Before Implementation (Phase 0.2)
- MUST be on a `feature/*` branch
- NEVER implement on `release/*`, `main`, or `master` branches
- If feature branch doesn't exist, STOP and run `/create-requirements` first

## Before Committing (Phase 3)
- Verify still on `feature/*` branch
- Extract ticket from branch name for commit message
- Commit format: `[TICKET-123] type(scope): description`

## Before Pushing (Phase 5.1)
- NEVER push to `release/*` branches directly
- NEVER push to `main` or `master` directly
- All pushes go to `feature/*` branches only

## Branch Validation Command
```bash
current_branch=$(git branch --show-current)
if [[ "$current_branch" =~ ^(main|master)$ ]] || [[ "$current_branch" =~ ^release/ ]]; then
  echo "ERROR: Cannot work directly on protected branch: $current_branch"
  exit 1
fi
if [[ ! "$current_branch" =~ ^feature/ ]]; then
  echo "WARNING: Expected feature/* branch, got: $current_branch"
fi
```
