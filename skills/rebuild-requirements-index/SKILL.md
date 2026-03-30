---
name: rebuild-requirements-index
model: haiku
category: requirements-kb
description: Rebuild search index for requirements repository
userInvocable: true
allowed-tools: Read, Bash, Task, AskUserQuestion
---

# Rebuild Requirements Index

Rebuild the search index for the team's requirements repository.

## Purpose

Fix corrupted, outdated, or missing index.json file that enables fast search of archived requirements.

## When to Use

- Index file corrupted (invalid JSON)
- Search failing or returning incorrect results
- After manual changes to requirements repository
- Index out of sync with actual requirements
- After repository cleanup or archival
- As part of maintenance routine

## How It Works

The index provides fast search without reading all requirement files:

**Without index:**
- Search must read 100+ requirements.md files
- Slow (10+ seconds)
- High memory usage

**With index:**
- Search reads single index.json file
- Fast (< 100ms)
- Low memory usage

## What Gets Rebuilt

The index contains:
- List of all tickets with metadata
- Tag frequencies (for browsing)
- Component frequencies (for filtering)
- Project counts (for multi-project repos)
- Last updated timestamp

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

Configure in .claude/configuration.yml to rebuild index.
See: ~/.claude/templates/requirements-repo/README.md
```

### Step 2: Confirm Rebuild

Use AskUserQuestion:

```
Rebuild requirements index?

Repository: ${repo_path}
Current index: ${index_status}

This will:
- Scan all requirement directories
- Extract metadata from each
- Rebuild index.json
- Validate integrity

Existing index will be backed up to:
  index.json.backup.${timestamp}

Time estimate: ~1 second per 100 requirements

Continue? [y/n]
```

### Step 3: Backup Current Index

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp ${repo_path}/index.json \
   ${repo_path}/index.json.backup.${TIMESTAMP}

✓ Backed up to: index.json.backup.${TIMESTAMP}
```

### Step 4: Delegate to Archivist

Use Task tool with `subagent_type: "archivist"`:

```
Task(archivist, "Rebuild requirements index

Repository: ${repo_path}

Process:
1. Scan all directories in repository root
2. For each directory with metadata.json:
   a. Read metadata.json
   b. Extract: id, title, description, tags, components, etc.
   c. Add to index tickets array
   d. Update tag/component/project frequencies
3. Skip directories: templates/, archive/, .git/
4. Handle missing or malformed metadata gracefully
5. Sort tickets by date (newest first)
6. Generate new index.json
7. Validate JSON structure
8. Write to repository
9. Report statistics and issues

Return:
- Tickets scanned
- Tickets added to index
- Issues found (missing metadata, malformed JSON, etc.)
- Tag and component counts
- Backup location
")
```

### Step 5: Report Results

**Success:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Index Rebuilt Successfully
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Repository: ${repo_path}
Execution time: 2.3 seconds

SCAN RESULTS
────────────────────────────────────────────────
Directories scanned: 28
Requirements found: 25
Added to index: 24
Skipped: 1 (issues)

STATISTICS
────────────────────────────────────────────────
Unique tags: 45
Unique components: 78
Projects: 3
Date range: YYYY-MM-DD to YYYY-MM-DD

TAG FREQUENCIES (top 10)
────────────────────────────────────────────────
api              : 15
database         : 12
export           : 8
authentication   : 5
integration      : 4
...

COMPONENT FREQUENCIES (top 10)
────────────────────────────────────────────────
UserController   : 8
AuthService      : 5
ExportService    : 3
ApiController    : 3
...

ISSUES FOUND
────────────────────────────────────────────────
⚠ USER-100: Missing metadata.json (skipped)

Recommendation: Add metadata.json or move to archive/

BACKUP
────────────────────────────────────────────────
Old index backed up to:
  index.json.backup.20260203_143022

Index committed to git:
  commit abc123: "Rebuild requirements index"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Test search: /search-requirements "export"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**With Issues:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠ Index Rebuilt with Issues
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Directories scanned: 30
Requirements found: 27
Added to index: 24
Skipped: 3 (issues)

ISSUES
────────────────────────────────────────────────
❌ USER-100: Missing metadata.json
   → Add metadata or move to archive/

❌ USER-101: Malformed metadata.json (invalid JSON)
   → Fix JSON syntax or regenerate metadata

⚠ USER-102: Missing required fields (title, description)
   → Update metadata.json with required fields

RECOMMENDATIONS
────────────────────────────────────────────────
1. Fix or archive problematic requirements:
   - USER-100: Add metadata.json
   - USER-101: Fix JSON syntax
   - USER-102: Add missing fields

2. Or move to archive/:
   mv USER-100 archive/2025/USER-100

3. Rebuild after fixing:
   /rebuild-requirements-index

Index is functional but incomplete.
Search will work but won't include skipped requirements.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Examples

### Example 1: Simple Rebuild

```bash
/rebuild-requirements-index
```

Rebuilds index from all requirements in repository.

### Example 2: After Manual Changes

```bash
# After manually editing metadata
/rebuild-requirements-index
```

Ensures index reflects manual changes.

### Example 3: After Cleanup

```bash
# After moving old requirements to archive/
mv USER-* archive/2025/
/rebuild-requirements-index
```

Removes archived requirements from index.

## When to Rebuild

### Required

- **Index corrupted** - Invalid JSON, cannot parse
- **Index missing** - File deleted or never created
- **Search fails** - Errors when searching

### Recommended

- **After bulk operations** - Archiving multiple requirements
- **After manual edits** - Direct changes to metadata.json
- **After cleanup** - Moving requirements to archive/
- **Periodic maintenance** - Monthly or quarterly

### Optional

- **After single archive** - Automatic in `/archive-requirements`
- **Normal usage** - Index auto-updated on archive

## Safety

### Non-Destructive

- Original requirements files unchanged
- Old index backed up before rebuild
- Backup includes timestamp
- Can restore from backup if needed

### Restore from Backup

If rebuild caused issues:
```bash
cd ${repo_path}

# Find backups
ls -lt index.json.backup.*

# Restore from backup
cp index.json.backup.20260203_143022 index.json

# Commit restoration
git add index.json
git commit -m "Restore index from backup"
git push
```

## Validation

The rebuild process validates:

**Required fields:**
- id (must be unique)
- title
- description
- status

**Optional fields:**
- tags (array)
- components (array)
- date (ISO format)
- project

**Structure:**
- Valid JSON syntax
- No duplicate ticket IDs
- All dates parseable
- Arrays are arrays (not strings)

## Performance

**Rebuild time:**
- ~1 second per 100 requirements
- 25 requirements: ~0.25 seconds
- 500 requirements: ~5 seconds
- 1000 requirements: ~10 seconds

**Scales well:**
- Linear performance
- Low memory usage
- Can handle 1000+ requirements

## Troubleshooting

### Permission Denied

```
❌ Cannot write to repository

Path: /path/to/requirements-repo/index.json
Error: Permission denied

Check:
1. File permissions: chmod 644 index.json
2. Directory permissions: chmod 755 /path/to/requirements-repo
3. Git permissions

Fix and retry: /rebuild-requirements-index
```

### Git Conflicts

```
❌ Git conflict when committing index

Another developer may have rebuilt simultaneously.

To resolve:
1. cd ${repo_path}
2. git pull --rebase
3. Retry: /rebuild-requirements-index
```

### Invalid Metadata

```
⚠ Found 3 requirements with invalid metadata

Details:
- USER-100: Missing metadata.json
- USER-101: Invalid JSON syntax
- USER-102: Missing required field: title

Options:
1. Fix metadata in these requirements
2. Move to archive/: mv USER-100 archive/2025/
3. Skip and rebuild anyway (index will be incomplete)

How to proceed? [fix/archive/skip]
```

## Maintenance Schedule

**Recommended:**

- **After bulk operations** - Immediately
- **After manual changes** - Immediately
- **Routine maintenance** - Monthly
- **Before important searches** - If index seems stale

**Signs index needs rebuild:**
- Search returns unexpected results
- Missing recent requirements
- Duplicate results
- Search errors

## Advanced Usage

### Rebuild with Custom Path

If multiple requirements repositories:
```bash
# Configure alternate repository temporarily
# Then rebuild
/rebuild-requirements-index
```

### Rebuild After Migration

After migrating from old structure:
```bash
# Migrate old requirements to new format
# Then rebuild index
/rebuild-requirements-index
```

### Scheduled Rebuilds

For periodic rebuilds, invoke the skill manually or set up a script that calls the rebuild logic from `resolve-config.sh`.

## See Also

- `/search-requirements <query>` - Search using the index
- `/archive-requirements [id]` - Archive (auto-updates index)
- `/load-requirements <id>` - Load specific requirement
