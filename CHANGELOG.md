# Changelog

## [1.33.0] - 2026-09-03

## What's Changed

14 commits across 4 merged PRs since v1.32.0: 3 feat, 6 fix, 5 merges. No breaking changes. One new skill; the rest is validators and CI.

### Features

- **skills**: new `/second-opinion` — hands a conclusion the session has already reached to a *different* model and reports what it says. Builds a neutral brief (the claim, the alternatives rejected and why, primary-source pointers, and the inverse question "what would have to be true for this to be wrong?"), dispatches one agent with a per-call `Task` model override (`fable` by default; `--model fable|opus|sonnet|haiku`), and reports the model the reviewer says it is, the verdict as given, the strongest objection unsoftened, then the session's own response. Changes nothing. Pinned to Opus under ADR-015 (score 9). Verified before building that the per-call override is honoured: probes came back Haiku 4.5, Opus 5 and Fable 5.1 for the three aliases (#384, CL-86)
- **validators**: F5 — CLAUDE.md's hand-written By Category tier list is checked against frontmatter on every `validate.sh` and CI run; the drift #376 caused and #377 fixed by hand now fails (#381, CL-83)
- **validators**: F6 — the 54 hand-written `**Model:**` lines in `docs/skills.md` and `docs/agents.md` are checked the same way, each doc standing alone. With F5 this closes every hand-written tier claim found outside the generated tables (#382, CL-84)

### Bug Fixes

- **ci**: on the self-hosted runner, the review job's sparse checkout of `.github/actions` into the shared workspace outlived the job, and under Debian 12's git 2.39 the next job's `actions/checkout` re-applied it — master validate after #381 failed with `scripts/validate.sh: No such file`. The review job now restores a full checkout on every exit, and every workflow with a root checkout resets sparse state before checking out; a workflow-syntax test pins both (#383, CL-85)
- **validators**: F5 skips a whole parenthesised note (a skill named inside another entry's note was scored as its own entry — a false PASS in one shape, a false FAIL in another), tolerates blank lines and tab indents, and knows `~~~` fences (#381)
- **validators**: F6 closes a component section at the next `##` chapter (a Model line under later prose was credited to the previous component), refuses an empty component map instead of certifying it, and reports an unsearchable `plugin/` as an enumeration failure (#382)
- **validators**: C7 recognises `general-purpose` as a built-in subagent type, alongside `Explore` and `Plan` (#384)

### Other Changes

- **ci**: `tests.yml` runs on changes to `validate.yml` and `claude.yml`, so the workflow-syntax pins on those files are enforced (#383)
- **docs**: ADR-015 census 54 → 55; the F-series bullet in CLAUDE.md now describes F2 as the prohibition it is and F3–F6 as checked-not-generated claims; README project-local skill count corrected to 9

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.32.0...v1.33.0

## [1.32.0] - 2026-09-02

## What's Changed

33 commits across 9 merged PRs since v1.31.0: 2 feat, 10 fix, 5 docs, 1 chore, 1 ci, 14 other (merges). No breaking changes.

### Features

- **models**: seven components re-tiered per ADR-015 — `bug-stub`, `jira`, `load-requirements`, `search-requirements` to Haiku; `architect`, `epic`, `feedback` to Opus. Cheaper on the commands that only fetch and format, better on the ones that make judgment calls. Distribution is now 12 Haiku / 29 Sonnet / 13 Opus (#376, #377)
- **validators**: new F4 check — ADR-015's per-component tier ledger is verified against frontmatter on every `validate.sh` and CI run, so a tier change can no longer leave its recorded reasoning silently stale. Third in the series after F2 (plugin/) and F3 (presentation/) (#378)

### Bug Fixes

- **hooks**: the push gate's blocked-push message told the reader to run an agent that cannot write the file the gate reads, and never named `record-audit.sh`, which can. It now names both steps, anchored to the repository being pushed so it works from a linked worktree (#375)
- **monitor-pr**: a CI failure matching none of the inline patterns is handed to `/troubleshoot` with a banner and a `handed_off` exit, instead of being diagnosed in the loop on a smaller model (#379)
- **monitor-pr**: replied-to comment ids are carried across runs in a ledger that survives cleanup, so the re-run the handoff instructs cannot answer the same reviewer twice. Only `acted` ids are carried; skipped and flagged items resurface for a human. Also fixed: both dedupe filters matched comment ids by substring, and now match exactly (#380)
- **ci**: `claude.yml`'s allowed tools scoped to read-only (#374)

### Other Changes

- **docs**: ADR-015 — a six-axis rubric and 54-component ledger for tier assignment, with the enactment order (frontmatter, validators, then regenerate) that surfaced four stale presentation files on first use (#355)
- **ci**: workflows switched to a self-hosted runner (#373)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.31.0...v1.32.0

## [1.31.0] - 2026-09-01

## What's Changed

139 commits across 24 merged PRs since v1.30.0: 3 feat, 68 fix, 6 docs, 10 test, 52 other (merges and chore). No breaking changes.

### Features

- **ci**: Claude Code Review is now opt-in via the `claude-review` label instead of running on every push — cheaper, and closes a real prompt-injection surface in the review workflow (#354, #359)
- **validators**: new G7 check — catches shell state (a `$VAR`, a shared-library function, a `$$` temp path, a printed placeholder) read in a Bash fence that never bound it, which cannot survive between Claude Code tool calls. Shipped fail-closed behind an owned gap list while the tree was swept, then the gap list was retired once clean (#357, #358, #360, #361, #362, #364, #366-#370)

### Bug Fixes

- **validators**: closed multiple scanner-precision gaps the G7 sweep surfaced — placeholder quoting (bare/single-quoted), heredoc delimiter collisions, `bash -n` parse coverage on every tagged fence, read-guard failures on `find`/`grep`/`awk` rc-2, and a new structure-tree check (H1-H3) that the `CLAUDE.md` repo tree matches the filesystem (#348, #349, #350, #351, #352, #353, #360, #362, #371, #372)
- **ci**: dropped a `--max-turns` flag on the review workflow that never actually bounded anything — a successful run could still exceed it and fail the check on its own assertion (#370)
- **skills**: third-party text (Jira comment bodies, issue titles) now goes to files instead of shell heredocs, closing an injection surface; one unicode-aware forged-content-marker scanner replaces several ad-hoc ones (#356, #366)
- **hooks**: worktree/branch resolution and multiline-quoted-argument parsing fixes (#363, #365)

### Other Changes

- Local gawk-parity tooling (`scripts/install-local-gawk.sh`) so a dev can reproduce CI's exact awk locally instead of discovering a gawk/mawk divergence only after CI turns red; the G7 fence-scanner's internal text views are now named explicitly with a test pinning that its two coupled read sites stay in sync (#372)
- Docs and internal cleanup across the G-series validator write-up in `CLAUDE.md` and `docs/decisions/`

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.30.0...v1.31.0

## [1.30.0] - 2026-08-27

## What's Changed

161 commits across 44 pull requests since v1.29.0: 6 feat, 75 fix, 12 test, 18 docs, 3 chore, 2 ci, 1 refactor. No breaking changes.

### ⚠️ Read first: the git safety hooks now actually run

Since 2026-04-08 the PreToolUse hooks read a `CLAUDE_TOOL_INPUT` environment variable that Claude Code never sets, so `git-mutation-guard`, `validate-commit` and `audit` saw an empty command in every installation — branch protection, the credential scan, the push audit gate and the commit-message ticket check gated nothing. This release fixes the input contract (hooks read the tool call from stdin) and the guards are live from the first session started after upgrading. Expect: pushes to `main`/`master`/`release/*` blocked, a credential scan on every commit, a push refused without a `record-audit.sh` record, and commits without a ticket key refused. Hook configuration is snapshotted at session start, so restart running sessions to pick it up. — CL-62, CL-64

### Features

- **pr-review**: orchestrated review path — a Workflow-tool script runs three blind per-dimension reviewers (code-reviewer, security-auditor, architect) over the raw diff, then three adversarial challengers with distinct identities verify every finding; falls back to the sequential path when the Workflow tool is unavailable; gate runner and report-path exclusion check shipped in `shared/pr-review/` — CL-40
- **jira**: `/jira create` write verb with the ADR-012 JSON envelope; every write verb names the site by hostname — CL-44, CL-49
- **prompt-defense**: content boundary markers (`ARCHIVED-CONTENT`, `UNTRUSTED-CONTENT`) defined in `shared/prompt-defense.md`; emitted by archivist and `/create-requirements` (Stages 4.1 and 4.6, with a forged-marker scan that fails closed and re-runs on resume); consumed by business-analyst — CL-39
- **validate**: G-series prompt shell-safety validator for the bash fences inside skill and agent prompts — CL-53, CL-61
- **release**: release skills advertise their arguments where they are read — CL-28

### Bug Fixes

Hooks (all plugin installs):
- **hooks**: read the tool call from stdin; fail closed on empty or unparseable input, a missing `command`, a truncated contract file, an absent `jq`, or a credential scanner that cannot run (previously fail-open); macOS bash 3.2 `mapfile` and empty-array fail-opens — CL-62
- **hooks**: gate `git commit`/`git push` anywhere in a compound command — `cd x && git push`, `nice git push`, `/usr/bin/git`, `git -c`/`-C`/`--no-pager`, `bash -c "git push"`, `eval`, subshells, `$( )`, backticks, spliced quotes, a `#` inside a commit message; bypass flags apply only to the segment that carries them; `--dry-run` exempt; `GIT_SSH_COMMAND` with a space refused; PATH-independent — CL-64
- **validate-commit**: parse quoted, heredoc, `-am` and `--message` commit messages (the previous regexes had never read a real subject); refusal text on stderr — CL-62

Prompt-injection defense:
- **agents**: prompt-defense reference for the second-order fleet, git-operator, test-writer, playwright-engineer — CL-39, CL-50
- **skills**: prompt-defense for `/load-context`, `/load-requirements`, `/search-requirements`, monitor-pr's two ingestion points — CL-38, CL-42, CL-48
- **archivist**: mark KB-sourced blocks and scan stored content for injected markers before archiving — CL-39
- **monitor-pr**: dedup CI-log injection flags per run/job; prescribed reason string — CL-45, CL-46

Shipped prompts that could not have run as written:
- **skills**: shell variables and sourced functions do not survive between Bash tool calls — 291 cross-block reads across 18 skills fixed by in-block re-derivation or a printed placeholder (`<WORK_DIR printed above>`); monitor-pr no longer keys its runs file on a PID that is new in every call; work-status resolves brainstorm sessions correctly — CL-60
- **report-issue**: the secret-scan gate now scans and publishes the same bytes in the same call; draft kept under `.claude/report-issue/` with `umask 077`, symlink refusal, `set -C`, removed after publish — CL-60
- **prompts**: every `cd "$VAR"` guarded against an empty value; every `git commit`/`push` leads its block — CL-53
- **skills**: user free text (titles, categories, summaries, PR bodies) travels through files, never command lines; pr-review builds its payload with `jq --rawfile` so PR content cannot inject an `event` — CL-57
- **storage**: one strict rule gates knowledge-base writes; configured path fragments are contained (`..`, shell metacharacters refused); `/add-product-knowledge` reports a skipped write instead of silently proceeding; `/rebuild-index` states both storage types and bounds backups — CL-32, CL-35, CL-51, CL-52 (ADR-014)

Validators and tests:
- **validators**: a failed read is an I/O error, never a verdict about content or a silent pass (`lib/io.sh`, stdout-only reporting, a sweep test that makes one file of each kind unreadable per validator) — CL-54
- **validators**: C3 no longer reads every backticked word as an agent name; C5b/C5d control gaps closed; presentation and plugin tier-claim drift checked — CL-36, CL-37, CL-39, CL-58
- **tests**: assertions observe the exit code; SIGPIPE no longer inverts contains-assertions — CL-34

CI:
- **ci**: Tests matrix collapsed to one job (~24 → 3 billable minutes per run), superseded runs cancelled, healthcheck weekly instead of per-PR, every job bounded by a timeout, silent review skips made visible; Node 20 actions retired — CL-41, CL-47, CL-55, CL-56, CL-59

### Other Changes

- ADR-012 (Jira create envelope, success and failure), ADR-014 (artifact resolution strictness), diagram-design skill assessment — CL-44
- Stale work session state reconciled — CL-21

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.29.0...v1.30.0

## [1.29.0] - 2026-08-26

## What's Changed

14 commits: 2 feat, 4 fix, 2 test, 2 docs, 2 chore. No breaking changes.

One security control and one CI cost fix. `business-analyst` was the only agent in the requirements pipeline with an ingestion surface and no prompt-injection framing — nine peers already carried it — so knowledge-base content reached requirements synthesis with no instruction to treat it as untrusted. This release closes that, and gives the check enforcing it its first automated coverage.

### Features

- **agents**: `business-analyst` now carries the canonical prompt-defense treatment — CL-33

  The blockquote names all three ingestion surfaces, not just the upstream agent's output: archivist SEARCH results, other agents' context-directory findings, and files read directly from a matched ticket's archived directory. The instruction at the third of those previously said to cite matched-ticket content "as confirmed", an elevated-trust framing applied to the least-trustworthy input; it is now a four-branch decision (verifies / contradicts / cannot be checked / carries a directive) with an explicit precedence rule.

- **validators**: `business-analyst` registered in the C5b ingestion list, and the eligibility rule written down at the enforcement point — CL-33

  No document previously defined what makes an agent an "ingestion agent", which is why second-order consumers were never considered. The rule now states both branches and cites the correct basis for each: the provenance-persistence rule governs pass-through only, while a direct knowledge-base read is first-order. The check logic itself is unchanged.

### Bug Fixes

- **validators**: C5b emits the roster its loop actually iterates, so a runtime change to the agent list can no longer disarm the check silently — CL-33
- **agents**: the failing-verification branch no longer instructs reproducing untrusted assertions into work-state, which the provenance rules forbid — CL-33
- **agents**: the knowledge-base read is now constrained beneath the requirements-repository root; the path arrives via another agent's output and was previously unbounded — CL-33
- **validators**: corrected a rule citation that named a rule which does not exist, and a header severity that described a blocking check as advisory — CL-33

### Tests

- **validators**: new C5b coverage — 10 tests where there were none, verified by mutation rather than by passing: reference stripped, agent dropped from the list, agent name removed from the failure message, loop short-circuited, failure downgraded to a warning, and failure line indented (which defeats the aggregator's column-anchored count while the test still catches it) — CL-33

### Other Changes

- **ci**: Claude review and healthcheck no longer run on every push to an open pull request — SKILLS-000

  Both triggered on `synchronize`, so an eight-commit branch bought eight full Claude reviews. That exhausted the Actions budget and CI went dark for five days, taking the v1.28.0 plugin publish with it. They now run on `[opened, ready_for_review]`, with a `paths-ignore` for work-directory artifacts. The deterministic gates (`validate`, `tests`) still run on every push, so per-push safety is unchanged — only the advisory LLM signal moved to once per pull request.

- **plugin**: the untrusted-data guideline now covers agents that only synthesize another agent's already-ingested output — CL-33
- **docs**: requirements triad and design-review record for CL-33

### Known Gaps

Tracked, not fixed here:

- The ingestion check is an unanchored substring match, so a reference inside a code fence satisfies it. A test locks this in as documented behaviour rather than leaving it implicit — CL-39
- A renamed or deleted agent file degrades to a warning rather than a failure, leaving the build green — CL-39
- Wording assertions cover `business-analyst` only; the other nine ingestion agents remain substring-only — CL-39
- Four further agents meet the newly written eligibility rule and are not yet listed — CL-39
- Two higher-privilege knowledge-base readers render archived content into the main orchestrating context with no untrusted-input notice — CL-38

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.28.0...v1.29.0

## [1.28.0] - 2026-08-26

## What's Changed

38 commits since v1.27.1: 2 feat, 12 fix, 6 chore, 7 docs, 4 test, 1 refactor, 1 ci. No breaking changes.

### Features

- **implement**: two archive trigger points with fail-closed consent — CL-27
- **scripts**: generate model-tier doc regions from frontmatter — CL-5

### Bug Fixes

- **implement**: branch on the archivist's actual outcome, not on having dispatched it — CL-27
- **implement**: address QA findings — broken opt-out, missing state write, misplaced publish — CL-27
- **skills**: close the same bypass defect in rebuild-requirements-index — CL-27, SEC-1, SEC-2, SEC-6, SEC-7
- **agents**: write index entries with the full template schema — CL-27
- **agents**: replace the index entry by identifier on re-archive — CL-27
- **agents**: anchor relative requirements-KB paths to the project root — CL-27
- **agents**: branch archivist STORE on storage type, no bypass push for directory KBs — CL-27, SEC-1, SEC-2, SEC-4
- CL-27: close the terminal skeptic's 8 gates — AC-1, SEC-3
- **scripts**: harden temp files, name gate and fence tracking — CL-5, CWE-377
- **scripts**: close truncation path and generate per-skill Model lines — CL-5, CL-26
- **presentation**: add quality-guard to the Opus agent listings — CL-5
- **scripts**: address security review findings in the generator — CL-5

### Other Changes

- **config**: enable Jira write operations for this repo — CL-5
- **skills**: delegate archive commit/push mechanics to archivist STORE (refactor) — CL-27
- **validate**: trigger on docs/** and the tier generator (ci) — CL-5, ADR-011
- Test coverage: config artifact backfill comparison, implement archive-offer delegation/consent, archivist storage-type STORE branch, tier-region freshness gate (F1) — CL-27, CL-5, CL-26
- Docs: requirements-KB directory-type store semantics (ADR-013), archive trigger points, work-session records for CL-27 and CL-5 — CL-27, CL-5, ADR-012, ADR-013
- **skills**: drop model-coupled capability claims from plugin prose — CL-5, SKILLS-060, SONNET-5

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.27.1...v1.28.0

## [1.27.1] - 2026-08-19

## What's Changed

8 commits since v1.27.0: 3 fixes, 1 test, 1 docs, 1 chore (plus 2 merge commits). No new features and no breaking changes. This is a correctness patch covering two tickets — CL-29 (`review_plan` phase config drift) and CL-31 (AskUserQuestion option-cap compliance).

### Bug Fixes

- **skills**: recognise the `review_plan` phase in `/configuration-init` — CL-29
- **templates**: complete the phase list and drop a false claim — CL-29
- **skills**: keep AskUserQuestion option lists within the 4-option cap — CL-31

### Tests

- **validators**: add A7 guard against over-cap AskUserQuestion blocks — CL-31

### Other Changes

- **work**: requirements triad, QA records and follow-up ledger — CL-29
- **work**: final state, manifest and cost summary — CL-29

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.27.0...v1.27.1

## [1.27.0] - 2026-08-17

## What's Changed

1 commit since v1.26.1 (1 feat, squash-merged from PR #294), no breaking changes. This release lands CL-22: a scope-contract hardening pass across `/create-requirements`'s deep-dive pipeline plus new requirements-run telemetry.

### Features

- **create-requirements**: add an explicit "don't re-derive `context-builder`'s discovery inventory" contract to five deep-dive roles (`architect`, `aws-architect`, `integration-analyst`, `security-requirements`, `archivist`) at both the persistent agent-definition and per-invocation dispatch-prompt layers; instrument Stage-3 exit with a `requirements-telemetry.md` record (spawn count and model tier per role); extend `scripts/cost-report.sh` to discover, attribute, and subtotal both `/implement`'s and `/create-requirements`'s telemetry, with added input-sanitization hardening — CL-22

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.26.1...v1.27.0

## [1.26.1] - 2026-08-16

## What's Changed

14 commits since v1.26.0, all documentation (13 `docs` + 1 merge commit), no breaking changes, no new features. This release lands CL-26: a documentation alignment audit correcting drift between the plugin's shipped behavior and its published docs.

### Documentation

- **configuration**: document the Jira write-flag's ADR-012 link, add the full 7-phase team-mode table (replacing a stale single-skill claim), fix the worktree-isolation affected-skills list
- **installation**: fix installed-component counts (hooks, templates, skills) and the team-mode claim to match configuration.md
- **agents**: narrow `git-operator`'s documented scope to match ADR-007 (merge conflicts, complex rebases, large-range PR body authoring only — not routine commit/push/PR); correct the `git-mutation-guard.sh` enforcement description (it only actually gates `git push` and `git commit`); clarify `GIT_AUTHORIZED=1`'s two sanctioned narrow uses
- **skills**: redraw the skills-to-agents diagram to cover all 34 shipped skills (previously showed 11); remove stale `git-operator`-delegation claims from 5 skill entries and an example sequence diagram; add the missing ADR-012 link on the `/jira` entry; fix a mermaid render error (unquoted node labels) that had silently broken the diagram
- **implementation-plan**: mark the pre-marketplace install plan as a historical record, superseded by the native plugin marketplace install path
- **readme**: refresh the "Last Updated" date, list all custom-addition directories (`hooks/`, `shared/`, `templates/`)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.26.0...v1.26.1

## [1.26.0] - 2026-08-16

## What's Changed

12 commits: 4 feat, 2 fix, 3 test, 1 docs, 2 unscoped. No breaking changes.

### Features

- **configuration**: explicit `jira.enabled` master opt-out (gates acli calls in both read and write paths) + `implement.playwright_scoping.default` to pre-set the Playwright auto-include decision — CL-23
- **create-requirements**: auto-seed feature description from a loaded Jira ticket — CL-15
- **implement**: add Playwright scoping question before E2E test generation — CL-14
- **implement**: add Phase 3.2b deviation checkpoint (plan-vs-diff sanity check after each chunk commit) — CL-11

### Bug Fixes

- **update-context**: propagate lock-subshell failure in Step 5's state.json write instead of silently reporting success — CL-24
- **work-status**: serialize state.json/manifest writes with flock to prevent races with concurrent hook writes — CL-12

### Other Changes

- CL-21: handle multi-ticket meetings, draft requirements, ADF text
- Remove `install.sh` / `uninstall.sh` and purge all references (native plugin install is now the only path) — CL-8
- Add Layer 1 and Layer 2 test coverage for `context-builder`, `refactorer`, and `database-analyst` agents — CL-9
- docs(full-cycle): remove ticket references from mermaid diagram nodes, keeping them in the surrounding prose — CL-25

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.25.0...v1.26.0

## [1.25.0] - 2026-08-16

## What's Changed

1 commit (squash-merged PR #279): a new feature in the `/jira` skill. No breaking changes.

### Features

- **jira**: `/jira KEY-123` now renders real Atlassian Document Format (ADF) ticket descriptions as plain text (paragraphs, bold/italic/code/strike marks, headings, bullet/ordered lists, code blocks, blockquotes, tables) instead of a fixed `"(rich-text content — not rendered here)"` placeholder — most Jira Cloud tickets store descriptions as ADF by default, so this was previously the common case. Malformed or unrecognised ADF shapes still fall back to the placeholder rather than failing the whole read. — CL-20

### Hardening

- Recursion depth in the new ADF renderer is capped (50 levels, truncates rather than recursing further) against pathologically nested ticket content, and the type-confused-input path is wrapped so a malformed field degrades safely instead of crashing `/jira`'s view operation.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.24.0...v1.25.0

## [1.24.0] - 2026-08-15

## What's Changed

2 commits: 1 feat, 1 docs. No breaking changes.

### Features

- **jira**: extend `/jira` to opt-in write operations (comment, transition, assign/unassign) — CL-18

### Other Changes

- **claude-md**: add Response Style guideline — CL-19

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.23.2...v1.24.0

## [1.23.2] - 2026-08-15

## What's Changed

7 commits: 6 docs, 1 ci. No features, fixes, or breaking changes — this release consolidates documentation and CI housekeeping from the CL-1 framework-simplification audit and TODO bookkeeping.

### Other Changes

- **docs**: CL-1 framework-simplification audit decision list (#273)
- **docs(todo)**: file pending items to Jira, fix stale Completed bookkeeping (#274)
- **docs(todo)**: trace healthcheck Mode 2 to the tool denials (#272)
- **docs(claude-md)**: add feedback, presentation and tests/storage to the tree (#271)
- **ci(healthcheck)**: make a green run imply a report exists (#270)
- **docs(skills)**: add meeting to the Opus tier table (#269)
- **docs(todo)**: file healthcheck green-when-no-signal defect (#268)

**Full Changelog**: https://github.com/nexus-a1/claude-skills/compare/v1.23.1...v1.23.2

## [1.23.1] - 2026-08-02

Patch release. **Repository tooling only — the distributed plugin payload is unchanged from v1.23.0.**

## Fixed

**CI healthcheck ran with no shell-quality coverage and a permanent false score deduction** (#267)

SKILLS-071 (#260) made `scripts/validate.sh` the deterministic Tier D of the CI healthcheck but did not carry over that job's environment. `shell-quality.sh` degrades to `[WARN] … skipping shell-quality checks` when `shellcheck` is absent, and the healthcheck job never installed it — so every CI healthcheck ran with **zero D1 coverage** while taking a standing −2 on its headline Tier D score for an environment gap rather than a repository defect. A false deduction, in the job whose whole purpose is trustworthy signal. `validate.yml` had installed shellcheck for this exact reason since #253.

**The healthcheck had no CI trigger on its own definition** (#267)

Neither `.claude/skills/healthcheck/**` nor `.github/workflows/healthcheck.yml` appeared in the workflow's `paths` filter. A change to the skill body — which *is* the check definition — or to the tier rules and report format carried in the workflow prompt shipped with no CI signal at all. `tests.yml` has carried an explicit self-trigger against this precise silent-skip failure since SKILLS-072; the job that grades the repository lacked it. Both entries added.

`scripts/**` was deliberately excluded from the trigger: Tier D is `scripts/validate.sh`, already gated deterministically by `validate.yml` on every validator edit, so triggering a paid LLM run there would buy duplication only.

## Notes

Closes the SKILLS-071 `TODO.md` entry, whose closeout task was never performed — it still read *In progress* after #260 merged, and closing it is what surfaced both gaps above.

**Full changelog:** https://github.com/nexus-a1/claude/compare/v1.23.0...v1.23.1

## [1.23.0] - 2026-07-31

## What's Changed

2 commits: 2 feat. No breaking changes.

### Features

- **meeting**: meeting records are now written to `$MEETINGS_DIR/{YYYY-MM-DD-HHMM}-{slug}/` instead of `$MEETINGS_DIR/{slug}/`, so a plain directory listing sorts chronologically and recurring meetings are distinguishable without opening each one. Meetings recorded before this format keep their bare `{slug}` directory names permanently — nothing is renamed, moved, or migrated. Lookups still accept a bare slug and resolve to the newest match, or a full directory name. Directory resolution moves into a new shared library (`shared/meeting/resolve-meeting-dir.sh`) covered by shellcheck and 34 new tests — SKILLS-077

  Two behaviour changes worth noting for existing users:
  - Resuming a meeting whose newest match is already **wrapped** now warns and asks whether you meant to start a new occurrence, rather than silently reopening a finished record.
  - Re-entering a dropped live session continues the same record instead of creating a second directory for it.

- **configuration-init**: adds a `location-rename` migration verb. Configs generated before SKILLS-074 call the shared storage location `team-repo`, while the shipped template has always called it `team-knowledge`. Backfill matched a template artifact's location against the keys defined in the target config, so every team-located artifact was silently skipped and `validate` named a migration that then refused to run. The rename and the backfill it unblocks now land in one run. A config defining *both* names is reported and skipped — that is a merge, not a rename, and picking a winner would discard a definition — SKILLS-075

### Other Changes

- `plugin/shared/meeting/` is registered in the D1 shellcheck target list, so the new shared library is statically checked in CI.
- Corrects a stale path in `shared/meeting-schema.md`, which still documented the pre-SKILLS-069 `$WORK_DIR/meetings/{slug}/` location.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.22.0...v1.23.0

## [1.22.0] - 2026-07-31

## What's Changed

One ticket (SKILLS-074), squashed into a single commit across 21 files. No breaking changes. Existing configurations are not modified by upgrading; the changes affect newly generated configs and add an opt-in migration.

`/meeting` was writing artifacts beside the project instead of inside the configured storage directory. The cause was not in `/meeting` — `/configuration-init` listed the artifact types from memory in six separate places, all of which had drifted, and none of which mentioned `meetings`. A configuration missing an artifact falls back to a guessed path, which is silently wrong whenever the project's local storage base is not the conventional `.claude`, or whenever the artifact belongs in a shared team location.

All six sites now read the artifact catalog live from `plugin/templates/configuration.yml`, which becomes the single source of truth.

### Features

- **configuration-init**: new `artifact-backfill` migration verb — `/configuration-init migrate` now detects artifacts the current template defines but your configuration is missing, and adds them behind the existing confirmation gate. An artifact whose storage location is not defined in your config is skipped with a warning rather than written, so migration cannot introduce a dangling reference — SKILLS-074
- **configuration-init**: `/configuration-init validate` reports a warning naming each artifact present in the template but absent from your configuration, so drift is caught immediately instead of surfacing later as a misplaced file — SKILLS-074
- **config**: new shared library `plugin/shared/config/artifacts.sh` for reading the template's artifact catalog and for migration write-safety — SKILLS-074

### Bug Fixes

- **configuration-init**: the setup wizard generates every artifact the current template defines, and creates a directory for each locally-stored one. Previously both lists were hardcoded and stale — SKILLS-074
- **configuration-init**: `migrate` never loaded the project's configuration, so `resolve_artifact` was called as an undefined function with its error silenced and a hardcoded default substituted. Any project with a customized work location was migrating against the wrong directory, with no symptom — SKILLS-074
- **configuration-init**: `validate` had the same gap, which is why the missing-artifact check could not previously be implemented where it belongs — SKILLS-074
- **configuration-init**: migration backs up each file at most once per run. Previously every verb wrote `<file>.bak-<timestamp>` with a single per-run timestamp; once two verbs could target `configuration.yml` in the same run, the second would have overwritten the first verb's backup with an already-rewritten intermediate — SKILLS-074
- **configuration-init**: migration now verifies the available `yq` preserves comments before rewriting, and refuses with an explanation otherwise. The installation docs suggest `apt install yq`, which on Debian/Ubuntu installs python-yq — a jq wrapper that does not round-trip comments — SKILLS-074
- **tests**: the shared test harness reported a test as passing whenever its final assertion passed, regardless of earlier failures, which silently disarmed multi-assertion tests across every suite — SKILLS-074

### Behavior Changes

- **configuration-init**: the wizard now writes the shared storage location under the key `team-knowledge` rather than `team-repo`, matching the shipped template, `plugin/CLAUDE.md`, and the wizard's own prompt text. Existing configurations are untouched and continue to work. Configurations generated by earlier versions retain `team-repo`; see nexus-a1/claude#264 for the tracked consequence.

### Other Changes

- New `tests/configuration-init/` suite — 103 tests across 6 files, covering the artifact catalog, migration write-safety, wizard output, and the skill's structural contract
- `plugin/shared/config/` registered with the D1 shellcheck validator
- `CLAUDE.md` structure tree and D-series description updated

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.21.0...v1.22.0

## [1.21.0] - 2026-07-30

## What's Changed

1 commit since v1.20.0: 1 feat, no breaking changes. This release makes the `/jira` work-item key optional, behind a mandatory confirmation gate.

### Features

- **jira**: make the work-item key optional, gated on explicit confirmation — SKILLS-073

  Invoked bare, `/jira` now proposes a work-item key from four signals — the current branch, the active work session, recent commit subjects, and the conversation — and reads only what the user explicitly confirms. No flag skips confirmation, and neither does unanimous agreement between signals.

  The typed-key path is unchanged, including for typos: inference fires only when `$ARGUMENTS` is empty, so `/jira PROJ-12X` still prints usage rather than guessing. `/jira` remains strictly read-only.

  Adds `plugin/shared/jira/key-inference.sh` (self-collecting, so the skill needs only `AskUserQuestion` added to its grants) and 50 hermetic tests.

  Supersedes the decision closed in SKILLS-070 (OQ-3 / AC-3.5). Of its two objections, the first is answered — nothing is silent, since confirmation is mandatory and shows the source text a key came from — and the second, that this re-adds an interactive tool grant removed on minimum-grant grounds, is accepted as a cost rather than refuted.

### Other Changes

- **ci**: fix D1, which had never actually run shellcheck — `shell-quality.sh` warns and skips without the tool, and `validate.yml` ran the validators without installing it.

### Known Limitations

- The confirmation gate is enforced by `SKILL.md` prose only. `invoke_claude()` in the test harness is a stub, so six acceptance criteria are graded by review rather than CI. This was declared in `spec.md` before implementation.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.20.0...v1.21.0

## [1.20.0] - 2026-07-28

## What's Changed

3 commits: 1 feat, 1 refactor, 1 ci. No breaking changes.

A new read-only Jira skill, plus two fixes to CI trustworthiness — a self-assessment that was reporting false criticals, and a test runner that silently skipped 16 test files.

### Features

- **jira**: add read-only `/jira` skill via the Atlassian CLI — SKILLS-070

  Read a work item and its recent comments from the terminal. Strictly read-only; every result is labelled with the Jira site it came from. Requires `acli` installed and authenticated.

  Write verbs are deliberately unimplemented: `acli` returns exit 0 even when a write fails completely, and its success-response shape has not been verified against a live instance, so a wrongly-reported success could mean a duplicate public comment or a ticket moved to the wrong state. The v2 design is specified and blocked on five observations recorded in `TODO.md`.

### Changes

- **healthcheck**: deterministic backstop for LLM-graded checks — SKILLS-071

  The CI healthcheck graded all 22 of its checks by having a model read files by hand, with no mechanical verification and no requirement to cite evidence, yet any check could emit a critical. It reported a skill as absent from `CLAUDE.md` across three consecutive commits while a deterministic validator checked the same property and passed in the same run.

  Split into two tiers: `scripts/validate.sh` is the only tier permitted to emit FAIL; judged checks are capped at WARN, must cite `file:line` plus the verbatim line, and a judged claim contradicting a deterministic PASS marks the run untrustworthy. Adds two new validator checks — `C6` (skill/agent listing across docs and `CLAUDE.md`) and `C7` (phantom agent references) — which mechanize the coverage the hallucinating check had no deterministic equivalent for.

- **tests**: discover test suites instead of listing them — SKILLS-072

  `tests.yml` registered suites by explicit allowlist, so a suite on disk but absent from the workflow produced no CI signal at all — it did not fail, it never ran, and nothing reported the omission. Three suites were in that state, including the tests for `credential-scan.sh` and `git-mutation-guard.sh`.

  A `discover` job now enumerates `tests/*/` and feeds a matrix, so adding a suite means adding the directory. Test coverage in CI goes from 27 of 43 files to 43 of 43.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.19.0...v1.20.0

## [1.19.0] - 2026-07-28

## What's Changed

5 commits: 1 feat, 1 fix, 3 docs. No breaking changes.

The headline change is that `meetings` and `brainstorms` are now first-class artifact types, resolved from `.claude/configuration.yml` like every other artifact instead of being written inside the work session store.

### Upgrade notes

**Where meetings and brainstorms are written has changed.** Artifacts are meant to be siblings under the storage location root (`locations[<name>].path` + `subdir`). Two skills did not honour that:

| Artifact | Before | After |
|---|---|---|
| `meetings` | `<location>/work/meetings/` | `<location>/meetings/` |
| `brainstorms` | `<location>/work/{slug}/` | `<location>/brainstorm/{slug}/` |

**No configuration change is required.** The resolver falls back to `location: local` plus the default subdir, so both resolve correctly even when absent from an existing `configuration.yml`. A `meetings` key is now documented if you want to override it.

**Existing records stay reachable.** Every reader falls back to the previous location, and a session or meeting found there is read, resumed, wrapped, and updated **in place** — nothing is moved automatically. If you prefer the new layout, move the directories yourself and run `/rebuild-index brainstorms`.

### Features

- **skills**: `/work-status --brief` — a narrative digest of active work sessions instead of the table view (#246)

### Bug Fixes

- **storage**: resolve `meetings` and `brainstorms` as first-class artifact types (#258) — SKILLS-069

  `/meeting` hardcoded `$WORK_DIR/meetings`, and `/brainstorm` wrote sessions into `$WORK_DIR` while upserting them into the *work* manifest using the work schema. The `brainstorms` artifact key was therefore documented but never written by anything, and `/load-context` read a directory that was always empty.

  Also fixed in the same change:
  - The brainstorms manifest schema could not represent an in-flight session (it had no `status` or `current_phase`), which is why the work schema was used instead. It now carries session fields alongside the catalog fields.
  - `/rebuild-index brainstorms` omitted `status` entirely. Because a null status satisfies both `!= "completed"` and `!= "promoted"` in jq, a rebuild made every brainstorm ever created reappear as resumable — including promoted ones.
  - `/resume-work`, `/work-status`, `/load-context` and `/create-requirements --from-brainstorm` now read both the new and legacy locations, and write back to whichever one owns the session.

### Other Changes

- **claude-md**: sync the repository structure tree with the files on disk — `plugin/shared/` was missing 6 files, `docs/workflows/` the `meetings/` subdirectory, and `tests/` listed 4 of 12 entries (#256)
- **todo**: split tier-assignment governance out of the SKILLS-068 drift-prevention item after an architect/quality-guard plan review, and record a live docs-vs-frontmatter drift instance (#255)
- **todo**: extend the generated-tables item to cover the `CLAUDE.md` structure tree (#257)

### Testing

New `tests/storage/` suite (17 tests), wired into CI as a `storage-tests` job:

- `01-artifact-resolution.test` — artifact path resolution across defaults, custom location paths, explicit subdir overrides, absolute second locations, and workspace anchoring from a subdirectory. Two tests assert the core invariant that artifacts resolve as **siblings, never nested**; verified to fail against the pre-fix behaviour rather than merely pass against the fix.
- `02-manifest-filters.test` — the jq filters that decide which sessions are actionable, plus the producer contract they depend on (a status-less manifest defeats the filter entirely).

CI test triggers now include `shared/resolve-config.sh`, `shared/manifest-schema.md`, and the six skills these paths flow through.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.18.1...v1.19.0

## [1.18.1] - 2026-07-26

## What's Changed

2 commits: 1 feat, 1 docs. No breaking changes.

**No user-facing changes.** Nothing under `plugin/` was modified, so the installed plugin is identical to v1.18.0. This release tags maintainer tooling that prevents a class of bug from reaching future releases. Installers can skip it.

### Repository Tooling

- **validators**: enforce pinned model IDs via a model catalog — SKILLS-068 (#253)

  Model assignments had drifted twice without CI noticing. SKILLS-060 left 9 components on `claude-opus-4-8` after Opus 5 shipped (fixed by hand in #250), and `/meeting` shipped in v1.18.0 on the bare alias `model: opus`, caught only by a manual pre-release read (#252). Both slipped through because the A3/B5 validators asked *"does this look like a model field?"* rather than *"is this the model we intend to ship?"* — the `claude-opus-*` glob matches every Opus ever released, and bare aliases were whitelisted outright.

  `scripts/model-catalog.sh` is now the single source of truth. Both validators source it and accept only current IDs; superseded, retired, policy-excluded, alias, and unknown values each fail with a distinct actionable message. Moving an ID from `CURRENT` to `SUPERSEDED` turns CI red on every component still declaring it, and that failure list is the maintainer's work queue.

  `validate.yml` now also triggers on `scripts/model-catalog.sh` — without it, editing the catalog (the forcing action itself) would not have fired CI.

- **docs**: document `/work-feedback` and `/work-issue`, fix project-local counts — SKILLS-068 (#254)

  Both skills existed on disk, fully formed and user-invocable, but appeared in no documentation. `README.md` claimed 3 project-local skills, `CLAUDE.md` claimed 4, and 6 exist. All three sources now agree with the filesystem.

### Decisions

- **[ADR-011](https://github.com/nexus-a1/claude/blob/v1.18.1/docs/decisions/011-model-version-bump-policy.md)** — pinned model IDs enforced by a validator-sourced catalog.

  Records why component frontmatter must pin an exact ID rather than an alias (an alias silently re-points for already-installed users, outside the release cycle), why `claude-fable-5`/`claude-mythos-5` are excluded by policy (they require 30-day data retention and return 400 for Zero-Data-Retention orgs, and frontmatter ships one static string to everyone), and why project-local skills under `.claude/skills/` are exempt by decision rather than omission.

  Scope-limited: it governs *which ID* a component may declare, not *which tier* it belongs in. The tier rubric remains open work.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.18.0...v1.18.1

## [1.18.0] - 2026-07-26

## What's Changed

5 commits: 1 feat, 3 chore, 1 docs. No breaking changes.

This release adds the `/meeting` skill and completes the model-tier move to Opus 5.

### Features

- **skills**: add `/meeting`, a live meeting-capture pipeline — SKILLS-000 (#248)

  Capture notes as a meeting happens while background probes ground each topic against the Product Knowledge Base and the live codebase, surfacing findings inline without stalling capture. On wrap it emits two distinct documents — a shareable summary and a technical changes/risks doc — as Markdown plus printable HTML under `$WORK_DIR/meetings/{slug}/`. Supports live, one-shot (`--file`/`--dir`), `--resume`, `--wrap`, and `--lite` modes.

  Ships two new shared components:
  - `shared/meeting-schema.md` — the meeting record and document schema
  - `shared/render-doc-html.sh` — zero-dependency Markdown/HTML → self-contained printable HTML. Uses pandoc when present, otherwise falls back to a caller-authored HTML body, so no pandoc/LaTeX/headless-browser install is assumed.

### Other Changes

- **models**: bump Opus 4.8 → Opus 5 across skills and agents — SKILLS-068 (#250)

  Repins the 9 components that were on the superseded `claude-opus-4-8`: agents `business-analyst`, `code-reviewer`, `quality-guard`, `security-auditor`, and skills `brainstorm`, `create-proposal`, `create-requirements`, `implement`, `troubleshoot`.

- **models**: pin `/meeting` to `claude-opus-5` — SKILLS-068 (#252)

  `/meeting` shipped in #248 carrying the bare alias `model: opus`, which matched neither the #250 sweep nor the A3 validator glob. Every shipped skill and agent now uses a pinned model ID.

- **todo**: track deferred model-version drift prevention — SKILLS-068 (#251)

  Records the drift-prevention work deferred out of #250: a model catalog as single source of truth, validator hardening to fail on superseded IDs, CI trigger coverage for `.claude/**` and `docs/**`, and generated tier tables with a drift check.

- **todo**: file the `/work-status` `updates[]` lock race — SKILLS-000 (#249)

  `/work-status --update` writes `state.json` without the `flock` guard `/update-context` uses, so a concurrent `auto-context.sh` hook write can drop an `updates[]` entry. Narrow window; filed as correctness hygiene.

### Documentation

- New workflow guide at `docs/workflows/meetings/README.md`; `/meeting` added to `docs/skills.md` and the workflows index.
- Skill count updated 31 → 32 across `README.md`, `CLAUDE.md`, and `docs/installation.md`.

### Validation

`scripts/validate.sh` — 302 passed, 0 failed. No new warnings.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.17.0...v1.18.0

## [1.17.0] - 2026-07-19

## What's Changed

1 commit since v1.16.8 (1 feat). No breaking changes. A minor release that makes `/update-documentation` session-aware, so doc updates can reflect decisions discussed during a session — gated by whether the code actually implements them.

### Features

- **skills**: make `/update-documentation` Phase 1 session-aware (#245) — a new step 1.5 folds solutions discussed and agreed during the session into the doc-update scope, sourced from the current conversation and, on a `feature/<ticket>` branch, from that ticket's `state.json` `updates[]` (the notes `/update-context` persists). Every candidate passes a mandatory **code-confirmation gate**: it is documented only when the diff/working tree actually implements it. Discussed-but-not-implemented items (rejected, deferred, hypothetical) are surfaced in the summary and never documented — the code stays the arbiter. The 1.5 block is self-contained (resolves `WORK_BASE` inline) and validates the branch-derived ticket id before path use.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.16.8...v1.17.0

## [1.16.8] - 2026-07-14

## What's Changed

4 commits since v1.16.7 (3 fix, 1 test). No breaking changes. A KB-integrity and framework-correctness maintenance release hardening the git-backed knowledge-base write path, the doc-writer agent boundary, and the `/update-documentation` skill.

### Bug Fixes

- **kb**: sanctioned git-write pattern + default-branch helper — the KB-write pattern now works correctly under `git-mutation-guard.sh` (commit and push each lead their own Bash call so the credential scan and bypass WARNs engage; branch resolved inline in the push), a 3-tier `_default_branch()` resolver (symref → `ls-remote` → `master`) that no longer crashes release scripts on an offline remote, an explicit credential scan on the manifest-rebuild loop, and `NEXUS_KB_WRITE`/`SECURITY_AUDITOR_BYPASS` honest logged bypasses (#241, SKILLS-067)
- **skills**: `/update-documentation` assessment remediations — work-dir resolution via `resolve_artifact`, guarded git context, single Task stub, skip-condition ordering, scoped lead fixes (1 P2, 4 P3) (#244)
- **agents**: doc-writer git boundary + `Edit` tool + team-mode completion fallback — doc-writer now declares it has no git access (caller commits), gained `Edit` for targeted doc changes, and `/update-documentation` uses output-file existence as the completion signal (#242)

### Tests

- **skills**: add `test-team-task-tools` Layer 2 test + ADR-010 — empirically confirms no subagent receives task tools in this harness, so teammate completion must key on output files, not `TaskUpdate` (#243)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.16.7...v1.16.8

## [1.16.7] - 2026-07-12

## What's Changed

1 commit: 1 docs fix. No breaking changes.

### Documentation

- **skills**: fix stale git-operator delegation claims — SKILLS-066

The narrow-git-operator policy (mutations run inline under `git-mutation-guard.sh`; `git-operator` only for merge conflicts, complex rebases, and large-range PR body authoring) is correctly implemented in `/implement`, `/monitor-pr`, and `/troubleshoot`'s actual steps, but stale prose in all three still described the old delegate-everything convention — a model reading only those lines would spawn unnecessary agents.

`/implement`'s Purpose bullet, agent cost table, and Important Notes are rewritten; the cost table's "Phase 3,5 | Commits and PR" row was wrong on both counts — Phase 3 commits already run inline, and only Phase 5's large-range PR body authoring still uses `git-operator`. `/monitor-pr`'s Step 2 prose, comment-handling table, and Design Notes bullet now match Step 3.3's actual inline commit+push. `/troubleshoot`'s orchestration table and example session now match Phase 7's actual inline commit.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.16.6...v1.16.7

## [1.16.6] - 2026-07-11

## What's Changed

1 commit: 1 fix. No breaking changes.

### Bug Fixes

- **skills**: reconcile allowed-tools with skills' own mandatory bash — SKILLS-065

Several skills declared `allowed-tools` narrower than the bash their own mandatory blocks execute — most commonly the shared config-sourcing block (`source .../resolve-config.sh`) and the `.active-sessions` jq/flock dance — causing permission prompts on every invocation or hard blocks in headless/CI runs.

`epic` and `load-context` widen to unrestricted `Bash`, matching sibling skills that already work this way (`create-requirements`, `implement`, `troubleshoot`, `resume-work`). Twelve other skills (`pr-review`, `refactor`, `work-status`, `feedback`, `create-proposal`, `report-issue`, `brainstorm`, `add-product-knowledge`, `update-context`, `update-documentation`, `commit`, `release` and its three siblings) get specific missing patterns added instead — `source`, `jq`, `flock`, `mv`, `rm`, `touch`, `pwd`, `cat`, `grep`, `bash`, `false` — preserving their tighter scoping.

Adds an A6 validator check in `scripts/validators/skill-structure.sh` that scans each skill's fenced bash blocks and inline Context `!`command`` snippets for a fixed watchlist of commonly-missed commands, to catch regressions on this class of bug.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.16.5...v1.16.6

## [1.16.5] - 2026-07-11

## What's Changed

1 commit: 1 chore. No breaking changes.

### Chores

- **skills**: remove deprecated `install.sh` references — SKILLS-064

`install.sh` was replaced by marketplace install (`/plugin install nexus@claude-skills`), but ~21 skills still stamped a shared config-sourcing block referencing it: a comment claiming "`./install.sh` users fall back to `~/.claude`" and an error message telling users to "Install via marketplace or run `./install.sh`". Both are reworded — the comment now says "legacy local copies fall back to `~/.claude`", and the error points users to reinstall the plugin (`/plugin install nexus@claude-skills`). `configuration-init`'s "When to Use" bullet, which told users to run `install.sh` to install skills globally, now references the marketplace install command instead.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.16.4...v1.16.5

## [1.16.4] - 2026-07-11

## What's Changed

1 commit: 1 fix. No breaking changes.

### Bug Fixes

- **plugin**: fix four broken inter-skill handoffs — SKILLS-063

`/epic` writes only `spec.md` per ticket (no per-ticket `state.json`) at `$WORK_DIR/{epic-id}/{ticket-id}/`, but `/implement` advertised a flat `/implement {ticket-id}` and hard-failed on the missing state.json. Now instructs `/implement {epic-id}/{ticket-id}`, and `/implement`'s Phase 0.2 waives the state.json check (creating the feature branch fresh) when `spec.md` + parent `EPIC_PLAN.md` are present.

`/brainstorm promote` handed off `--from-brainstorm {slug} {ticket-id}`, but `/create-requirements` Stage 1.1 always re-prompted for the ticket regardless, silently dropping the trailing argument. Stage 1.1 now consumes a ticket-formatted token from `$ARGUMENTS` when present. Also removed brainstorm's blank-ticket fallback to the slug itself, which never matches the required ticket format and was guaranteed to fail validation.

`/review-plan` told users to paste revised plan text into `/implement`, which only accepts a work directory or a requirements file. Now writes the revised plan to `.claude/session-state/` and hands off the file path.

`/todo-work` passed the raw TODO item title as the `/implement` identifier, which never matches an actual `state.json`. Now checks for a matching state.json first; routes to `/create-requirements` instead when absent. Also fixes a worktree path bug (`resolve_worktree_root` already returns an absolute path; concatenating `$REPO_ROOT` onto it produced a mangled path) and gates worktree creation on the `worktree.enabled` opt-in, skipping it for the `/implement` handoff (which manages its own).

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.16.3...v1.16.4

## [1.16.3] - 2026-07-11

## What's Changed

1 commit: 1 fix. No breaking changes.

### Bug Fixes

- **plugin**: fix broken commands and unreachable loop caps — SKILLS-062

`pr-review`'s GitHub review-posting command (6R.4) was empirically broken — `-f` fields alongside `--input` were silently dropped into the query string instead of the request body, so the review summary never posted, and `event="PENDING"` isn't a valid Reviews API value. It now builds one JSON payload and omits `event` to get the intended pending-review behavior.

`monitor-pr`'s iteration cap only advanced when a fix was pushed, so a green-but-unapproved PR polled forever; it now increments every pass and adds an `awaiting_review` terminal state. Its CI poll loop (20 min) exceeded the harness's 10-minute per-call cap; reduced to a ~9-minute round with an explicit re-invoke budget. Its `EXIT` trap for tmpfile cleanup was a no-op across the loop's real lifetime and has been replaced with a persisted JSON state file plus one explicit cleanup step.

`implement`'s resume path could null out the PR target branch after the requirements→implementation state transition moved branch info under `.requirements.branches`; resume now reads that path with a fallback.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.16.2...v1.16.3

## [1.16.2] - 2026-07-11

## What's Changed

1 commit: 1 fix. No breaking changes.

### Bug Fixes

- **plugin**: fix marketplace-portability paths across skills and agents — SKILLS-061

Replaces hardcoded `~/.claude/shared|templates|agents/` prose paths (which only resolve for deprecated `install.sh` installs) with `${CLAUDE_PLUGIN_ROOT}`-first resolution across 13 skills, 5 agents, and `plugin/CLAUDE.md`. Extracts the manifest envelope/upsert contract into `plugin/shared/manifest-schema.md` and repoints 10 dead `docs/manifest-system.md` links at it. Fixes `configuration-init`'s dead-end where a missing template forced marketplace users toward `install.sh` with no other path forward — it now warns and continues.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.16.1...v1.16.2

## [1.16.1] - 2026-07-08

## What's Changed

Updated model IDs across all plugin agents and skills to use the latest Claude models (Sonnet 5, Opus 4.8).

### Chores

- **models**: Upgrade Sonnet 4.6 → Sonnet 5 and Opus 4.7 → Opus 4.8 across 20 agents and 31 skills

**Full Changelog**: https://github.com/nexus-a1/claude-skills/compare/v1.16.0...v1.16.1

## [1.16.0] - 2026-05-28

## What's Changed

4 commits: 1 feature addition, 1 fix, 2 docs updates. Ships SKILLS-059 (hook runtime profiles and kill-switch) on top of v1.15.0.

### Features

- **hooks**: Add `NEXUS_HOOK_PROFILE` (full/minimal/off) and `NEXUS_DISABLED_HOOKS` kill-switch to all 7 hooks. Safety hooks (git-mutation-guard, validate-commit) warn loudly when bypassed via env vars or profile setting (SKILLS-059). Bash hooks now strip whitespace from hook names in disabled list, matching Python behavior.

### Bug Fixes

- **hooks**: Strip whitespace from `NEXUS_DISABLED_HOOKS` in bash case match — `NEXUS_DISABLED_HOOKS="notify, audit"` now correctly disables audit in all 5 bash hooks

### Documentation

- **shared**: New `plugin/shared/hook-profiles.md` — full reference with hook catalogue, common scenarios, and safety notes
- **CLAUDE.md**: Added Hook Management section with quick-ref table for env vars

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.15.0...v1.16.0

## [1.15.0] - 2026-05-28

## What's Changed

12 commits: 6 feature additions, 4 fixes, 3 docs updates, 1 test. Ships three ECC P2 quick wins and follows up on the meta-security audit (SKILLS-056 from v1.14.0).

### Features

- **rules**: Add strategic-compaction guidance to workflow.md (SKILLS-057) — clarifies when to compact context, what survives, and practical implications
- **security**: Add plugin self-security audit mode to security-auditor + deep config checks 27-31 to healthcheck (SKILLS-056)
- **validators**: Add E-series config-security CI validator for remote-pipe-to-shell, unpinned versions, eval-on-external-input checks (SKILLS-056)
- **validators**: Add C5c config-audit reference integrity check (SKILLS-056)
- **healthcheck**: Enable config-security checks 27-31 in deep mode (SKILLS-056)

### Bug Fixes

- **review**: Address three automated review findings (SKILLS-058)
- **validators**: Handle compact and entry-on-bracket-line JSON in no-jq awk fallback (SKILLS-056)
- **validators**: Handle eval-in-comment + no-jq mcpServers edge cases (SKILLS-056)
- **validators**: Harden config-security no-jq fallback + add regression tests (SKILLS-056)

### Governance & Documentation

- **governance**: Add CONTRIBUTING.md with Skill Adaptation Policy, direct-port review habit, and Supply-Chain Guard checklist (SKILLS-058)
- **pr-review**: Add Supply-Chain Review section for human judgment calls validator cannot catch (SKILLS-058)
- **agents**: Document security-auditor config-audit mode (SKILLS-056)

### Testing

- **validators**: Make config-security regression tests sound (SKILLS-056)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.14.0...v1.15.0

## [1.14.0] - 2026-05-27

## What's Changed

This release completes all Phase 1 items from the ECC (Evaluating Claude Code) assessment. 10 commits: 5 new features, 3 fixes, 1 docs, 1 test. No breaking changes.

### Features

- **security**: agent-config & plugin self-security audit (meta-security) — SKILLS-056
- **healthcheck**: add config-security checks 27–31 to deep mode — SKILLS-056
- **validators**: add E-series config-security CI validator — SKILLS-056
- **validators**: add C5c config-audit reference integrity check — SKILLS-056
- **security**: add config-audit mode to security-auditor — SKILLS-056

### Bug Fixes

- **validators**: address automated review findings (E2 eval-in-comment + E4 no-jq mcpServers) — SKILLS-056
- **validators**: handle compact and entry-on-bracket-line JSON in no-jq awk fallback — SKILLS-056
- **validators**: harden config-security no-jq fallback + add tests — SKILLS-056

### Other Changes

- **docs**: document security-auditor config-audit mode — SKILLS-056
- **test**: make config-security regression tests sound — SKILLS-056

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.13.0...v1.14.0

## [1.13.0] - 2026-05-26

# Release v1.13.0

## What's Changed

20 commits: 11 features, 7 fixes, 1 docs. Complete implementation of ECC assessment P0–P4 (security baselines for prompt injection, stale-context replay, subagent retrieval discipline, acceptance-criteria-as-graders framework, and cross-reference validation). No breaking changes.

### Features

**Security & Defense** (SKILLS-052):
- **shared**: Prompt-injection defense baseline for ingestion agents (9 agents protected) — [`plugin/shared/prompt-defense.md`](https://github.com/nexus-a1/claude/blob/master/plugin/shared/prompt-defense.md)
- **agents**: Wire prompt-injection defense into context-builder, archaeologist, business-analyst, code-reviewer, security-auditor, product-expert, aws-architect, archivist, database-analyst, integration-analyst agents
- **validators**: Add C5 shared-reference-integrity checks for cross-file references

**Protocol & Discipline** (SKILLS-053 & SKILLS-054):
- **shared**: Stale-context replay guard (historical reference framing + 6 rules) — [`plugin/shared/replay-guard.md`](https://github.com/nexus-a1/claude/blob/master/plugin/shared/replay-guard.md)
- **shared**: Subagent-context discipline (iterative retrieval with 3-cycle hard cap) — [`plugin/shared/subagent-context-discipline.md`](https://github.com/nexus-a1/claude/blob/master/plugin/shared/subagent-context-discipline.md)
- **skills**: Wire dispatch-site anchors for stale-context guard (`/load-context`, `/resume-work`) and subagent discipline (`/create-requirements`, `/troubleshoot`, `/refactor`)

**Quality & Evaluation** (SKILLS-055):
- **shared**: Eval concepts grader taxonomy (code/rule/model/human evidence types + reliability vocabulary) — [`plugin/shared/eval-concepts.md`](https://github.com/nexus-a1/claude/blob/master/plugin/shared/eval-concepts.md)
- **agents**: Grader-tag ACs in business-analyst (marks evidence type for each AC); cite AC IDs in quality-guard gates
- **skills**: Per-AC PASS/FAIL eval reporting in `/implement` (Phase 4.5) and `/troubleshoot --spec` (Phase 6.3); grader-tag slot in AC template (`/create-requirements`)

### Bug Fixes

- **troubleshoot**: Harden `--spec` parser (quote-aware, handles paths with spaces) — QA gate GATE 2 fix
- **docs**: Add `replay-guard.md` to plugin/shared tree in CLAUDE.md reference
- **docs**: Add docs/workflows/release/ to CLAUDE.md tree
- **docs**: Add docs/assets/ to CLAUDE.md tree
- **pr-review**: Address three post-PR review findings (prompt-defense snippet self-sufficiency)
- **review**: Make prompt-defense snippet self-sufficient for AC-SEC-2/6
- **docs**: Resolve healthcheck WARNs (missing assets/ and workflows/release/ tree nodes)

### Documentation & Reference Updates

- **docs**: Note grader-tagging and per-AC eval reporting in agents.md and skills.md references

## Deployment Notes

### New Files (Installation Required)

All new shared files are installed to `~/.claude/shared/` by the marketplace:
- `plugin/shared/prompt-defense.md` — 7 defense rules; required for all ingestion agents
- `plugin/shared/replay-guard.md` — 6 replay-guard rules; required for `/load-context` and `/resume-work`
- `plugin/shared/subagent-context-discipline.md` — iterative retrieval protocol; required for `create-requirements`, `implement`, `troubleshoot`, `refactor`
- `plugin/shared/eval-concepts.md` — grader taxonomy and reliability vocabulary; referenced by `quality-guard` agent and per-AC eval reports

### Modified Agents & Skills

- **Agents**: business-analyst (grader-tag instruction), quality-guard (AC-ID citation)
- **Skills**: `/create-requirements` (AC template), `/implement` (per-AC eval reporting), `/troubleshoot` (`--spec` opt-in per-AC section)

### Validation

All 261 validators (A/B/C series) pass. Cross-reference integrity (C5) enforced for new shared files.

---

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.12.0...v1.13.0

## [1.12.0] - 2026-05-25

## What's Changed

5 commits: 2 features, 2 fixes, 1 chore. No breaking changes.

### Features

- **update-context**: make /update-context session-aware
- **update-context**: session-aware /update-context + repo-wide session-id fix

### Bug Fixes

- **session**: key .active-sessions map by the session id the runtime actually injects
- **update-context**: address PR review comments

### Other Changes

- [SKILLS-051] chore(cleanup): deprecate install.sh references in CLAUDE.md and update-context

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.11.0...v1.12.0

## [1.11.0] - 2026-05-24

## What's Changed

1 commit: 1 feat. No breaking changes.

### Features

- **release**: Fetch remote tags before version recommendation — ensures version suggestions are based on the authoritative tag set, not stale local tags. Includes markers to warn users when fetches fail or when offline. See PR #225 for details.

**Full Changelog**: https://github.com/anthropics/claude-code/compare/v1.10.0...v1.11.0

## [1.10.0] - 2026-05-24

## What's Changed

6 commits: 2 features, 2 bug fixes, 2 maintenance commits. No breaking changes.

### Features

- **quality-guard**: Independent-first review mode where the contrarian reviewer traces code paths first, then reconciles agent findings. Terminal review pass lifts output-ceiling to report all severity levels (BLOCKING/IMPORTANT/ADVISORY). Prevents suppressed medium/low findings that slip through intermediate passes.
- **implement + pr-review**: Architect agent is now conditionally gated into post-implementation code review when structural changes are detected (module/boundary changes, shared/core services, new DI patterns, public interface changes, etc.). Validates built code against the Phase 2 plan and flags design-drift before PR.

### Bug Fixes

- Replace stale "ALL THREE agents" references with "the QA agents" (agent-count-agnostic as architect joins optionally)
- Fix stale "four QA files" prose that didn't account for architect's conditional output file

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.9.0...v1.10.0

## [1.9.0] - 2026-05-24

## What's Changed

1 commit since v1.8.11: 1 feat. No breaking changes.

### Features

- **todo-work**: hand off directly via Skill tool instead of printing a slash-command string, enabling seamless invocation of `/review-plan` or `/implement` from within the todo-work flow — SKILLS-000

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.11...v1.9.0

## [1.8.11] - 2026-05-24

## v1.8.11

**1 fix**: resolve origin-first branch resolution to defeat stale local refs in release workflows.

### Bug Fixes

- **release**: Resolve `origin/<ref>` first to prevent stale local refs from masking upstream state. Fixes false "No commits to release" errors when a local release branch is behind the remote. ([#49](https://github.com/nexus-a1/claude-skills/issues/49))

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.10...v1.8.11

## [1.8.10] - 2026-05-06

## What's Changed

1 commit since v1.8.9: 1 docs. No breaking changes.

### Other Changes

- **assessments**: evaluate Garry Tan plan-mode patterns (#220)

**Full Changelog**: https://github.com/nexus-a1/claude-skills/compare/v1.8.9...v1.8.10

## [1.8.9] - 2026-05-01

## What's Changed

### Performance
- drop Step 1 re-runs of resolve-latest-release (#218) - Reduces token spend in release skill workflow by skipping redundant resolve-latest-release invocations

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.8...v1.8.9

## [1.8.8] - 2026-05-01

## What's Changed

### Performance
- Strip rendered command strings from plan JSON (#217)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.7...v1.8.8

## [1.8.7] - 2026-05-01

## What's Changed

1 commit: 1 perf. No breaking changes.

### Performance

- **release**: cap commits-data output and drop full sha — reduces token waste in release notes generation by eliminating redundant full commit SHAs.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.6...v1.8.7

## [1.8.6] - 2026-05-01

## What's Changed

### Performance
- Trim pr-merge --plan output for token cost (#215)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.5...v1.8.6

## [1.8.5] - 2026-05-01

## What's Changed

1 commit: 1 performance improvement

### Performance
* f06bf26 [SKILLS-000] perf(monitor-pr): trim runtime token cost so skill stays under 200k

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.4...v1.8.5

## [1.8.4] - 2026-05-01

## What's Changed

### Bug Fixes
- **fix(skills)**: Fetch origin target before PR description generation ([8e1ee30](https://github.com/nexus-a1/claude/commit/8e1ee30a6c29687ae2f5c4c9ea96b68a059ce76c))

Ensures commit ranges for PR bodies reflect current upstream state, not stale local refs. Fixes `/create-release`, `/implement`, and `pr-create.sh` to fetch the target branch before computing commit deltas.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.3...v1.8.4

## [1.8.3] - 2026-04-29

## What's Changed

### Bug Fixes
- [SKILLS-000] fix(release): single-JSON apply + clean MERGED blocking_issues

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.2...v1.8.3

## [1.8.2] - 2026-04-29

## What's Changed

### Bug Fixes
- Restore single-digit ticket support + fix test assertions
- Split compound context cmd + strengthen base-branch test
- Fetch remote tags at skill load + fix cached tag check
- Tighten ticket regex + add --base-branch to version-suggest

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.1...v1.8.2

## [1.8.1] - 2026-04-29

## What's Changed

This patch release includes shell library refactoring, quality improvements, and bug fixes across the release management skills.

### Release Engineering
- **Shell Library Migration** — All three release skills (`/create-release-branch`, `/create-release`, `/merge-release`, `/release`) converted to shell-backed dispatchers. This consolidates release logic into reusable, testable shell scripts.
- **Bug Fixes** — Corrected version suggestion base-branch handling, fixed duplicate "release/" prefix in error messages, hardened permission validation for security.

### Testing & Quality
- **Integration Tests** — Fixed invalid jq syntax in pr-merge test assertions.
- **CI Linting** — Resolved shellcheck warnings (SC2034, SC2317, SC1091) across scripts.
- **Ticket Extraction** — Made commit ticket pattern matching case-insensitive.

### Documentation
- **Release Workflow Guide** — Added comprehensive `docs/workflows/release/README.md` with step-by-step process and architecture diagram.
- **Scripts Reference** — Updated documentation to list all shell scripts and their roles.

### Security
- **Input Validation** — Tightened permission glob in release scripts to require `--` prefix for safety.
- **PII/Sensitive Data** — Hardened `report-issue` skill to prevent accidental sensitive data exfiltration.

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.8.0...v1.8.1

## [1.7.1] - 2026-04-25

## What's Changed

### Security
- **report-issue skill hardening** — Added deterministic bash grep gate that hard-blocks `gh issue create` on high-confidence secret prefixes (AWS/GitHub/Slack/Stripe/Anthropic/OpenAI/Google). Strengthened LLM sensitivity check with explicit pattern catalog and fixed bypass paths (Additional Notes, issue title). Pre-marketplace validation.

### Features
- **create-requirements & epic: Spec-Driven Development** — Requirements now include structured success criteria, acceptance tests, and implementation spec inline. Epic decomposition auto-validates against spec.

### Bug Fixes
- Prevent pr-review crash in non-git CWD
- Surface CWD in create-release-branch preflight

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.7.0...v1.7.1

## [1.8.0] - 2026-04-25

## What's Changed

### Features
- Adopt Spec-Driven Development for /create-requirements and /epic (#205) — Restructured requirements output into canonical spec.md, plan.md, and tasks.md for clearer audience separation (product/technical/execution), improved downstream consumption, and better artifact traceability in the knowledge base.

### Bug Fixes
- Surface CWD in create-release-branch preflight (#204) — Improved error messaging to show working directory context when validation fails.

**Full Changelog**: https://github.com/nexus-a1/claude-skills/compare/v1.7.0...v1.8.0

## [1.7.0] - 2026-04-24

## What's Changed

### Features
- `/todo-work`: create isolated worktree before handoff (#202)
- `/release`: add `--fasttrack` flag (#203)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.6.3...v1.7.0

## [1.6.4] - 2026-04-24

## What's Changed

### Features
- Add `--fasttrack` flag to `/release` skill for non-interactive releases by @nexus-a1 in #203

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.6.3...v1.6.4

## [1.6.3] - 2026-04-24

## Bug Fixes

- Prevent pr-review crash in non-git CWD (#201)
- Ground next-version suggestion in current repo (#200)

**Full Changelog**: https://github.com/nexus-a1/claude-skills/compare/v1.6.2...v1.6.3

## [1.6.2] - 2026-04-24

## What's Changed

### Bug Fixes
- [SKILLS-000] fix(release): enforce version-only GitHub release title

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.6.1...v1.6.2

## [1.6.1] - 2026-04-24

## What's Changed

### Features
- Enforce {TICKET}-{slug} work directory naming convention across skill ecosystem
- Add /add-product-knowledge skill for enriching product context
- Integrate playwright-engineer into /implement Phase 4 QA
- Add migrate mode for legacy configuration formats in /configuration-init

### Refactoring
- Extract conditional sections to references for better maintainability
- Refactor /implement worktree setup and auto-fix loop
- Code structure improvements across skills

### Documentation
- Add skill composition guidance to principles
- Document work directory naming convention in CLAUDE.md
- Clarify /implement consumes identifiers from /create-requirements
- Defer knowledge-sync workflow (ADR 008)

### Fixes
- Correct circular variable definitions in epic skill
- Address code review findings and template inconsistencies
- Align product-knowledge category with documentation
- Add missing allowed tools (xargs/basename/sort)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.6.0...v1.6.1

## [1.6.0] - 2026-04-23

## What's Changed

### Features
• [SKILLS-000] feat(skills): add /add-product-knowledge skill
• [SKILLS-000] feat(configuration-init): add migrate mode for legacy formats (#193)
• [SKILLS-000] feat(skills): integrate playwright-engineer into /implement Phase 4 QA (#3)

### Bug Fixes & Improvements
• [SKILLS-000] fix(docs): align add-product-knowledge category with docs/skills.md
• [SKILLS-000] fix(skills): add missing xargs/basename/sort to allowed-tools
• [SKILLS-000] refactor(skills): use resolve_artifact_typed in add-product-knowledge
• [SKILLS-000] fix(skills): address code review findings for add-product-knowledge
• [SKILLS-000] refactor(skills): extract conditional sections to references/ for create-requirements and create-proposal
• [SKILLS-000] refactor(implement): extract worktree setup and auto-fix loop to references (#2)

### Documentation
• [SKILLS-000] chore(docs): archive deep-dive assessment and record won't-do decisions
• [SKILLS-000] docs(principles): add skill composition guidance (#10)
• [SKILLS-000] docs(decisions): defer knowledge-sync workflow via ADR 008 (#5)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.5.4...v1.6.0

## [1.5.4] - 2026-04-23

## What's Changed

### Documentation
- docs(assessment): mark item #9 done — output caps already landed
- docs(assessment): correct hook count 8→9 per review
- docs(skills): cross-link /work-status and /update-context scopes (#187)

### Testing
- test(hooks): add coverage for credential-scan and git-mutation-guard (#188)

### Other Changes
- Deep-dive assessment + merge /local-pr-review into /pr-review --local (#186)

**Full Changelog**: https://github.com/anthropics/claude-skills/compare/v1.5.3...v1.5.4

## [1.5.3] - 2026-04-23

## What's Changed

### Features
- Rename `/status` to `/work-status` and add lifecycle tracking — sessions now support explicit `ready_to_implement` → `in_progress` → `qa_ready` → `qa` → `done` states with optional `--update` and `--sync` modes (#184)

### Bug Fixes
- Ship logo inside plugin so marketplace README renders correctly (#185)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.5.2...v1.5.3

## [1.5.2] - 2026-04-22

## What's Changed

### Features
- feat(release): centralize release terminology and latest-release resolution (#183)

### Bug Fixes
- fix(skills): feedback resolves identifier from disk only, confirms with user (#182)
- fix(skills): cap todo-work pick list at 3 items + Cancel (#180)

### Documentation
- docs(skills): clarify load-requirements scope, point at load-context for in-flight tickets (#181)

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.5.1...v1.5.2

## [1.5.1] - 2026-04-22

## What's Changed

### Bug Fixes
* dcb7a28 [EXT-15709] fix(plugin): apply process improvements from EXT-15709 feedback (#179)

### Maintenance
* a4de5e2 [SKILLS-000] chore(license): set copyright holder to Michal Traczewski
* d41a4bc [SKILLS-000] chore(repo): update references after migration to nexus-a1

**Full Changelog**: https://github.com/nexus-a1/claude/compare/v1.5.0...v1.5.1

## [1.5.0] - 2026-04-18

## What's Changed

### Features
- 2f0062d [SKILLS-006] feat(skills): complete auto-context sentinel plumbing (PR 2) (#176)
- 35529f2 [SKILLS-006] feat(hooks): auto-update ticket context via opt-in PostToolUse hook (#175)
- 33a4b2b [SKILLS-000] feat(skills): list all pending TODO items inline in /todo-work
- ceda362 [SKILLS-000] feat(plugin): pin explicit model versions across skills and agents (#172)

### Improvements
- 72a1446 [SKILLS-000] refactor(git): hook-first git mutations, narrow git-operator

### Bug Fixes
- c7e89a8 [SKILLS-000] fix(ci): address code reviewer suggestions in TODO.md
- de792ee [SKILLS-000] fix(hooks): replace python3 with grep, drop misleading allowlist entry
- 15528ee [SKILLS-000] fix(commit): correct credential-scan bypass instruction
- 4f5858c [SKILLS-000] fix(hooks): address review findings from PR #173

### Other Changes

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.4.4...v1.5.0

## [1.4.4] - 2026-04-17

## What's Changed

### Features
- Work-issue worktree isolation + /create-requirements hand-off (#170)

### Bug Fixes
- Stop /todo Step 6 from failing when user adds details (#169)

### Other Changes
- Replace todo-work clipboard step with inline hand-off proposal (#171)

**Full Changelog**: https://github.com/traczewskim/claude-skills/compare/v1.4.3...v1.4.4

## [1.4.3] - 2026-04-16

## What's Changed

### Features
- Add A5/context-bash-safety validator check to skill-structure — catches compound operators and bare git commands in !`...` Context patterns before they reach users

### Bug Fixes
- Harden Context bash in 4 remaining skills against non-git CWD and compound operators (local-pr-review, release, commit, create-release-branch)
- Complete hardening of merge-release skill with pre-flight check

## Scope

This release completes the proactive hardening sweep following issues #32, #34, #38, #39, #41, and #42. Added A5 validator prevents recurrence.

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.4.2...v1.4.3

## [1.4.2] - 2026-04-16

## What's Changed

### Bug Fixes
- **fix(skills):** Add exit-0 fallbacks to create-release Context commands (#165) — Completes SKILLS-039 by adding `|| echo "..."` fallbacks to all Context bash commands in `/create-release`, ensuring the skill loads even when git commands exit non-zero in certain environments (e.g., monorepo subdirectories).

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.4.1...v1.4.2

## [1.4.1] - 2026-04-16

## Bug Fixes

- **[SKILLS-038]** fix(skills): handle non-git CWD in create-release-branch — frontmatter git commands now gracefully fall back when invoked from a non-git directory (e.g., monorepo root), with a pre-flight check guiding users to cd into the service repo
- **[SKILLS-039]** fix(skills): handle non-git CWD in create-release — same fix applied to /create-release skill for consistency with sibling release workflow skills

## What's Changed

Both skills now detect when the current working directory is not a git repository and provide actionable error messages instead of crashing with `fatal: not a git repository`. This enables running skills in monorepo environments where the user may be in a non-git parent directory.

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.4.0...v1.4.1

## [1.4.0] - 2026-04-15

## What's Changed

### Features
- **New skill `/review-plan`** — pre-implementation design review via architect + quality-guard (and optionally security-auditor with `--security` or keyword heuristic). Produces findings report + revised plan for paste into `/implement`. ([#161](https://github.com/traczewskim/claude/pull/161))
- **New skill `/todo-work`** — companion to `/todo`: lists pending items from `TODO.md`, lets you pick one, flips it to `In progress`, and prints a ready-to-paste `/review-plan` or `/implement` invocation (clipboard copy when available). ([#162](https://github.com/traczewskim/claude/pull/162))

### Bug Fixes
- **`/monitor-pr` Step 2** — inlined local checkout alignment to avoid unnecessary subagent spin-up (~17k tokens saved per invocation) while preserving `--ff-only` safety. ([#160](https://github.com/traczewskim/claude/pull/160))

### Plugin surface
- Skill count: 30 → 31 active (project-local stays at 3)
- Agent count unchanged (20)

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.3.0...v1.4.0

## [1.3.0] - 2026-04-15

## What's Changed

### Features
- **Output Discipline**: Enforce output size caps across 12 agents with dual-save state files containing distilled summaries
- **Phase-Boundary Summarization**: Implement automatic summarization in /implement and /create-requirements pipelines
- **Credential Scanning**: Add content scan for credentials before staging changes
- **--light Mode**: Add --light mode to create-proposal for reduced token usage
- **Plugin Distribution**: Source resolve-config.sh from ${CLAUDE_PLUGIN_ROOT} for marketplace compatibility
- **Visual Branding**: Add claude-skills logo to README header

### Bug Fixes
- Fix compound shell patterns in release skill and create-release-branch
- Sharpen git-operator task discipline to prevent off-task drift
- Remove unsupported push trigger from healthcheck workflow
- Fix README logo visibility and relative paths
- Expand git-operator allow list with explicit per-command entries

### Other Changes
- Add .claude/worktrees artifacts to gitignore
- Add direction log for tracking ongoing initiatives
- Improve README styling and professional presentation

**Full Changelog**: https://github.com/traczewskim/claude-skills/compare/v1.2.0...v1.3.0

## [1.2.0] - 2026-04-10

## What's New

### Features
- **`/monitor-pr`** — New skill to shepherd open PRs: polls CI, surfaces review comments, and posts status updates automatically (SKILLS-022)
- **`/load-context` handoff** — `/resume-work` and `/implement` now hand off to `/load-context` for richer context loading on session resume (SKILLS-022)

### Fixes
- **git-operator enforcement** — `git-mutation-guard.sh` hook now blocks all mutations unless run via `git-operator` agent with `GIT_AUTHORIZED=1`. Covers `rm`, `mv`, `restore`, `clean`, long-form tag flags, and anchors bypass regex to start of command (SKILLS-024)
- **monitor-pr hardening** — Handles stale comments, exit-8 edge cases, and orphan polls (SKILLS-025)
- **Hook regex anchoring** — Mutation regexes now anchored to prevent false positives on `grep`/`cat` commands containing git substrings (SKILLS-027)
- **Test exit codes** — `run-tests.sh` now correctly propagates non-zero exit codes in non-verbose mode (SKILLS-026)
- **git-operator token efficiency** — Quiet flags added throughout to reduce verbose output (SKILLS-023)

### Documentation
- git-operator: `GIT_AUTHORIZED=1` list now includes `git rm`, `mv`, `restore`, `clean` (SKILLS-028)
- `plugin/CLAUDE.md` delegation table updated with all mutation commands
- `docs/agents.md`, `docs/installation.md`, `plugin/hooks/git-mutation-guard.sh` header comments synced (SKILLS-029)
- `plugin/skills/brainstorm/README.md`: documented `--light` flag and `promote` subcommand

### CI
- Healthcheck workflow now triggers on `push: branches: [master]` — badge in README stays green after merges (SKILLS-029)
- Added git-operator agent tests: output minimization and `GIT_AUTHORIZED=1` co-convention (SKILLS-024)

## [1.1.6] - 2026-04-08

## What's Changed

### Features
- Add /work-feedback project-local skill and feedback reports (#129)

### Bug Fixes
- Rename debug skill to troubleshoot to avoid native command conflict (#128)
- Rename context skill to load-context to avoid native command conflict (#125)
- Rewrite `gh pr view` to use --json to dodge projectCards GraphQL deprecation (#122)
- Quote argument-hint values to prevent YAML list parsing (#124)

### Documentation
- Clarify worktree isolation is opt-in (default off) (#123)
- Clarify git-operator delegation boundaries with explicit allow/delegate table (#121)

**Full Changelog**: https://github.com/anthropics/claude-skills/compare/v1.1.5...v1.1.6

## [1.1.5] - 2026-04-04

## What's Changed

### Bug Fixes
- [SKILLS-014] fix(skills): delegate git mutations to git-operator in create-requirements, local-pr-review, rebuild-requirements-index (#120)

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.1.4...v1.1.5

## [1.1.4] - 2026-04-04

## What's Changed

### Features
- Add /work-issue project-local skill (#116)
- Make /work-issue autonomous with full PR cycle (#117)

### Bug Fixes
- Add Bash(yq:*) to update-context allowed-tools (#118)
- Prevent git commit in /context Phase 3 for multi-repo workspaces (#119)

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.1.3...v1.1.4

## [1.1.2] - 2026-04-02

## Bug Fix

- **fix(implement):** Delegate all git mutation operations to git-operator agent (#114, fixes nexus-a1/claude-skills#8)
  - Phase 0.2: `git checkout` → git-operator delegation
  - Phase 5.1: `git push` → git-operator delegation
  - Phase 5.3: `gh pr create` → git-operator delegation
  - Clarified delegation rule in Important Notes (read-only checks and worktree ops remain inline)

## [1.1.1] - 2026-04-02

## Bug Fix

### Fix YAML frontmatter rendering on GitHub

Quoted `allowed-tools` values containing colons (e.g., `Bash(jq:*)`) in 17 skill frontmatter blocks. GitHub's YAML parser rejected unquoted colons as invalid mapping syntax, causing `Error in user YAML` when viewing SKILL.md files on GitHub.

No behavioral change — Claude Code receives the identical parsed value with or without quotes.

### Full Changelog
https://github.com/traczewskim/claude/compare/v1.1.0...v1.1.1

## [1.1.0] - 2026-04-02

## What's New

### Project-agnostic git worktree isolation

Code-modifying skills (`/implement`, `/debug`, `/refactor`) can now operate in isolated git worktrees, keeping your working tree clean and enabling parallel work on multiple tickets.

**Zero-config auto-detection:**
- Inside a git repo → single-repo mode (uses `EnterWorktree`/`ExitWorktree`)
- Plain directory with git repos as subdirs → multi-repo mode (per-service worktrees via `git worktree add`)

**Opt-in via configuration:**
```yaml
# .claude/configuration.yml
worktree:
  enabled: true
```

**Multi-repo workspace support:**
```
main_dir/
├── .worktrees/TICKET-123/    ← isolated workspace per ticket
│   ├── service1/             ← git worktree
│   └── service2/             ← git worktree
├── service1/                 ← original (untouched)
└── service2/
```

### Changes

- **`resolve-config.sh`**: Added `WORKSPACE_ROOT` anchoring, `WORKSPACE_MODE` auto-detection, worktree helpers, service helpers. All artifact paths now resolve correctly from inside worktrees.
- **`/implement`**: Worktree entry in Phase 0, exit after PR creation, state.json tracking, multi-repo cleanup hint
- **`/debug`**: Worktree entry in Phase 0, auto-removed after commit
- **`/refactor`**: Worktree entry before applying fixes
- **`/resume-work`**: Re-enters worktrees from state.json metadata
- **21 skills**: Synced `BEGIN_SHARED` inline blocks with workspace-aware `resolve-config`
- **Configuration template**: Added `worktree` and `workspace` sections
- **Documentation**: Full reference in `docs/configuration.md`

### Full Changelog
https://github.com/traczewskim/claude/compare/v1.0.7...v1.1.0

## [1.0.7] - 2026-03-31

## Bug Fixes

- Harden release skill `git fetch` shell interpolation with `|| true` guard — prevents skill from aborting at load time when fetch fails (network unavailable, no remote configured, etc.)

**Closes:** nexus-a1/claude-skills#4, nexus-a1/claude-skills#5

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.0.6...v1.0.7

## [1.0.6] - 2026-03-31

## What's Changed

### Bug Fixes
- [SKILLS-000] fix(skills): surface non-label errors in report-issue stderr handling

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.0.5...v1.0.6

## [1.0.5] - 2026-03-31

## What's Changed

### Bug Fixes
- [SKILLS-000] fix(skills): handle git fetch failure in release skill context
- [SKILLS-000] fix(hooks): prevent CRLF line endings in distributed scripts
- [SKILLS-000] fix(ci): remove legacy plugin publish job

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.0.4...v1.0.5

## [1.0.4] - 2026-03-31

## What's Changed

### Features
- feat(skills): add `/nexus:report-issue` skill — draft and submit bug reports or feature requests to the nexus repo using current conversation context, with sensitivity check and confirmation step

### Bug Fixes
- fix(plugin): prevent namespace prefix on agent invocations — stops Claude from incorrectly prepending `nexus:` to agent names (e.g. `nexus:git-operator`), causing "unknown skill" errors
- fix(plugin): remove hardcoded hook paths from `settings.json` — fixes "notify.sh not found" errors on Stop events for marketplace plugin installs

### Other Changes
- chore(plugin): migrate all references from traczewskim to nexus-a1

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.0.3...v1.0.4

## [1.0.3] - 2026-03-30

## What's Changed

### Bug Fixes
- fix(plugin): prevent namespace prefix on agent invocations — Claude was prepending `nexus:` to agent names (e.g., `nexus:git-operator`) in plugin context, causing "unknown skill" errors. Added explicit CLAUDE.md instruction to always use plain agent names.

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.0.2...v1.0.3

## [1.0.2] - 2026-03-30

## What's Changed

### Bug Fixes
- fix(plugin): remove hardcoded hook paths from settings.json — fixes "notify.sh not found" error on Stop events for marketplace plugin installs

### Other Changes
- chore(plugin): migrate all references from traczewskim to nexus-a1
- move git status/diff into git-operator, simplify commit skill

**Full Changelog**: https://github.com/traczewskim/claude/compare/v0.1.0-rc.7...v1.0.2

## [1.0.1] - 2026-03-30

## What's Changed

### Fixes
- Migrate all plugin references from `traczewskim/claude-skills` to `nexus-a1/claude-skills` as canonical distribution repo
- Update README install instructions, marketplace.json, plugin.json, and docs/installation.md

**Full Changelog**: https://github.com/traczewskim/claude/compare/v1.0.0...v1.0.1

## [1.0.0] - 2026-03-30

## What's Changed

### Features
- Add nexus-a1/claude-skills publish job to CI
- Rename plugin namespace from `skills` to `nexus`
- Rename `/performance-feedback` to `/feedback`, add GitHub issue creation
- Add team mode support to all multi-agent skills (SendMessage cross-pollination)
- Add `quality-skeptic` agent and enhance agent collaboration
- Add validation, shared principles, `--light` mode, write safety, and cost tracking
- Add bash token-filter hook for reducing bash output tokens
- Add workflow section to doc-writer agent
- Change default execution mode from `subagent` to `team`
- Add `/performance-feedback` retrospective analysis skill
- Add output guidelines to git-operator, aws-architect, refactorer

### Bug Fixes & Improvements
- Move git status/diff into git-operator; simplify commit skill
- Fix skill count drift, shared/ tree duplicate, and C21 validator gap
- Fix plugin skills not recognized after marketplace install (marketplace.json source)
- Fix hooks: remove cargo test override, fix curl combined-flags detection
- Fix bash token-filter hook review findings
- Fix agents: use correct skill reference in archivist scope boundary
- Fix context: replace ls with Glob in artifact scan fallbacks
- Remove invalid fields from plugin.json; use GitHub source in marketplace.json

### Refactoring & Chores
- Assess all 20 agents and fix portability/quality issues (#103)
- 3-round quality audit of all 27 skills; sync README counts
- Rename add-todo skill to `todo`; rename /resume to /resume-work
- Remove stale skill excludes and fix C3 validator false positives
- Apply feedback-driven improvements (F1-F13) across agents, skills, and rules
- Frame repo as plugin factory with marketplace design constraints

**Full Changelog**: https://github.com/traczewskim/claude-skills/compare/v0.1.0-rc.7...v1.0.0
