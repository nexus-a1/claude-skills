# Requirements Repository Setup Guide

This directory contains templates for setting up a team requirements repository that works with Claude Code's archivist agent.

## What is a Requirements Repository?

A **requirements repository** is a separate Git repository where your team stores:
- Technical requirements from completed work
- Implementation decisions and rationale
- Architectural patterns used
- Lessons learned

The **archivist agent** searches this repository to find similar past work, helping your team:
- Avoid re-inventing solutions
- Reuse proven patterns
- Learn from past decisions
- Build institutional knowledge

## Repository Structure

```
requirements-repo/
├── README.md                    # Repository documentation
├── .gitignore                   # Git ignore rules
├── index.json                   # Searchable index (maintained by archivist)
├── templates/                   # Templates for manual archival
│   ├── metadata.template.json
│   └── requirements.template.md
├── PROJECT-123/                 # Individual requirement
│   ├── metadata.json            # Searchable metadata
│   ├── requirements.md          # Human-readable summary
│   ├── requirements-state.json  # Original workflow state
│   └── context/                 # Agent outputs
│       ├── discovery.json
│       ├── archivist.md
│       ├── archaeologist.md
│       ├── data-modeler.md
│       └── business-analyst.md
├── PROJECT-456/
│   └── ...
└── archive/                     # Old requirements (optional)
    └── 2025/
        └── PROJECT-100/
```

## Initial Setup

### Step 1: Create Repository

```bash
# Create new repository
mkdir requirements-repo
cd requirements-repo
git init

# Copy templates from claude-skills
cp -r /path/to/claude-skills/plugin/templates/requirements-repo/* .

# Initial commit
git add .
git commit -m "Initial requirements repository setup"

# Optional: Push to remote
git remote add origin https://github.com/your-org/requirements-repo.git
git push -u origin main
```

### Step 2: Configure in Project

Add to your project's `.claude/configuration.yml`:

```yaml
storage:
  locations:
    team-knowledge:
      type: git
      path: /absolute/path/to/requirements-repo
  artifacts:
    requirements: { location: team-knowledge, subdir: requirements }

requirements:
  auto_search: true
  auto_archive: true
  auto_load_threshold: 0.9
  max_suggestions: 3
  archive_on_pr: true
```

### Step 3: Verify Configuration

```bash
# In your project directory
claude "verify requirements repository configuration"

# Archivist agent should:
# 1. Read CLAUDE.md configuration
# 2. Verify repository path exists
# 3. Run sync command
# 4. Confirm ready for use
```

## How It Works

### During Requirements (Stage 3)

When you run `/create-requirements`:

1. **Stage 2:** context-builder analyzes current project
2. **Stage 3 (parallel):**
   - archivist searches requirements-repo for similar work
   - Other agents analyze codebase, database, APIs, etc.
3. **Stage 4:** business-analyst synthesizes current + historical context

**Archivist provides:**
- Similar past implementations
- Patterns that worked well
- Gotchas to avoid
- Related decisions

### After Implementation (Stage 9)

When you run `/implement` and create a PR:

1. Implementation completes successfully
2. Archivist offers: "Archive requirements to team repo? [y/n]"
3. If yes:
   - Extracts metadata from commits and code
   - Generates requirements.md summary
   - Copies context from `.claude/work/{id}/`
   - Updates index.json
   - Commits and pushes to requirements-repo

## Metadata Schema

See `metadata.template.json` for full schema. Key fields:

```json
{
  "id": "PROJECT-123",
  "title": "Feature title",
  "tags": ["export", "api", "excel"],
  "components": ["UserController", "ExportService"],
  "apis": {
    "added": ["POST /api/export"],
    "modified": [],
    "removed": []
  },
  "related_tickets": ["PROJECT-100"]
}
```

**Why metadata matters:**
- **Searchable:** Find similar work by tags, components, APIs
- **Discoverable:** Browse by project, date, or technology
- **Connected:** See relationships between tickets

## Index Structure

The `index.json` file enables fast search without loading all requirements:

```json
{
  "version": "1.0",
  "last_updated": "2026-02-03T10:00:00Z",
  "tickets": [
    {
      "id": "PROJECT-123",
      "title": "User export feature",
      "tags": ["export", "excel"],
      "components": ["UserController"],
      "path": "PROJECT-123/"
    }
  ],
  "tags": {
    "export": 3,
    "api": 15
  }
}
```

**Maintained by archivist:**
- Auto-updated on archive
- Can be rebuilt with `/rebuild-requirements-index`

## Search Examples

### By Keyword
```bash
/search-requirements "user export"
```

### By Tag
```bash
/search-requirements "tag:export,excel"
```

### By Component
```bash
/search-requirements "component:UserController"
```

### Combined
```bash
/search-requirements "export component:UserController after:2025-01-01"
```

## Best Practices

### 1. Consistent Tagging

Use standardized tags:
- **Domain:** `auth`, `export`, `reporting`, `billing`
- **Technology:** `api`, `database`, `queue`, `cache`
- **Type:** `feature`, `bugfix`, `refactor`, `migration`

### 2. Meaningful Descriptions

Write descriptions that help future searches:
- ❌ "Add export"
- ✅ "Add user data export to Excel with async processing"

### 3. Link Related Work

Use `related_tickets` to build knowledge graph:
```json
{
  "related_tickets": ["PROJECT-100", "PROJECT-456"],
  "dependencies": {
    "relates_to": ["PROJECT-789"]
  }
}
```

### 4. Capture Lessons Learned

In `requirements.md`, document:
- What worked well
- What didn't work
- Recommendations for similar work

### 5. Regular Maintenance

Periodically:
- Archive old requirements to `archive/YYYY/`
- Rebuild index: `/rebuild-requirements-index`
- Remove obsolete entries
- Update tags for consistency

## Archival Strategy

### When to Archive

Move requirements to `archive/` when:
- Older than 1 year
- Status = completed
- No recent references
- Feature deprecated or replaced

### How to Archive

```bash
# Manual archival
mv PROJECT-100 archive/2025/PROJECT-100

# Update index
/rebuild-requirements-index
```

**Note:** Archived requirements remain searchable but indicate historical nature.

## Troubleshooting

### Index Corrupted

```bash
/rebuild-requirements-index
```

### Can't Find Requirements

Check configuration in project CLAUDE.md:
```bash
claude "show requirements repository configuration"
```

### Search Not Working

Verify:
1. Repository path is correct
2. Sync command works
3. Index.json exists and is valid JSON
4. Metadata in requirements is well-formed

### Merge Conflicts

If multiple developers archive simultaneously:
```bash
cd requirements-repo
git pull --rebase
# Resolve conflicts in index.json
git add index.json
git rebase --continue
git push
```

## Advanced Usage

### Multiple Projects

One requirements-repo can serve multiple projects:

```yaml
# project-a/.claude/configuration.yml
storage:
  locations:
    team-knowledge:
      type: git
      path: /team/shared-requirements-repo
  artifacts:
    requirements: { location: team-knowledge, subdir: requirements }

# project-b/.claude/configuration.yml
storage:
  locations:
    team-knowledge:
      type: git
      path: /team/shared-requirements-repo
  artifacts:
    requirements: { location: team-knowledge, subdir: requirements }
```

Search filters by project automatically.

### Custom Templates

Override default templates by placing in requirements-repo root:
- `custom-metadata.json` - Custom metadata fields
- `custom-requirements.md` - Custom summary format

Archivist will use custom templates if present.

## Integration with Other Tools

### Confluence/Notion Sync

Create webhook or script to sync requirements.md to wiki:
```bash
# Example sync script
for dir in */; do
  ticket="${dir%/}"
  if [ -f "$dir/requirements.md" ]; then
    # Upload to Confluence
    confluence-cli --page "Requirements-$ticket" --file "$dir/requirements.md"
  fi
done
```

### Jira Integration

Link requirements to Jira tickets:
```json
{
  "id": "JIRA-123",
  "jira_url": "https://jira.company.com/browse/JIRA-123",
  "pr_url": "https://github.com/org/repo/pull/123"
}
```

### Analytics

Extract insights from index.json:
```bash
# Most common tags
jq '.tags | to_entries | sort_by(.value) | reverse | .[0:10]' index.json

# Components with most changes
jq '.components | to_entries | sort_by(.value) | reverse | .[0:10]' index.json

# Tickets per month
jq '.tickets | group_by(.date[0:7]) | map({month: .[0].date[0:7], count: length})' index.json
```

## Support

For issues or questions:
- Check `docs/workflows/requirements-knowledge-base.md`
- Review archivist agent: `plugin/agents/archivist.md`
- File issue in claude-skills repository

---

**Version:** 1.0
**Last Updated:** 2026-02-03
