# Output Minimization Reference

Single source of truth for compact CLI flags, search-tool discipline, and agent return contracts. **Every line printed by a Bash, Grep, or Read call enters the caller's context window and consumes tokens.** Default to the most compact form that still answers the question being asked.

> **How to use this file:** Agents and skills reference this file by path
> (e.g., "Follow the compact-flag patterns in `plugin/shared/output-minimization.md`")
> rather than embedding the full table. The reference implementation is
> `plugin/agents/git-operator.md`, which already follows these rules in full.

---

## Principle

> "If the output is not used for a decision, suppress it."

Every command produces three categories of output:
1. **Decision-bearing** — needed to choose the next action. Keep, but minimize.
2. **Confirmation** — proves the command ran. Replace with `-q` / redirect to `/dev/null`.
3. **Progress / chatter** — remote refs, download bars, "Switched to branch X". Always suppress.

---

## Bash: Compact Flags by Tool

### `git`

See [`plugin/agents/git-operator.md`](../agents/git-operator.md#output-minimization-token-efficiency) for the full git table. Summary:

| Pattern | Use |
|---------|-----|
| `git status` | `git status --short` |
| `git diff` | `git diff --stat` first; full patch only for files you'll describe |
| `git fetch/push/pull/checkout/merge/rebase` | always pass `-q` |
| `git log` | use `--oneline -n N` for scans; `--format=...` for narrow projections |

### `gh` (GitHub CLI)

Always project to specific fields with `--json` + `--jq`. Never let `gh` fall back to default text mode for anything but a one-off interactive view.

| Instead of | Use | Why |
|------------|-----|-----|
| `gh pr view 123` | `gh pr view 123 --json number,state,title,headRefName,baseRefName,reviewDecision,mergeable` | Default text view ships ~30 fields; pick what you need |
| `gh pr list` | `gh pr list --json number,title,state,headRefName --jq '.[] \| "\(.number) \(.title)"'` | Project to one display line per PR |
| `gh issue view 29` | `gh issue view 29 --json number,title,body,labels,state` | Skip comments unless you need them |
| `gh run list` | `gh run list --branch X --limit N --json databaseId,name,status,conclusion,headSha --jq '...'` | Filter by `headSha` to scope to current commit |
| `gh run view {id}` | `gh run view {id} --log-failed` for diagnosis only; **never** `gh run view {id} --log` (full log = thousands of lines) |
| `gh api repos/X/pulls/N/comments` | Add `--jq '[.[] \| {id, path, line, body}]'` to slice fields |

### `jq`

| Pattern | Use |
|---------|-----|
| Whole document dump | Project: `jq '{key1, key2}'` or `jq '.array[] \| .field'` |
| `jq '.'` (pretty-print) | `jq -c '.'` (compact, one line per array element) for scanning |
| Nested traversal | Use `jq '.. \| select(.target?)'` only when paths are unknown — prefer explicit paths |
| Counting | `jq 'length'` instead of dumping the array |

### `aws`

Always pair `--query` (JMESPath projection) with `--output text` or `--output json`.

| Instead of | Use |
|------------|-----|
| `aws ec2 describe-instances` | `aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text` |
| `aws s3 ls s3://bucket --recursive` | `aws s3 ls s3://bucket --recursive --summarize \| tail -2` for size+count only |
| `aws logs filter-log-events ...` | Add `--max-items N --query 'events[].[timestamp,message]'` |

### `npm` / `pip` / `cargo`

The PreToolUse hook (`bash-token-filter.py`) injects `--silent`/`-q` for `npm install`, `npm ci`, `pip install`, `cargo build`. For other subcommands:

| Pattern | Use |
|---------|-----|
| `npm test` | `npm test -- --silent` (test runner output passes through) |
| `npm run X` | Tolerate output unless the script is known-noisy |
| `npm ls` | `npm ls --depth=0` (top-level only) |

### `docker`

| Instead of | Use |
|------------|-----|
| `docker build .` | `docker build -q .` |
| `docker pull X` | `docker pull -q X` |
| `docker ps` | `docker ps --format '{{.ID}}\t{{.Names}}\t{{.Status}}'` |
| `docker images` | `docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}'` |

### `kubectl`

| Pattern | Use |
|---------|-----|
| `kubectl get pods` | `kubectl get pods -o jsonpath='{.items[*].metadata.name}'` for name-only scans |
| `kubectl describe X` | Use `kubectl get X -o yaml \| yq '.status'` when you only need one section |
| `kubectl logs X` | Always pass `--tail=N` |

### `find` / `ls`

| Instead of | Use |
|------------|-----|
| `find . -name 'X'` | Use the **Glob tool** instead of Bash `find` |
| `ls -laR` | Use the **Glob tool** instead of recursive `ls` |
| `cat file` | Use the **Read tool** — never `cat` for inspection |

---

## Grep Tool Discipline

The Grep tool defaults to `head_limit: 250` lines. For most searches that's already too many — narrow before you call.

### Output mode selection

| Goal | Use `output_mode` | Why |
|------|------------------|-----|
| Find files containing X | `files_with_matches` (default) | Returns paths only — smallest output |
| Read matching lines | `content` with `head_limit: N` | Always cap; default 250 is rarely justified |
| Count occurrences | `count` | Returns one number per file — smallest signal |

### head_limit guidance

| Search type | Suggested `head_limit` |
|-------------|------------------------|
| Sanity check ("does X exist?") | `1` |
| Locate a single definition | `5` |
| Survey all call sites | `30–50` |
| Open-ended exploration | `100` (then refine) |
| **Never use the default 250** | unless you've already filtered with `glob`/`type` |

### Filtering before reading

Use `glob` or `type` to scope by file kind:
```
type: "py"           # ripgrep file type — most efficient
glob: "**/*.test.ts" # explicit glob — use for non-standard kinds
```

Combine with `path` to scope by directory.

### Context lines

Pass `-A`, `-B`, or `-C` only when the surrounding lines are needed to interpret the match. Default to no context.

---

## Read Tool Discipline

Every full-file Read becomes part of the conversation context. For files >200 lines, prefer:

1. **Grep first** to find the relevant line range, then **Read with `offset` + `limit`**:
   ```
   Read(file_path: "/path/big.py", offset: 340, limit: 80)
   ```
2. Use `limit: 100` for spot checks; only read the full file when you genuinely need the whole structure.
3. For known section headers, Grep for the header with `-n` to get the line number, then Read that range.

---

## Agent Output Contracts

Every agent invoked from a pipeline (i.e., not as the final user-facing call) **must** include a `## Output` section that defines:

- **What to RETURN** — the minimum information the caller needs to decide the next step
- **What NOT to RETURN** — full transcripts, raw command output, intermediate working notes, narrative restatement of the prompt

### Reference template

Model on `git-operator`'s [Output Guidelines](../agents/git-operator.md#output-guidelines):

```markdown
## Output

Your final response to the caller must be **minimal**. The caller has limited
context and verbose output wastes it.

### RETURN only:

| Item | Example |
|------|---------|
| {decision-bearing finding} | {one-line example} |
| {key identifier} | {file:line, hash, etc.} |
| {error or blocker if any} | {one-line, no debugging narrative} |

**Format:** {one-line-per-finding | severity-grouped | structured table}.

### DO NOT return:

- Full file contents, raw grep output, or command stdout
- Step-by-step narration of what you searched for
- Restatement of the prompt or input
- Hypothetical issues without evidence
```

### Sizing guidelines per agent type

| Agent type | Target output ceiling |
|------------|----------------------|
| Single-purpose worker (git-operator, doc-writer) | 1–3 lines per operation |
| Reviewer (code-reviewer, security-auditor) | severity-grouped findings, ~10–40 lines for typical PR |
| Investigator (archaeologist, business-analyst) | structured report, ~50–150 lines |
| Synthesizer (quality-guard verdict) | gates + verdict block, ~30–80 lines |

These are targets, not hard caps — a real critical finding always wins over brevity.

---

## Anti-Patterns

- **Echoing the prompt back** — never restate what the caller asked
- **Narrating the process** — "I searched X, then I read Y, then I noticed Z" — only the conclusions matter
- **Returning raw tool output** — `git status` text, full grep listings, full file dumps
- **Defensive verbosity** — listing every file you checked to "prove coverage." Confirm coverage in one line: `Reviewed: 12 files`
- **Hypothetical findings** — every claim must be backed by file:line evidence
- **Ignoring `--json` projection** — letting `gh`, `aws`, `kubectl` produce default text output when narrow JSON would do
