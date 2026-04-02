# Claude Code Guidelines

## Parallel Execution

**Always maximize parallelism for efficiency:**

- Use multiple tool calls in a single message when operations are independent
- Launch multiple Task agents simultaneously when tasks don't depend on each other
- Read multiple files in parallel when gathering context
- Run independent searches (Grep, Glob) concurrently

---

## Agent Delegation

**IMPORTANT**: Always delegate specialized tasks to agents. This improves quality and reduces context usage.

**CRITICAL — Agent name format**: Always invoke agents by their **plain name** (e.g., `git-operator`). Never use a namespace prefix like `nexus:git-operator`. Agents are resolved by plain name regardless of plugin context. Using a namespace prefix will cause an "unknown skill" error.

### Mandatory Agent Delegation

The following operations **MUST** always use their designated agents:

#### Git Operations → `git-operator`
Every time git operations are needed (commit, push, PR), delegate to the `git-operator` agent. Never run git commit/push/PR commands directly.
```
Task(git-operator, "Commit and push: {description of changes}")
Task(git-operator, "Commit, push, and create PR to {branch}: {description}")
```

**Exception:** Haiku-tier release skills (`/nexus:create-release`, `/nexus:merge-release`, `/nexus:release`) run git/gh commands directly for speed. These are simple, deterministic operations where git-operator delegation adds latency without quality benefit. `/nexus:commit` delegates staging and commit message generation to `git-operator` (which runs `git status`/`git diff` internally) but runs `git commit` directly. `/nexus:create-release-branch` delegates branch creation and push to `git-operator`.

#### Documentation → `doc-writer`
Every time documentation needs to be created or updated, delegate to the `doc-writer` agent.
```
Task(doc-writer, "Document the {feature/component} including: {details}")
```

#### Pre-Commit Security Scan → `security-auditor`
Before every commit in the implementation pipeline, run the `security-auditor` agent to ensure no sensitive data is committed.
```
Task(security-auditor, "Scan staged changes for PII and sensitive data exposure")
```

### Available Agents

#### Requirements Stage
| Agent | Use For | When to Use |
|-------|---------|-------------|
| `context-builder` | Build structured context | First step in requirements - creates inventory |
| `archivist` | Search/load past requirements | Stage 3 - finds similar historical work (runs in parallel) |
| `business-analyst` | Requirements analysis | Understanding features, consolidating findings |
| `archaeologist` | Legacy code analysis | Deep dive into specific code modules |
| `data-modeler` | Database schema analysis | When feature involves DB changes |
| `integration-analyst` | External API analysis + implementation | Requirements: API mapping; Implementation: API clients |
| `security-requirements` | Security/compliance needs | Early identification of security requirements |
| `aws-architect` | Cloud architecture | When feature involves AWS/cloud resources |
| `product-expert` | Product knowledge base | When feature involves product-specific patterns or integrations |

#### Implementation Stage
| Agent | Use For | When to Use |
|-------|---------|-------------|
| `Explore` | Codebase exploration | Finding files, understanding patterns |
| `Plan` | Implementation planning | Designing approaches, architecture decisions |
| `architect` | Architecture validation | Validating plans against architecture rules |
| `refactorer` | Apply refactoring | Making code changes for refactoring |

#### Testing Stage
| Agent | Use For | When to Use |
|-------|---------|-------------|
| `test-writer` | Write tests | After implementing features |
| `test-fixer` | Fix failing tests | When tests fail after changes |
| `playwright-engineer` | Playwright E2E tests | Writing or fixing Playwright tests, cross-browser testing |

#### Review & Deployment Stage
| Agent | Use For | When to Use |
|-------|---------|-------------|
| `quality-guard` | Adversarial validation of agent outputs | After QA agents complete — challenges findings, verifies claims, identifies gaps |
| `code-reviewer` | Code quality + performance review | After writing code, reviewing PRs |
| `security-auditor` | Security analysis + PII scanning | Reviewing auth, payments, sensitive data, **ALWAYS before commit** |
| `doc-writer` | Technical + API documentation | **ALWAYS use for documentation** |
| `git-operator` | Git operations (commit, push, PR) | **ALWAYS use for any git operation** |

#### Standalone Agents
| Agent | Use For | When to Use |
|-------|---------|-------------|
| `database-analyst` | Execute database queries & analyze data | **ALWAYS use when running database queries** - returns gist/summary only |

---

## Efficiency Rules

1. **Batch operations** - Combine related operations into single messages
2. **Parallel reads** - Read all needed files at once
3. **Parallel agents** - Run independent agents simultaneously
4. **Minimize round-trips** - Complete tasks in fewer messages
5. **Delegate expertise** - Use agents for specialized work
6. **Explore before implementing** - Use `Explore` agent to understand codebase first
7. **Review after writing** - Use `code-reviewer` agent after significant changes

---

## Installed Rules

Rules in `~/.claude/rules/` are automatically loaded based on project context.

### Cross-Cutting (always active)
| Rule | File | Purpose |
|------|------|---------|
| PR Review | `rules/pr-review.md` | Code review standards, severity levels, feedback guidelines |
| Workflow Orchestration | `rules/workflow.md` | Plan mode, subagents, self-improvement loop, verification standards |

### PHP/Symfony (active in PHP projects)
`rules/php/` — architecture, code-style, database, rest-api, security, symfony, testing

### React/TypeScript (active in React projects)
`rules/react/` — architecture, components, hooks, performance, state-management, testing, typescript

---

## Critical Thinking & Feedback

**Think critically about ideas and proposals:**

- **Challenge assumptions** - Don't automatically accept ideas at face value. Evaluate their merit objectively.
- **Question weak proposals** - If an idea lacks substance, technical grounding, or clear benefit, push back respectfully.
- **Provide reasoned pushback** - When disagreeing, explain your technical concerns and suggest alternatives.
- **Be intellectually honest** - Prioritize correctness and best practices over agreeableness.
- **Identify risks** - Point out potential issues, technical debt, or complexity that may not be obvious.

**Balance:**
- Be collaborative, not combative
- Explain the "why" behind your concerns
- Offer constructive alternatives when raising objections
- Accept valid user preferences and requirements even if you'd choose differently

---

## Project Configuration

**Purpose:** Centralized configuration for storage locations, artifact mapping, and behavior flags.

### Configuration File

Create `.claude/configuration.yml` in your project (copy from `~/.claude/templates/configuration.yml`):

```yaml
execution_mode: team

storage:
  locations:
    team-knowledge:
      type: git
      path: /path/to/team-knowledge
    local:
      type: directory
      path: .claude
  artifacts:
    requirements:      { location: team-knowledge, subdir: requirements }
    proposals:         { location: team-knowledge, subdir: proposals }
    product-knowledge: { location: team-knowledge, subdir: . }
    brainstorms:       { location: local, subdir: brainstorm }
    work:              { location: local, subdir: work }
    refactoring:       { location: local, subdir: work/refactoring-sessions }

requirements:
  auto_search: true
  auto_archive: true
  auto_load_threshold: 0.9
  max_suggestions: 3
  archive_on_pr: true
```

### Sections

**`execution_mode`** — Controls how multi-agent skills run their parallel phases. Supports two formats:

**Simple string** (applies to all phases):
```yaml
execution_mode: team   # or "subagent"
```

**Per-phase object** (granular control):
```yaml
execution_mode:
  default: team
  overrides:
    debug: subagent   # opt out specific phases if needed
```

| Value | Default | Behavior |
|-------|---------|----------|
| `"team"` | Yes | Agents run as teammates with cross-pollination via SendMessage. Higher quality. |
| `"subagent"` | No | Agents run as independent parallel tasks. Lower token cost. |

| Phase Name | Used By | Description |
|------------|---------|-------------|
| `requirements_deep_dive` | `/create-requirements` | Stage 3 parallel research agents |
| `qa_review` | `/implement` | Phase 4 QA agents (test-writer, code-reviewer, security-auditor, quality-guard) |
| `documentation_update` | `/update-documentation` | Phase 2-4 agents (context-builder, business-analyst, doc-writer) |
| `refactor` | `/refactor` | Step 5.1 quality gate loop (code-reviewer, test-writer, quality-guard) |
| `debug` | `/debug` | Phase 6 verification (security-auditor, quality-guard) |
| `local_pr_review` | `/local-pr-review` | Step 4 review agents (code-reviewer, security-auditor, quality-guard) |
| `pr_review` | `/pr-review` | Step 4 review agents (code-reviewer, security-auditor, quality-guard) |

All skills that use multiple agents support configurable execution mode (`"subagent"` or `"team"`).

**`storage.locations`** — Named storage backends. Each location has a `type` and a `path`. If `configuration.yml` is absent or a key is missing, skills/agents fall back to hardcoded defaults.

| Key | Type | Purpose |
|-----|------|---------|
| `type` | `git` or `directory` | `git` locations are synced (pull) before reads; `directory` locations are plain local paths |
| `path` | Absolute or relative path | Base path for the location. Git locations should use absolute paths. |

**`storage.artifacts`** — Maps logical artifact names to storage locations. Each artifact specifies a `location` (reference to a `storage.locations` key) and a `subdir` within that location.

| Artifact | Default Location | Default Subdir | Used By |
|----------|-----------------|----------------|---------|
| `work` | `local` | `work` | `/create-requirements`, `/implement`, `/resume-work`, `/epic`, `/create-proposal` |
| `brainstorms` | `local` | `brainstorm` | `/brainstorm` |
| `refactoring` | `local` | `work/refactoring-sessions` | `refactorer` agent |
| `proposals` | `local` | `proposals` | `/create-proposal` |
| `requirements` | `local` | `requirements` | `/archive-requirements`, `/search-requirements`, `archivist` agent |
| `product-knowledge` | `local` | `.` | `product-expert` agent |

**`requirements`** — Behavior flags for the requirements knowledge base. Optional.

| Key | Default | Purpose |
|-----|---------|---------|
| `requirements.auto_archive` | `true` | Archive after implementation |
| `requirements.auto_search` | `true` | Search during planning |
| `requirements.auto_load_threshold` | `0.9` | Auto-load high-confidence matches |
| `requirements.max_suggestions` | `3` | Maximum suggestions to show |
| `requirements.archive_on_pr` | `true` | Archive when PR is created |

**`worktree`** — Worktree isolation for code-modifying skills. Optional.

| Key | Default | Purpose |
|-----|---------|---------|
| `worktree.enabled` | `false` | Opt-in toggle; code-modifying skills work in isolated worktrees |
| `worktree.root` | `.worktrees` | Multi-repo only: where ticket workspace directories are created |

**`workspace`** — Multi-repo workspace definition. Optional.

| Key | Purpose |
|-----|---------|
| `workspace.services[].name` | Service identifier (used in worktree paths and agent context) |
| `workspace.services[].path` | Relative or absolute path to the git repo |

Workspace mode is auto-detected — no configuration needed:
- Inside a git repo → **single mode** (uses `EnterWorktree`/`ExitWorktree`)
- Plain directory with git repos as subdirs → **multi mode** (per-service worktrees via `git worktree add`)

Define `workspace.services` only to limit which repos are included. If omitted, all git repos in immediate subdirectories are auto-discovered.

### How It Works

Skills find `.claude/configuration.yml` by walking up from CWD. All relative artifact paths are anchored to the workspace root (where `configuration.yml` lives), ensuring state files resolve correctly even from inside worktrees. If absent, skills fall back to hardcoded defaults (e.g., `.claude/work`).

### Setup

Run `/nexus:configuration-init` for interactive setup, or copy `~/.claude/templates/configuration.yml` and edit manually. See `docs/configuration.md` for full reference.
