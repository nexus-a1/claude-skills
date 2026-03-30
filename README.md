# Claude Nexus Plugin

A Claude Code plugin covering the full development lifecycle — from requirements through release — with **27 skills**, **20 agents**, **16 rules**, and **4 hooks**.

## Installation

```bash
# Add the marketplace
/plugin marketplace add nexus-a1/claude-skills

# Install the plugin
/plugin install nexus@claude-skills
```

Skills are invoked with the `nexus:` namespace prefix (e.g., `/nexus:brainstorm`).

## Quick Start

```bash
/nexus:brainstorm              # Explore approaches before committing to specs
/nexus:create-requirements     # Generate detailed requirements with agent pipeline
/nexus:implement               # Implement from requirements with built-in QA
/nexus:resume-work             # Resume interrupted work
/nexus:commit                  # Commit with conventional format
/nexus:local-pr-review         # Review local changes before PR
```

## What's Included

| Component | Count | Purpose |
|-----------|-------|---------|
| Skills | 27 | Slash commands for the full dev lifecycle |
| Agents | 20 | Specialized sub-agents invoked by skills |
| Rules | 16 | Domain-specific coding standards (PHP, React, cross-cutting) |
| Hooks | 4 | Pre/post-tool automation (commit validation, audit, notifications) |

Run `/nexus:configuration-init` to configure storage locations and execution mode for your project.

## Updates

```bash
/plugin update nexus@claude-skills
```

## License

MIT
