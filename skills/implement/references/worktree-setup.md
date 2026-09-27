# Worktree Setup (Phase 0.2b)

Read this file only when the `WORKTREE_ENABLED` printed in Phase 0.2b is `true`.

## Single mode (`WORKSPACE_MODE == "single"`)

1. Call `EnterWorktree` with name `"impl-{identifier}"`.
   - CWD moves to `.claude/worktrees/impl-{identifier}/`.
   - A temporary branch is created from HEAD.
2. After entering, checkout the feature branch (see Phase 0.2b main flow).
3. `$WORK_DIR` still resolves correctly (anchored to `WORKSPACE_ROOT`).

## Multi mode (`WORKSPACE_MODE == "multi"`)

Create per-service worktrees:

```bash
# Its own Bash call, so the library is sourced again: without it the resolve_*
# calls are undefined, WT_ROOT is empty and the mkdir lands at /.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
  exit 1
fi
WT_ROOT=$(resolve_worktree_root)
[ -n "$WT_ROOT" ] || { echo "ERROR: no worktree root resolved" >&2; exit 1; }
TICKET_WORKSPACE="${WT_ROOT}/{identifier}"
mkdir -p "$TICKET_WORKSPACE"

for svc in $(resolve_services); do
  svc_path=$(resolve_service_path "$svc")
  # A rejected service NAME returns 1 with EMPTY stdout (a rejected PATH is
  # different: it falls back to the name-is-the-directory convention). `git -C ""`
  # is a documented no-op that runs in the CURRENT repo, so an unguarded empty
  # value here creates the worktree in whatever repository the session is in.
  [ -n "$svc_path" ] || { echo "skipping $svc: no usable path" >&2; continue; }
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
