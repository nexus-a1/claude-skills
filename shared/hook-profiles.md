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
| `redact-output` | **safety** | ✅ active | ❌ off | Rewrite every Bash command so its output streams through `redact-stream.sh`: secrets become stable `<REDACTED:kind:n>` placeholders before the model sees them |
| `read-guard` | **safety** | ✅ active | ❌ off | Refuse Read, Grep and Glob on files that exist to hold secrets (`.env*`, `*.pem`, `*credentials*`, the redaction map, …) — by path or by filename filter — and redirect to `cat`, whose output is redacted |
| `audit` | advisory | ❌ off | ❌ off | Write all tool usage to `~/.claude/tool-audit.log` |
| `auto-context` | advisory | ❌ off | ❌ off | Auto-append entries to active work-session state.json |
| `bash-token-filter` | advisory | ❌ off | ❌ off | Inject `-q`/`--silent` flags to reduce noisy output. Runs *inside* `redact-output` (not registered on its own, so only one hook ever rewrites a command); this name still disables it |
| `notify` | advisory | ❌ off | ❌ off | Send desktop notification on session end |
| `output-guard` | advisory | ❌ off | ❌ off | Advisory nudge when Bash output exceeds thresholds |

> **How a hook receives the tool call.** Claude Code passes it as JSON on
> **stdin**. A hook here depends only on `CLAUDE_PROJECT_DIR`,
> `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` and `CLAUDE_EFFORT` — other
> `CLAUDE_*` variables may be present in the environment, but relying on one is
> how the defect below happened. What matters is that **`CLAUDE_TOOL_INPUT` and
> `CLAUDE_TOOL_NAME` are never provided**: there is no variable carrying the
> command or the tool. `git-mutation-guard` and `validate-commit`
> read one that does not exist, so both saw an empty command and
> enforced nothing in every real installation — while their tests passed,
> because the tests set that variable themselves. `plugin/hooks/hook-input.sh`
> is the shared reader; `bash-token-filter.py` is the reference implementation.
> A safety hook that cannot read its payload now **blocks**; an advisory hook
> degrades and says so.
>
> Two consequences worth knowing before you meet them. **`jq` is required**: on
> a machine without it, a Bash call whose payload looks like a git command is
> refused rather than waved through, because a guard that cannot read its input
> must not approve it. Install `jq`, or disable the hook explicitly with
> `NEXUS_DISABLED_HOOKS=git-mutation-guard` — unrelated commands are unaffected.
>
> And **`validate-commit` cannot check every commit**. `git commit -F <file>`,
> `--amend`, an interactive editor, and `-m "$(…)"` all produce their message
> somewhere the hook cannot see, so those pass unchecked and the last of them
> says so with a WARN. The check covers `-m`, `-am`, `--message` and the
> quoted-heredoc form; it is not a guarantee that every commit carries a ticket.

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

**Reading a secret value on purpose (the model must see it, not a placeholder):**
```bash
NEXUS_DISABLED_HOOKS=redact-output,read-guard claude
```
Both hooks print a `WARN` line on every call while disabled. Prefer to keep them on
and paste the one value into the conversation yourself — that is one value, not
every value in every file the session reads.

**What redaction does and does not cover.** `redact-output` filters what a Bash
command *prints*; `read-guard` refuses Read, Grep and Glob on files *named* to hold
secrets. Neither can touch `@file` mentions, pasted text, MCP tool output, or a
secret the model itself wrote into a command — those reach the model without
passing through a rewritable input. A Grep that names no path (or a directory)
returns matching lines from every file under it unhooked; ripgrep skips
gitignored files, which covers `.env` in most projects and the redaction map
always, but a sensitive file that is not gitignored is reachable that way.
Names and other free-text personal data are not redacted; that needs a model, not
a filter.

The session map (`.claude/session-state/redaction-map.tsv`, or
`~/.claude/session-state/` outside a repository) holds the redacted values the filter can chase — secret-shaped ones —
in clear, so later output is redacted consistently. It is created mode 0600 with a
`.gitignore` of `*` beside it, `read-guard` refuses it (Read, Grep and Glob alike),
and `cat` on it, or any reformatting of it, comes back as placeholders. Both hooks need `jq`; without it they
**block** (exit 2) and name the `NEXUS_DISABLED_HOOKS` opt-out, rather than run silently
unredacted — the same choice as a missing filter.

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
