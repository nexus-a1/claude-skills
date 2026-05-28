---
description: Hook runtime profiles and per-hook kill-switch reference
---

# Hook Runtime Profiles

Two environment variables let you tune or disable Claude Code hooks without
editing any files. Set them in your shell, a `.env` file, or any wrapper
script before launching Claude Code.

---

## `NEXUS_HOOK_PROFILE`

Named preset that controls which hooks run.

| Value | Effect |
|-------|--------|
| `full` (default) | All hooks active. Normal operation. |
| `minimal` | Advisory hooks disabled; safety hooks remain active. |
| `off` | **All** hooks disabled, including safety hooks. Nuclear option. |

```bash
# Disable advisory hooks only (keep git guards active)
NEXUS_HOOK_PROFILE=minimal claude

# Disable every hook (debugging, CI environments where hooks cause issues)
NEXUS_HOOK_PROFILE=off claude
```

---

## `NEXUS_DISABLED_HOOKS`

Comma-separated list of individual hook names to disable. Overrides
`NEXUS_HOOK_PROFILE` per hook — a hook named here exits immediately
regardless of the profile setting.

```bash
# Disable desktop notifications and the audit trail
NEXUS_DISABLED_HOOKS=notify,audit claude

# Disable token-filter rewriting (keep everything else)
NEXUS_DISABLED_HOOKS=bash-token-filter claude
```

---

## Hook Catalogue

| Hook name | Class | `minimal` | `off` | Purpose |
|-----------|-------|:---------:|:-----:|---------|
| `git-mutation-guard` | **safety** | ✅ active | ❌ off | Branch protection, credential scan, push audit gate |
| `validate-commit` | **safety** | ✅ active | ❌ off | Enforce ticket-number pattern in commit messages |
| `audit` | advisory | ❌ off | ❌ off | Write all tool usage to `~/.claude/tool-audit.log` |
| `auto-context` | advisory | ❌ off | ❌ off | Auto-append entries to active work-session state.json |
| `bash-token-filter` | advisory | ❌ off | ❌ off | Inject `-q`/`--silent` flags to reduce noisy output |
| `notify` | advisory | ❌ off | ❌ off | Send desktop notification on session end |
| `output-guard` | advisory | ❌ off | ❌ off | Advisory nudge when Bash output exceeds thresholds |

**Safety hooks** are enforced in `minimal` mode because they protect against
silent data leaks and accidental pushes to protected branches. Disabling them
requires the explicit `off` profile or naming them in `NEXUS_DISABLED_HOOKS`.

---

## Common Scenarios

**Debugging hook interference in a CI environment:**
```bash
NEXUS_HOOK_PROFILE=off claude --print "run the tests"
```

**Reducing noise during a focused coding session (keep safety, drop advisories):**
```bash
NEXUS_HOOK_PROFILE=minimal claude
```

**Temporarily silencing desktop notifications without touching anything else:**
```bash
NEXUS_DISABLED_HOOKS=notify claude
```

**Bypassing token-filter command rewriting (e.g., you need verbose `npm install` output):**
```bash
NEXUS_DISABLED_HOOKS=bash-token-filter claude
```

---

## Safety Notes

- `NEXUS_HOOK_PROFILE=off` disables `git-mutation-guard`, removing branch
  protection, credential scanning, and the push audit gate. Use only when
  you understand the risks, and prefer `minimal` or `NEXUS_DISABLED_HOOKS`
  for targeted suppression.
- Disabling `validate-commit` means commit messages will no longer be
  validated for ticket numbers. CI may still enforce this separately.
- Hook state is process-scoped — environment variables do not persist
  between Claude Code sessions unless you add them to your shell profile.
