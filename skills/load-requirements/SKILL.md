---
name: load-requirements
model: claude-sonnet-4-6
category: requirements-kb
description: Load a specific archived requirement from the requirements KB for detailed review. For in-flight tickets that have not been archived yet, use /load-context instead — it also covers work sessions, brainstorms, and proposals.
argument-hint: <identifier>
userInvocable: true
allowed-tools: Read, Bash, Task, AskUserQuestion
---

# Load Requirements

Load full details of a specific archived requirement from the team's knowledge base.

> **Scope:** this skill only reads the archived requirements repository. It does not look at active work sessions, brainstorms, or proposals. If the ticket you are after has not been archived yet, use [`/load-context`](../load-context/SKILL.md) — it aggregates every artifact type (work, brainstorms, proposals, requirements KB, product knowledge, git history) into a single summary and is the right entry point for in-flight tickets.

## Purpose

View complete requirements, decisions, implementation notes, and lessons learned from past work to inform current development.

## When to Use

- After finding relevant work via `/search-requirements`
- Before implementing similar feature
- Reviewing past architectural decisions
- Learning from lessons learned
- Understanding implementation patterns

**When NOT to use:** if the ticket is still in flight (work session open, brainstorm or proposal exists, requirement not yet archived). Use `/load-context <identifier>` instead — it searches across all artifact types, including the requirements KB.

## Arguments

```bash
/load-requirements <identifier>
```

**identifier** (required): Work identifier (e.g., JIRA-123, USER-456)

## Process

### Step 1: Check Configuration

Read project configuration:
```bash
# Source resolve-config: marketplace installs get ${CLAUDE_PLUGIN_ROOT} substituted
# inline before bash runs; ./install.sh users fall back to ~/.claude. If neither
# path resolves, fail loudly rather than letting resolve_artifact be undefined.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found. Install via marketplace or run ./install.sh" >&2
  exit 1
fi
IFS='|' read -r REPO _TYPE <<< "$(resolve_artifact_typed requirements requirements)"
_BASE="$(dirname "$REPO")"
```

If the storage location type is `git`, sync before reading:
```bash
if [[ "$_TYPE" == "git" ]]; then
  cd "$_BASE" && git pull
fi
```

Extract requirements artifact path from storage configuration.

**If not configured:**
```
Requirements storage not configured

Configure in .claude/configuration.yml to load archived requirements.
See: ~/.claude/templates/requirements-repo/README.md
```

### Step 2: Offer Loading Options

Use AskUserQuestion:

```
Load requirements for ${identifier}

What would you like to load?

[1] Quick summary (metadata + key points)
[2] Full requirements (all sections)
[3] Specific section (choose from list)
[4] Agent outputs (context files)

Select [1-4]:
```

### Step 3: Delegate to Archivist

Based on user selection, use Task tool with `subagent_type: "archivist"`:

#### Option 1: Quick Summary

```
Task(archivist, "Load summary for ${identifier}

Load mode: metadata only

Return:
- Title, description, status
- Tags, components, APIs
- Key decisions (3-5 bullet points)
- Lessons learned (top 3)
- Related tickets
- Date and PR link
")
```

#### Option 2: Full Requirements

```
Task(archivist, "Load full requirements for ${identifier}

Load mode: complete

Return:
- Complete requirements.md (all sections)
- Metadata
- Implementation approach
- All technical decisions
- Lessons learned
- Related work
")
```

#### Option 3: Specific Section

After user selects section (Requirements, Architecture, Decisions, Implementation, Testing, Lessons):

```
Task(archivist, "Load ${section} section for ${identifier}

Load mode: section

Return only the specified section with full details.
")
```

#### Option 4: Agent Outputs

```
Task(archivist, "Load agent outputs for ${identifier}

Load mode: context files

Return:
- Available context files
- Option to load specific agent output
- Formatted agent findings
")
```

### Step 4: Display Results

#### Quick Summary Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
USER-123: User Data Export to Excel
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Status: Completed (YYYY-MM-DD)
PR: #456
Tags: export, excel, queue, user-data
Components: UserController, ExportService, ExportJob

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
QUICK SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Problem
Admins needed to export user data, but sync export
timed out on large datasets (10k+ users).

## Solution
Queue-based async processing with PhpSpreadsheet
library, S3 storage, and email notification.

## Key Decisions

1. **PhpSpreadsheet vs CSV**
   - Chose PhpSpreadsheet for rich formatting
   - Trade-off: Higher memory usage (addressed with
     chunk processing)

2. **Queue-based Processing**
   - Async processing prevents timeouts
   - User gets immediate response
   - Can handle 10k+ users in ~2 minutes

3. **S3 Storage**
   - 7-day retention for generated files
   - Signed URLs for secure download

## Implementation Patterns

- Repository pattern for data access
- Job/Queue pattern for async processing
- Chunk processing to manage memory (1000 records/chunk)

## Lessons Learned

✓ What worked well:
- Queue approach handled large datasets without issues
- Chunk processing prevented memory problems
- PhpSpreadsheet formatting well-received by admins

⚠ Gotchas to avoid:
- PhpSpreadsheet memory usage: use gc_collect_cycles()
- Set queue timeout > processing time (300s vs 120s default)
- Test with production-scale data volumes

## Related Work

- REPORT-200: Similar export pattern (PDF reports)
- EXPORT-100: Earlier CSV export (sync, had timeout issues)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Load full details: /load-requirements USER-123
Search similar: /search-requirements "export excel"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### Full Requirements Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
USER-123: User Data Export to Excel
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[Complete requirements.md content displayed]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Examples

### Example 1: Quick Summary

```bash
/load-requirements USER-123
# Select option 1
```

Shows summary with key points, decisions, and lessons.

### Example 2: Full Requirements

```bash
/load-requirements USER-123
# Select option 2
```

Shows complete requirements.md document.

### Example 3: Specific Section

```bash
/load-requirements USER-123
# Select option 3
# Choose "Technical Decisions"
```

Shows only the technical decisions section in detail.

### Example 4: Agent Outputs

```bash
/load-requirements USER-123
# Select option 4
# Choose which agent output to view
```

Shows agent analysis (business-analyst, archaeologist, etc.).

## Loading Modes Comparison

| Mode | Speed | Detail | Use When |
|------|-------|--------|----------|
| Quick summary | Fast | High-level | Initial exploration |
| Full requirements | Moderate | Complete | Deep understanding needed |
| Specific section | Fast | Focused | Looking for specific info |
| Agent outputs | Fast | Technical | Understanding analysis |

## Navigation

After loading, the skill offers:

```
What would you like to do?

[1] View different section
[2] Search for related work
[3] Compare with another ticket
[4] Export to local file
[5] Done

Select [1-5]:
```

### Option 1: View Different Section

Switch to another section without reloading.

### Option 2: Search Related

```bash
/search-requirements "tag:${tags[0]}"
```

Finds other work with similar tags.

### Option 3: Compare

```
Compare with which ticket?
Enter identifier: REPORT-200

Shows side-by-side comparison:
- Similar approaches
- Different decisions
- Lessons from both
```

### Option 4: Export

```bash
# Copy requirements.md to local file
cp /path/to/requirements-repo/${identifier}/requirements.md \
   docs/reference/${identifier}-requirements.md

✓ Exported to: docs/reference/${identifier}-requirements.md
```

## Error Handling

### Requirement Not Found

The requirements KB only contains tickets that have been archived. If nothing matches, the ticket is most likely still in flight — point the user at `/load-context`, which searches every artifact type (work sessions, brainstorms, proposals, requirements KB, product knowledge, git history):

```
❌ Requirement not found: USER-999

This skill only searches the archived requirements KB. For in-flight tickets,
try /load-context — it also covers work sessions, brainstorms, and proposals:

  /load-context USER-999

Other options:
- Search the archive:   /search-requirements "keyword"
- List recent archives: /search-requirements "after:2020-01-01"

Nearby entries in the archive:
- USER-123
- USER-456
- PROJ-789
```

### Missing Sections

```
⚠ Section "Testing" not available for USER-123

This requirement may have been archived before
the testing section was added to the template.

Available sections:
- Overview
- Requirements
- Architecture
- Implementation
- Lessons Learned

Select different section or view full requirements.
```

### Repository Not Accessible

```
❌ Cannot access requirements repository

Path: /path/to/requirements-repo
Error: Permission denied

Check:
1. Repository path in .claude/configuration.yml
2. File permissions
3. Repository exists

Fix and retry: /load-requirements USER-123
```

## Tips

### Efficient Browsing

1. **Start with summary** - Quick overview
2. **Load specific sections** - Dive into relevant parts
3. **Check lessons learned** - Avoid past mistakes
4. **View related work** - Build comprehensive understanding

### Cross-Referencing

When working on similar feature:
```bash
# 1. Search for similar work
/search-requirements "export excel"

# 2. Load top result
/load-requirements USER-123

# 3. Check related tickets mentioned
/load-requirements REPORT-200

# 4. Compare approaches
# (using Compare option)
```

### Learning Patterns

Use load-requirements to build understanding of:
- **Architectural patterns** - How team solves similar problems
- **Technology choices** - What works, what doesn't
- **Implementation strategies** - Proven approaches
- **Common pitfalls** - What to avoid

## Performance

**Loading times:**
- Quick summary: < 1 second (index + metadata only)
- Full requirements: 1-2 seconds (reads requirements.md)
- Specific section: < 1 second (targeted read)
- Agent outputs: 1-2 seconds (reads context files)

## See Also

- `/search-requirements <query>` - Find requirements to load
- `/archive-requirements [id]` - Archive new requirements
- `/rebuild-requirements-index` - Fix index if loading fails
