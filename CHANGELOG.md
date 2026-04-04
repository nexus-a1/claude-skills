# Changelog

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
