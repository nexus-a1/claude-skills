# Changelog

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
