# Worktree Setup (Phase 0.2b)

Read this file only when `resolve_worktree_enabled` returns `"true"`.

## Single mode (`WORKSPACE_MODE == "single"`)

1. Call `EnterWorktree` with name `"impl-{identifier}"`.
   - CWD moves to `.claude/worktrees/impl-{identifier}/`.
   - A temporary branch is created from HEAD.
2. After entering, checkout the feature branch (see Phase 0.2b main flow).
3. `$WORK_DIR` still resolves correctly (anchored to `WORKSPACE_ROOT`).

## Multi mode (`WORKSPACE_MODE == "multi"`)

Create per-service worktrees:

```bash
WT_ROOT=$(resolve_worktree_root)
TICKET_WORKSPACE="${WT_ROOT}/{identifier}"
mkdir -p "$TICKET_WORKSPACE"

for svc in $(resolve_services); do
  svc_path=$(resolve_service_path "$svc")
  wt_path="${TICKET_WORKSPACE}/${svc}"

  if [[ -d "$wt_path" ]]; then
    echo "Worktree exists: ${svc}/ → ${wt_path}"
    continue
  fi

  # Create worktree with feature branch (create branch or checkout existing)
  git -C "$svc_path" worktree add "$wt_path" -b "feature/{identifier}" 2>/dev/null \
    || git -C "$svc_path" worktree add "$wt_path" "feature/{identifier}"

  echo "Created worktree: ${svc}/ → ${wt_path}"
done
```

All subsequent agent prompts MUST use `$TICKET_WORKSPACE/{service}/` paths instead of the original service paths.

## Track worktree state (both modes)

Add to `state.json`:

```json
{
  "worktree": {
    "enabled": true,
    "mode": "single|multi",
    "name": "impl-{identifier}",
    "workspace": "/absolute/path/.worktrees/{identifier}",
    "services": {
      "service1": "/absolute/path/.worktrees/{identifier}/service1",
      "service2": "/absolute/path/.worktrees/{identifier}/service2"
    }
  }
}
```

After worktree setup, control returns to the main SKILL.md flow for the shared branch-checkout and feature-branch validation steps.
