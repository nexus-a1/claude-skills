# Sanctioned KB-Write Pattern

Canonical procedure for committing and pushing to a **git-backed knowledge-base
repo** (requirements archive, product-knowledge, or any artifact whose
`storage.locations.*.type` is `git`). Referenced by `archive-requirements`,
`rebuild-requirements-index`, `rebuild-index`, `add-product-knowledge`, and the
`archivist` / `product-expert` agents. This file is the single source of truth —
if the mechanics change, change them here.

## Why a special pattern

KB repos are **separate git remotes with no PR/review process of their own**. A
direct push to their default branch (`master`/`main`) is the intended workflow,
not a bypass of *this* project's review requirement. But `git-mutation-guard.sh`
(the PreToolUse hook) can't tell "this is a KB repo" from "this is the project
repo" — it only sees a `git push` to a protected-branch name. The pattern below
tells the guard, explicitly and audibly, that this is a sanctioned KB write.

## The three hard rules

**1. `cd` into the KB repo — never `git -C`.**
The guard resolves `git rev-parse --show-toplevel` and runs the credential scan
against the repo it is standing in. `git -C <path> commit` keeps the guard
pointed at the *calling project* while the mutation lands in the KB repo, and —
worse — the guard's mutation regexes are anchored to `git <subcommand>`, so a
`git -C …` invocation matches neither the commit nor the push rule and **every
check is silently skipped**. Always `cd`.

**2. `git commit` must lead its own Bash tool call.**
The guard's credential scan fires only when the command *starts with*
`git commit` (its regex is anchored: `^\s*git\s+commit`). A compound
`cd "$KB" && git commit …` begins with `cd`, so the scan is silently skipped —
the exact hazard that lets a secret slip into a KB repo. So: do the `cd` (and
`git add`) in one Bash call, then run `git commit` as the very next Bash call,
leading the command. The working directory persists across Bash tool calls, so
the `cd` still applies. (The push must lead its own call too — see rule 3.)

**3. The push must LEAD its own Bash call, prefixed with
`NEXUS_KB_WRITE=1 SECURITY_AUDITOR_BYPASS=1`, resolving the branch inline.**
The guard's push block is anchored to the *start* of the command
(`^\s*git\s+push`, after the env-strip loop removes a leading `NEXUS_KB_WRITE=`
/ `SECURITY_AUDITOR_BYPASS=` token). If anything else leads the call — e.g.
`default_branch=$(…)` on the line before `git push` — the regex never matches
and the **entire push block is skipped via a regex miss, not via the env
bypasses**: no WARN prints, and the ⚠️ tripwire below is void (an accidental run
against the project repo would push to a protected branch with zero
enforcement). So the push, like the commit, must be the first thing in its Bash
call. Because shell variables do not survive across Bash calls, resolve the
branch **inline** in the push argument, on ONE physical line:
```bash
NEXUS_KB_WRITE=1 SECURITY_AUDITOR_BYPASS=1 git push origin -- "$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' | grep . || timeout 10 git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2);print $2;exit}' | grep . || echo master)"
```
Keep it on one line — a `\`-continuation puts a newline in the command string,
which defeats the guard's single-line-anchored regex just like a leading
assignment does.
- `NEXUS_KB_WRITE=1` skips *only* branch protection (without it the guard blocks
  the push — `master`/`main` is a protected-branch name); `SECURITY_AUDITOR_BYPASS=1`
  skips *only* the audit gate. Both are **logged to stderr** — that WARN is the
  tripwire. The credential scan already ran on the commit call. Do **not**
  substitute a mechanical `record-audit.sh`, which would rubber-stamp an audit
  that never happened.
- `timeout 10` bounds the remote query so a slow/unreachable KB remote can't
  hang the push step (matches `lib.sh:_default_branch`).

> ⚠️ **Never run the combined `NEXUS_KB_WRITE=1 SECURITY_AUDITOR_BYPASS=1`
> prefix from inside the project's own repo.** Together they disable *both*
> branch protection and the audit gate — the guard cannot tell a KB remote from
> this project, so the combo run against the project repo would push straight to
> its protected `master`. It is sanctioned **only** after rule #1's `cd` has put
> you inside a separate git-backed KB repo. The stderr WARN lines are your
> tripwire that both gates were dropped — if you see them while standing in the
> project repo, stop.

## Resolving the default branch

Never hardcode `master` — a KB repo may default to `main`. Resolve it, and query
the remote if the local symref is missing (fresh clones and CI checkouts often
leave `origin/HEAD` unpopulated):

```bash
default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
[ -z "$default_branch" ] && default_branch=$(timeout 10 git ls-remote --symref origin HEAD 2>/dev/null \
  | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
default_branch="${default_branch:-master}"
```

## Canonical sequence

Three separate Bash tool calls (shown together for readability — do **not**
paste them into one call). Both the commit (Call 2) and the push (Call 3) must
*lead* their respective calls so the guard engages; Call 3's branch resolution
is inline in the push argument because shell variables do not cross call
boundaries.

```bash
# Call 1 — enter the KB repo and stage. (Neither cd nor git add is guarded.)
cd "$KB_PATH"
git add <the KB files you wrote>          # e.g. "$identifier/" index.json
```

```bash
# Call 2 — commit. Must LEAD the call so the guard's credential scan runs.
git commit -m "<message>"
git pull --rebase                          # optional: sync before push (uses upstream tracking)
```

```bash
# Call 3 — push must LEAD, on ONE line, so the guard engages and logs the bypass WARNs.
NEXUS_KB_WRITE=1 SECURITY_AUDITOR_BYPASS=1 git push origin -- "$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' | grep . || timeout 10 git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2);print $2;exit}' | grep . || echo master)"
```
