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

Four separate Bash tool calls (shown together for readability — do **not**
paste them into one call). Call 0 exists because the three that follow all
name the KB path and none of them can read it from a variable: it is printed
once and substituted as `<KB_PATH printed above>` thereafter. Both the commit (Call 2) and the push (Call 3) must
*lead* their respective calls so the guard engages; Call 3's branch resolution
is inline in the push argument because shell variables do not cross call
boundaries.

```bash
# Call 0 — resolve the KB path and PRINT it. Everything below substitutes that
# printed value rather than reading a variable, because no variable set here
# survives to the next call. A caller that already printed KB_PATH skips this.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found — reinstall the nexus plugin: /plugin install nexus@claude-skills" >&2
  exit 1
fi
# resolve_artifact_STRICT, not the advisory resolver: this pattern WRITES to a
# shared knowledge base, and the advisory one fabricates a path when the KB is
# not configured — which is how a write lands somewhere nobody asked for. It
# refuses instead, returning non-zero with nothing on stdout. See
# docs/decisions/014-artifact-resolution-strictness.md.
if _RESOLVED=$(resolve_artifact_strict requirements requirements); then
  IFS='|' read -r KB_PATH _TYPE <<< "$_RESOLVED"
else
  echo "ERROR: the requirements KB is not configured — there is nothing to write to" >&2
  exit 1
fi
echo "KB_PATH=$KB_PATH"
```

```bash
# Call 1 — enter the KB repo and stage. (Neither cd nor git add is a guarded
# mutation verb, so they share this call; the commit and push must not.)
[ -n "<KB_PATH printed above>" ] || exit 1
cd "<KB_PATH printed above>" || exit 1
git add <the KB files you wrote>          # e.g. "$identifier/" index.json
```

> **The emptiness test is the guard, not `cd … || exit 1`.** `cd ""` returns 0
> and stays put, so an empty `<KB_PATH printed above>` sails straight through a `||` guard and
> every command after it runs against whatever repository the session happens
> to be in — which, on the path this pattern exists for, is then pushed to with
> branch protection and the audit gate disabled. Test for emptiness first;
> `cd … || exit 1` only catches a path that exists nowhere.

> Call 2 — commit. Must LEAD the call so the guard's credential scan runs.

```bash
git commit -m "<message>"
git pull --rebase                          # optional: sync before push (uses upstream tracking)
```

> Call 3 — push must LEAD, on ONE line, so the guard engages and logs the bypass WARNs.

```bash
NEXUS_KB_WRITE=1 SECURITY_AUDITOR_BYPASS=1 git push origin -- "$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' | grep . || timeout 10 git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2);print $2;exit}' | grep . || echo master)"
```

---

## Substituting values into a command (placeholders)

Several skills carry a value across Bash tool calls by printing it and having
the caller substitute it into the next command — `<KB_PATH printed above>`,
`{identifier}`, `{title}`. Shell state does not survive between calls, so this
is the mechanism that works; the rule below is what makes it safe.

### Three spellings, and they are not interchangeable

A value can reach a command in one of three ways, and each is spelled
differently so a reader — and a scanner — can tell them apart at a glance.
They used to be spellable alike: a placeholder written `${name}` is
indistinguishable from a shell read, and that ambiguity is how several values
shipped being read in a call that never set them.

| Spelling | What it is | What makes it safe |
|---|---|---|
| `$X` / `${X}` | a shell READ | it is assigned in the SAME block, set by a file that block sources, or a real environment variable. Never anything else — a value from an earlier block is gone. |
| `<X printed above>` | a value an EARLIER block printed | the setup block echoes it exactly once, and every block that writes through it tests it first (`[ -n "<X printed above>" ] \|\| exit 1`). An empty substitution turns `<X printed above>/thing` into `/thing`, at the filesystem root, where `mkdir` and `rm` succeed. |
| `{x}` | substituted by the model from context | its shape is CHECKED somewhere, and `tests/validators/placeholder-quoting.test` records where. Quoting is not what makes it safe: a value of `a";id;"` closes the quote whatever it is wrapped in. |

**Free text is the fourth case, and it has no spelling — it does not go on a
command line at all.** A title, a note, a plan, a path someone typed: write it
through a heredoc with a QUOTED delimiter and pass the file (`-F file`,
`--body-file file`, `"$(cat file)"`). The rest of this section is that rule in
detail.

Two consequences worth stating outright, because both have been got wrong:

- Substituting a value in order to CHECK it is the same defect as using it.
  Testing `case "{category}" in` puts the free text on a command line to find
  out whether it is safe.
- `$X` is always a shell read. There is no per-site exception for "this one is
  really a placeholder" — an exception list is a second place to edit that goes
  stale, and the check that enforces this (G7) needs none.

**Free text never goes on a command line.** A title, a summary, a description, a
commit message body — substituted into `--title "{title}"` or
`git commit -m "…{title}…"`, a value of `a";id;"` closes the quote and runs
`id`, and one containing `$( )` or backticks is executed outright. Write it to
a file, then reference the file.

**Use the `Write` tool to create that file.** It invokes no shell, so there is
no delimiter, nothing to quote, and no expansion to disable:

```text
Write  → $HOME/.claude/tmp/thing-title.txt   (contents: {title}, exactly)
```

```bash
git commit -F "$HOME/.claude/tmp/thing-title.txt" && rm -f "$HOME/.claude/tmp/thing-title.txt"
```

A quoted heredoc is the older shape and is still correct for a value **you** are
composing in the call, or for re-binding a value already in this session across
`Bash` calls — `/update-context`'s `{identifier}` and `{base_branch}` are the
worked example, since a second tool call there would be noise:

```bash
mkdir -p -m 700 "$HOME/.claude/tmp"
cat > "$HOME/.claude/tmp/thing-title.txt" <<'TITLE_EOF'
{title}
TITLE_EOF
```

Either way the commit gets **its own call**, because rule 2 above applies to it
like any other: writing the file and committing together would put `Write`'s
successor or a `cat` at the head of the input and skip the credential scan.

Where a heredoc is used, the quoted delimiter is the whole point — it disables
every expansion inside the body, so the text arrives as inert characters.
Leaving it unquoted reintroduces exactly what the heredoc was for.

**Quoting does not decide where the body ends — the body does.** A line inside
the content that is exactly the delimiter terminates the heredoc, and every
line after it is parsed as commands. That match happens before any
interpretation of the content, so quoting is no defence against it at all.

**When the body is not typed by the user in this session, do not use a heredoc
at all — write the file with the `Write` tool.** A note synthesised from a
ticket, a commit message summarising a CI log, a PR body assembled from a diff
and other people's comments: for all of these, `Write` puts no shell in the
path. There is no delimiter to collide with, nothing to quote, and no expansion
to disable, so what the content contains stops being a shell question. Create
the directory in its own `Bash` call first — `mkdir -p -m 700
"$HOME/.claude/tmp" && chmod 700 "$HOME/.claude/tmp"`; the mode argument applies
only to a directory `mkdir` creates, so an existing one at 755 keeps its mode,
and a `Write` to a missing path would create the parent at the default mode —
then `Write` the file, then `cat` / `-F` / `--body-file` it and `rm -f` it.

**The length of the content is not the test; where it came from is — and
"you wrote the words" is not the same as "you made it up".** If any part of the
value summarizes text you read from outside this session — a log, a ticket, a
diff, a review comment, a fetched page — it is third-party, even though you
composed the sentence. That is the disambiguator: a CI-fix commit message reads
like something you invented, and every clause in it came from the build log.

Where a heredoc is unavoidable over content you did not write — a fence that must
stay a single `Bash` call for a hook to see the right leading verb is the case
that actually arises — give the delimiter a fresh random suffix per invocation
(`THING_EOF_{nonce}`), generated as you write the call and never derived from the
content, from a file, or from a ticket — a delimiter drawn from text the attacker also wrote is one the attacker
can reproduce. Treat that as the fallback, not the default: an unguessable
delimiter makes a collision unlikely, `Write` makes it impossible.

`{nonce}` is shown as a placeholder, not a sample value, and that is deliberate: this
file ships, so a literal suffix printed here would be a delimiter every reader already
knows, and one copied through unchanged is a fixed delimiter with extra characters.

**Values with a checked shape may be substituted directly.** `resolve_config`
refuses a configured path containing a shell metacharacter — a quote, backtick,
`$`, backslash, `;`, `|`, `&`, `<`, `>`, a glob character or a newline — and
refuses a `..` segment in the parts that must stay inside their location. (It
does NOT refuse an absolute location path: those are documented and normal, and
that is exactly why the metacharacter check runs on them separately.) A slug
derived by slugifying is `[a-z0-9-]`; `{identifier}` is `{TICKET}-{slug}`. The check is what earns the substitution — if a value has
not been through one, it belongs in a file, not in a command.

**Derive rather than carry.** `add-product-knowledge` slugifies the title once
and carries the SLUG; every later block substitutes the slug. That is the
general shape: constrain the value at the point it enters, then pass the
constrained form.
