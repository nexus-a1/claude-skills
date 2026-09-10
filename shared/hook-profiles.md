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
# Disable desktop notifications and the output-size nudge
NEXUS_DISABLED_HOOKS=notify,output-guard claude

# Disable token-filter rewriting (keep everything else)
NEXUS_DISABLED_HOOKS=bash-token-filter claude
```

---

## `NEXUS_AUDIT`

The one hook that is **off under every profile, including `full`**. Set
`NEXUS_AUDIT=1` to turn the audit trail on.

```bash
# This session records every tool call to ~/.claude/tool-audit.log
NEXUS_AUDIT=1 claude
```

`audit` matches `.*`, the broadest matcher in the set, so it runs after every
Read, Grep, Glob, Edit, Write, Task and Bash call — measured at ~44 ms each,
which is tens of seconds across a long session. It shipped on by default and
the trail went unread.

**Why it is disabled rather than deleted.** An audit trail's value is being
already on when something goes wrong; one enabled *after* an incident records
nothing about the incident. Off is one environment variable away from on, and
that is affordable because the disabled hook costs 3 ms, not 44: its check sits
above `hook_read_input`, so it exits before the payload is parsed. A gate placed
below that parse would look identical in behaviour and save nothing —
`tests/hooks/audit-opt-in.test` pins the position, not just the behaviour.

The profile switches above still apply on top once it is on: `off`, `minimal`,
and `NEXUS_DISABLED_HOOKS=audit` each silence it regardless of `NEXUS_AUDIT`.

---

## The token filter is the expensive part of `redact-output`

`redact-output` is the most costly hook in the set, and about half that cost is
not redaction — it is CPython starting up to run `bash-token-filter.py`, an
**advisory** convenience (injecting `-q`/`--silent`) that runs inside a **safety**
hook on every Bash call.

Before CL-111 its kill switch was checked only inside the Python, by which point
the interpreter had already started and imported its modules. The switch is now
checked in `redact-output.sh` *before* the spawn as well, so `off`, `minimal`,
and the by-name entry each actually skip it. Measured end to end, 25 runs per
cell on an idle machine:

| Setting | before | after |
|---|---|---|
| default | 139 ms | 133 ms |
| `NEXUS_DISABLED_HOOKS=bash-token-filter` | 133 ms | 69 ms |
| `NEXUS_HOOK_PROFILE=minimal` | 134 ms | 65 ms |

The default is unchanged by design. Disabling the filter recovers **~65-70 ms,
roughly half the hook**, where before it recovered nothing distinguishable from
noise.

The check inside `bash-token-filter.py` is deliberately kept. It is the authority
if the filter is ever invoked from anywhere else, and the two are asserted to
agree — including on whitespace in the list — by `tests/hooks/redact-output.test`.
Removing either as a duplicate reintroduces the cost or the gap.

**Redaction itself is never skipped by any of this.** Whatever disables the
token filter, the command still gets the redaction wrapper; that is asserted
too.

---

## Hook Catalogue

| Hook name | Class | `minimal` | `off` | Purpose |
|-----------|-------|:---------:|:-----:|---------|
| `git-mutation-guard` | **safety** | ✅ active | ❌ off | Branch protection, credential scan, push audit gate |
| `validate-commit` | **safety** | ✅ active | ❌ off | Enforce ticket-number pattern in commit messages |
| `redact-output` | **safety** | ✅ active | ❌ off | Rewrite every Bash command so its output streams through `redact-stream.sh`: secrets become stable `<REDACTED:kind:n>` placeholders before the model sees them |
| `read-guard` | **safety** | ✅ active | ❌ off | Refuse Read, Grep and Glob on files that exist to hold secrets (`.env*`, `*.pem`, `*credentials*`, the redaction map, …) — by path or by filename filter — and redirect to the Bash equivalent (`grep` for a Grep, `cat` otherwise), whose output is redacted |
| `reverse-substitute` | **safety** | ✅ active | ❌ off | On Write, Edit and MultiEdit: turn a `<REDACTED:kind:n>` placeholder the model wrote into the real value from the session map, so a file can carry a value the conversation never held. Refuses outside the repository and on sensitive paths unless the file already contains that value; logs every substitution without the value |
| `audit` | advisory | ❌ off | ❌ off | **Opt-in — off under `full` too.** `NEXUS_AUDIT=1` writes all tool usage to `~/.claude/tool-audit.log`. See [`NEXUS_AUDIT`](#nexus_audit) |
| `auto-context` | advisory | ❌ off | ❌ off | Auto-append entries to active work-session state.json |
| `bash-token-filter` | advisory | ❌ off | ❌ off | Inject `-q`/`--silent` flags to reduce noisy output. Runs *inside* `redact-output` (not registered on its own, so only one hook ever rewrites a command); this name still disables it, and since CL-111 disabling it **skips the `python3` spawn** rather than starting an interpreter that exits immediately — worth ~65-70 ms on every Bash call. See [the note below](#the-token-filter-is-the-expensive-part-of-redact-output) |
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

**Keeping the placeholders literal in files you write (no reverse substitution):**
```bash
NEXUS_DISABLED_HOOKS=reverse-substitute claude
```
Both hooks print a `WARN` line on every call while disabled. Prefer to keep them on
and paste the one value into the conversation yourself — that is one value, not
every value in every file the session reads.

---

## Structured PII (tier 2)

On top of secrets, `redact-output` redacts **structured personal data** — classes
with a shape a filter can match and, where the format defines one, a checksum
that turns a guess into a decision. Same placeholder scheme, same session map:
`carol@example.com` becomes `<REDACTED:email:1>` and stays that placeholder for
as long as the session stays in that repository — the map is keyed on the
repository, so every linked worktree of it shares one map and one numbering, and
a `cd` into a **different** repository starts a different sequence in which the
same number means something else.

| Class | Default | What it matches | What it deliberately does not |
|-------|:-------:|-----------------|-------------------------------|
| `email` | **on** | `local@domain.tld` | `git@…`, `noreply@…`, `no-reply@…` and `*.noreply.github.com` — service addresses, on every git remote and commit trailer, never a person's |
| `phone` | **on** | `+…` international numbers with 8–15 digits (E.164), and the dashed Polish `123-456-789` | a space-separated bare `123 456 789` — three space-separated three-digit columns are ordinary tabular output |
| `iban` | **on** | grouped or unseparated, **mod-97 checked** | anything that fails the check digits |
| `pesel` | **on** | 11 digits, **control digit and embedded date checked** | an 11-digit timestamp; a wrong control digit |
| `nip` | **on** | the dashed forms, or 10 bare digits **on a line that says NIP** | a bare 10-digit number with no label — that is a unix timestamp far more often than a tax id |
| `card` | **on** | 13–19 digits, plain or in 4-4-4-4 / 4-6-5 groups, **Luhn checked** | a UUID, a long id, a number that fails Luhn |
| `ip` | **off** | IPv4 with every octet in range | IPv6 (not covered at all), and it is off by default — see below |

**Why `ip` defaults off and the rest default on.** The test applied to each
class is: *does a working agent need the real value more often than not?* If
yes, it defaults off, because a redactor that breaks the task gets turned off
wholesale and a wholesale-off redactor protects nothing. Container addresses,
`127.0.0.1`, a `192.168.x` home lab, a `docker inspect`, a failing DNS lookup —
IP addresses are usually infrastructure rather than people, and they share their
shape with a four-part version string, which is the worst false-positive
neighbour in the set. Everything else on the list is data an agent essentially
never needs to read back. `email` is the one judgement call: it is the class most
likely to carry a real person's data in a repository, and the cost is that `git
log`, `git blame` and `gh` output show author addresses as placeholders — with
service addresses exempted so remotes and trailers still read normally.

Switch classes per project in `.claude/configuration.yml`:

```yaml
redaction:
  pii:
    ip: true       # a project that handles subscriber logs
    email: false   # a project where addresses are the task
```

…or per session, which beats the file:

```bash
NEXUS_REDACT_PII=none claude          # secrets only
NEXUS_REDACT_PII=all claude           # every class, ip included
NEXUS_REDACT_PII=email,card claude    # exactly these
```

An empty value counts as unset, not as `none` — a wrapper that blanks every
`NEXUS_*` variable must not be able to switch a redaction tier off by accident.
Turning it off takes the word.

---

## Writing a value back: `reverse-substitute`

Redaction alone makes one thing impossible: writing a file that has to carry the
real value. `reverse-substitute` closes that. The model writes
`<REDACTED:env-secret:2>` into a Write or an Edit, and the bytes that reach the
file are the value that placeholder stands for.

It is narrow on purpose, because this is the one place a bug writes a real
secret into the wrong file:

- Only exact tokens resolve. `<REDACTED:email:11>` is never entry 1.
- A placeholder with no map entry is written literally and reported in a
  `systemMessage`. Nothing is guessed.
- Only `content` and `new_string` are rewritten — never `file_path` (which would
  redirect the write) and never `old_string` (which the Edit tool echoes back
  into the conversation when it does not match, putting the value in the
  transcript on every near-miss).
- The target path is resolved physically, symlinks and `..` included. Outside
  the repository, or on a path the deny list marks sensitive, a value is written
  only if the file **already contains it** — restoring what is there leaks
  nothing; putting something new there is what the rule stops. Outside a git
  repository nothing is "inside", so only restoration happens.
- Every substitution and every refusal is appended to
  `.claude/session-state/redaction-audit.log` as timestamp, action, path, kind
  and number — never the value. The path is the resolved one; where it could
  not be resolved it is written `unresolved:<path>` rather than asserted. If
  the log cannot be written, the substitution does not happen.
- Values never reach a command line (`/proc/<pid>/cmdline` is world-readable)
  and are never written to a temporary file. They travel from the map through
  pipes and shell variables only.

Unlike the other safety hooks it **fails open**: with it inert the file receives
the literal placeholder text — wrong content, plainly visible, and no value
anywhere it should not be. Blocking every Write on a machine without `jq` would
cost the session and buy nothing.

---

## What this does not cover

Stated as a list, because every item on it has been mistaken for coverage at
least once.

- **Names, addresses and free-text personal data.** A filter matches shapes.
  "Call Anna Kowalska at the Kraków office" has no shape. This needs a model
  (NER — Presidio or similar), which is a different kind of dependency, and it
  is explicitly out of scope.
- **`@file` mentions and pasted text.** Both reach the model without passing
  through a rewritable tool input. There is no hook between them and the
  conversation.
- **MCP tool output.** `updatedMCPToolOutput` exists and nothing here uses it.
  If an MCP server in use returns customer data, that is a separate piece of
  work.
- **The command text itself.** A secret the model writes into a Bash command was
  already in its context; the hook filters what the command *prints*.
- **Grep over the whole repository.** `read-guard` is a check by NAME. A Grep
  that names no path, or a directory, still returns matching lines from files
  the deny list does not name — a secret in an innocently named file is caught
  by the content filters when it is `cat`ed, and not by this. ripgrep skips
  gitignored files, which covers `.env` in most projects and the redaction map
  always. This is the accepted residual.
- **IPv6, and a bare space-separated national phone number.** Not matched.
- **A secret split across two lines.** The filter is line-oriented.
- **A second hardlink to the same bytes, where `stat` cannot be run.** The
  containment check refuses a target whose link count is above one, because no
  amount of path resolution can see an in-repo name for a file that also lives
  outside the repository. Where neither `stat -c` nor `stat -f` answers, the
  count reads as 1 and that check is simply absent.
- **A path containing `..` on a machine with no `readlink -f`.** Folding `..`
  textually is wrong the moment a component is a symlink, so it is not folded:
  with `readlink -f` the kernel's answer is used, and without it such a path is
  declared suspect and treated as outside the repository. Conservative, and
  visible in the refusal.
- **Confirming a guess.** The refusal message distinguishes "the file does not
  already contain this value" from a silent success, so a caller that can Write
  can test candidate plaintexts against a readable file without ever seeing one.
  For the short classes (`ip`, a dashed phone number, a NIP) the candidate space
  is small. This is not a new capability where Bash is available; it is one
  where Write and Edit are the only tools granted.
- **The disk.** `reverse-substitute` lets a value the model can name a
  placeholder for be written into any ordinary file in the repository, and
  `base64` on a file does not go through a redactor the way `cat` does.
  Redaction protects the transcript. It is not a boundary against a model that
  is deliberately working around it, and it was never built to be one — the
  commit-time credential scan is the gate that stands between such a file and a
  push.

The session map (`.claude/session-state/redaction-map.tsv` in the **main
checkout** of the repository, or `~/.claude/session-state/` outside a repository)
holds the redacted values the filter can chase — secret-shaped ones —
in clear, so later output is redacted consistently. There is **one map per
repository**, not one per checkout: `git rev-parse --show-toplevel` answers with
a linked worktree's own path, so keying the map on it gave every worktree its own
independently numbered sequence, and `<REDACTED:env-secret:1>` then meant one
value in one worktree and a different one in the next — with the substitution
picking whichever map matched the current directory, and nothing in the
transcript showing the swap. The locator is `git rev-parse --git-common-dir`
(`plugin/shared/session-map-path.sh`), which every worktree of one repository
answers identically. The cost, accepted deliberately: one plaintext file now
holds every value the session saw in any of those worktrees. It is created mode 0600 with a
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
