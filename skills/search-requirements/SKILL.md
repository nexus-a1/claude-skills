---
name: search-requirements
model: sonnet
category: requirements-kb
description: Search team requirements repository for similar past work
argument-hint: <query>
userInvocable: true
allowed-tools: Read, Bash, Task
---

# Search Requirements

Search the team's requirements knowledge base for similar past work.

## Purpose

Find past implementations, architectural decisions, and lessons learned from similar features to inform current work.

## When to Use

- Before starting new feature work (research phase)
- Looking for implementation patterns to reuse
- Finding past decisions on similar problems
- Exploring team's historical knowledge

## Arguments

```bash
/search-requirements <query>
```

**query** (required): Search query
- Can be keywords (e.g., "user export excel")
- Can include filters (e.g., "tag:export component:UserService")
- Can combine multiple terms

### Search Syntax

**Keyword search:**
```bash
/search-requirements "user authentication"
```

**Tag filter:**
```bash
/search-requirements "tag:export,api"
```

**Component filter:**
```bash
/search-requirements "component:UserController"
```

**Date filter:**
```bash
/search-requirements "export after:2025-01-01"
```

**Combined:**
```bash
/search-requirements "export tag:excel component:UserService after:2025-01-01"
```

## Process

### Step 1: Check Configuration

Read project configuration:
```bash
# BEGIN_SHARED: resolve-config
# Shared configuration resolution for Claude Code skills.
# Source this script to get config discovery and artifact resolution functions.
#
# Usage in SKILL.md bash blocks:
#   source ~/.claude/shared/resolve-config.sh
#   WORK_DIR=$(resolve_artifact work work)
#   EXEC_MODE=$(resolve_exec_mode qa_review team)

# --- Config discovery ---
# Walks up from CWD to find .claude/configuration.yml
CONFIG=""
_d="$PWD"
while [[ "$_d" != "/" ]]; do
  if [[ -f "$_d/.claude/configuration.yml" ]]; then
    CONFIG="$_d/.claude/configuration.yml"
    break
  fi
  _d="$(dirname "$_d")"
done

# --- Artifact resolution ---
# Resolves an artifact path from configuration, with fallback defaults.
# Usage: resolve_artifact <artifact_name> <default_subdir> [default_base]
# Returns: resolved path (e.g., ".claude/work" or "/abs/path/to/requirements")
resolve_artifact() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    echo "${_BASE}/${_SUB}"
  else
    echo "${default_base}/${default_subdir}"
  fi
}

# --- Artifact resolution with type ---
# Like resolve_artifact but also returns the storage type (git|directory).
# Usage: IFS='|' read -r PATH TYPE <<< "$(resolve_artifact_typed work work)"
resolve_artifact_typed() {
  local artifact="$1"
  local default_subdir="$2"
  local default_base="${3:-.claude}"

  if [[ -f "$CONFIG" ]]; then
    local _LOC=$(yq -r ".storage.artifacts.${artifact}.location // \"local\"" "$CONFIG")
    local _BASE=$(yq -r ".storage.locations.${_LOC}.path // \"${default_base}\"" "$CONFIG")
    local _SUB=$(yq -r ".storage.artifacts.${artifact}.subdir // \"${default_subdir}\"" "$CONFIG")
    local _TYPE=$(yq -r ".storage.locations.${_LOC}.type // \"directory\"" "$CONFIG")
    echo "${_BASE}/${_SUB}|${_TYPE}"
  else
    echo "${default_base}/${default_subdir}|directory"
  fi
}

# --- Execution mode resolution ---
# Resolves execution mode for a specific phase from configuration.
# Usage: resolve_exec_mode <phase_name> [default_mode]
# Returns: "team" or "subagent"
resolve_exec_mode() {
  local phase="$1"
  local default="${2:-team}"

  if [[ -f "$CONFIG" ]]; then
    local _raw=$(yq -r '.execution_mode' "$CONFIG" 2>/dev/null)
    if [[ "$_raw" == "subagent" || "$_raw" == "team" ]]; then
      echo "$_raw"
    elif [[ "$_raw" != "null" && -n "$_raw" ]]; then
      yq -r ".execution_mode.overrides.${phase} // .execution_mode.default // \"${default}\"" "$CONFIG"
    else
      echo "$default"
    fi
  else
    echo "$default"
  fi
}
# END_SHARED: resolve-config
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

To search past work, configure requirements storage:
1. See: ~/.claude/templates/requirements-repo/README.md
2. Add to .claude/configuration.yml:

storage:
  locations:
    team-knowledge:
      type: git
      path: /path/to/team-knowledge
  artifacts:
    requirements: { location: team-knowledge, subdir: requirements }
```

### Step 2: Delegate to Archivist

Use Task tool with `subagent_type: "archivist"`:

```
Task(archivist, "Search requirements repository

Query: ${query}
Configuration: ${requirements_config}

Tasks:
1. Sync requirements repository (if sync_command configured)
2. Parse query for keywords, filters, date ranges
3. Load index.json for fast search
4. Calculate relevance scores for matching tickets
5. Rank results by relevance (0.0-1.0)
6. Return top results with summaries

Search dimensions:
- Keyword match (title, description, requirements text)
- Tag match (if filters specified)
- Component match (if filters specified)
- Date range (if specified)

Return:
- Top 10 results ranked by relevance
- Each result: id, title, summary, relevance score, tags, components
- Total matches found
")
```

### Step 3: Display Results

**Format results:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Search Results: "${query}"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Found 7 matches (showing top 5):

[1] USER-123: User data export to Excel (relevance: 0.95) ⭐
    Tags: export, excel, queue, user-data
    Components: UserController, ExportService, ExportJob
    Date: 2026-02-20

    Summary: Queue-based async export with PhpSpreadsheet.
    Handles 10k+ users without timeout. S3 storage with
    7-day retention.

    Match reason: High keyword match: 'export', 'excel'.
    Same component: ExportService.

─────────────────────────────────────────────────

[2] REPORT-200: Report export system (relevance: 0.82)
    Tags: export, pdf, reports
    Components: ReportController, ExportService
    Date: 2026-01-15

    Summary: PDF report generation with async processing.
    Uses dompdf library with queue jobs.

    Match reason: Keyword match: 'export'. Component
    overlap: ExportService.

─────────────────────────────────────────────────

[3] INVOICE-300: Invoice export (relevance: 0.75)
    Tags: export, pdf, invoices
    Components: InvoiceController, PdfGenerator
    Date: 2025-12-10

    Summary: Sync invoice export to PDF with template
    system.

    Match reason: Keyword match: 'export'.

─────────────────────────────────────────────────

Load details: /load-requirements <id>
Search again: /search-requirements "<new query>"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**No results:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Search Results: "${query}"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

No matches found.

Suggestions:
- Try broader keywords: "export" instead of "excel export"
- Check spelling
- Try related terms: "download" instead of "export"
- Browse by tag: /search-requirements "tag:export"
- Browse recent work: /search-requirements "after:2025-01-01"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Examples

### Example 1: Keyword Search

```bash
/search-requirements "user authentication"
```

Finds tickets related to user authentication.

### Example 2: Tag Filter

```bash
/search-requirements "tag:export"
```

Finds all tickets tagged with "export".

### Example 3: Component Search

```bash
/search-requirements "component:UserController"
```

Finds tickets that modified UserController.

### Example 4: Combined Search

```bash
/search-requirements "authentication tag:jwt,oauth component:AuthService"
```

Finds authentication tickets with JWT/OAuth tags that modified AuthService.

### Example 5: Date Range

```bash
/search-requirements "api after:2025-06-01"
```

Finds API-related tickets from June 2025 onwards.

### Example 6: Recent Work

```bash
/search-requirements "after:2025-01-01"
```

Browses all work from this year.

## Search Tips

### Effective Queries

**✅ Good:**
- "user export" - Broad, finds variations
- "tag:export" - Finds all export-related work
- "component:UserService" - Finds all changes to UserService
- "authentication after:2025-01-01" - Recent auth work

**❌ Less Effective:**
- "user export feature to excel with async processing" - Too specific
- "USER-123" - Use /load-requirements for specific IDs
- "how to implement export" - Use natural keywords instead

### Understanding Relevance Scores

- **0.9-1.0** ⭐ - Highly relevant, likely very similar work
- **0.7-0.9** - Relevant, useful context
- **0.5-0.7** - Somewhat relevant, may have useful patterns
- **< 0.5** - Low relevance, filtered out

### Refining Search

**Too many results?**
- Add more specific keywords
- Use tag filters: "tag:export,excel"
- Use component filters: "component:UserService"
- Narrow date range: "after:2025-06-01"

**Too few results?**
- Use broader keywords: "export" vs "excel export"
- Remove filters
- Try related terms: "download" vs "export"
- Search by technology: "tag:phpspreadsheet"

## Search Filters Reference

### Tag Filters

```bash
tag:export          # Single tag
tag:export,api      # Multiple tags (OR)
tag:export tag:api  # Multiple tags (AND)
```

### Component Filters

```bash
component:UserController              # Single component
component:UserController,AuthService  # Multiple (OR)
```

### Date Filters

```bash
after:2025-01-01     # On or after date
before:2025-12-31    # On or before date
after:2025-01-01 before:2025-06-30  # Date range
```

### Project Filters

```bash
project:main-app     # Filter by project
project:api-service  # Different project
```

### Status Filters

```bash
status:completed     # Only completed work
status:archived      # Only archived work
```

## Common Searches

### Browse by Category

```bash
/search-requirements "tag:authentication"
/search-requirements "tag:api"
/search-requirements "tag:database"
/search-requirements "tag:export"
/search-requirements "tag:integration"
```

### Browse by Technology

```bash
/search-requirements "tag:jwt"
/search-requirements "tag:aws"
/search-requirements "tag:queue"
/search-requirements "tag:redis"
```

### Browse Recent Work

```bash
/search-requirements "after:2025-01-01"  # This year
/search-requirements "after:2025-06-01"  # Last 6 months
```

### Find Similar to Current Work

If working on authentication feature:
```bash
/search-requirements "authentication tag:jwt"
```

If working on export:
```bash
/search-requirements "export tag:excel,pdf"
```

## Error Handling

### Repository Not Found

```
❌ Requirements repository not found

Configured path: /path/to/requirements-repo
Error: Directory does not exist

Check CLAUDE.md configuration.
```

### Index Corrupted

```
❌ Search failed: Index file corrupted

Path: /path/to/requirements-repo/index.json
Error: Invalid JSON

To fix:
1. /rebuild-requirements-index
2. Or restore from backup: git checkout HEAD~1 index.json

Retry search after fixing.
```

### No Results

```
No matches found for: "${query}"

Try:
- Broader keywords
- Different search terms
- Browse by tag: /search-requirements "tag:export"
- Browse recent: /search-requirements "after:2025-01-01"
```

## Performance

**Fast search:**
- Index-based search (no file reads)
- Results in < 100ms for typical repositories

**Scales to:**
- 1000+ archived requirements
- Complex queries with multiple filters

## See Also

- `/load-requirements <id>` - Load full details for a result
- `/archive-requirements [id]` - Archive completed work
- `/rebuild-requirements-index` - Fix corrupted index
