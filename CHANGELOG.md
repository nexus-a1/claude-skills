# Changelog

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
