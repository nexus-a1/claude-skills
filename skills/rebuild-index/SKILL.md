---
name: rebuild-index
model: claude-haiku-4-5
category: project-setup
description: Rebuild manifest.json for any artifact storage type. Scans directories and regenerates from scratch.
argument-hint: <artifact-type|all>
userInvocable: true
allowed-tools: Read, Write, Bash, Glob, Grep, Task, AskUserQuestion
---

# Rebuild Index

Rebuild `manifest.json` for one or all artifact storage types by scanning directories and extracting metadata from state files.

## Usage

```bash
/rebuild-index work              # Rebuild work manifest
/rebuild-index brainstorms       # Rebuild brainstorms manifest
/rebuild-index proposals         # Rebuild proposals manifest
/rebuild-index refactoring       # Rebuild refactoring manifest
/rebuild-index product-knowledge # Rebuild product knowledge manifest
/rebuild-index requirements      # Delegates to /rebuild-requirements-index
/rebuild-index all               # Rebuild all manifests
```

## When to Use

- Manifest missing or corrupted
- After manual changes to artifact directories
- After cleanup or archival operations
- Periodic maintenance
- As a safety net when manifests fall out of sync

## Context

Arguments: $ARGUMENTS

---

## Configuration

Read `.claude/configuration.yml` for all artifact paths:

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
IFS='|' read -r WORK_DIR WORK_TYPE         <<< "$(resolve_artifact_typed work work)"
IFS='|' read -r BRAINSTORM_DIR BRAIN_TYPE  <<< "$(resolve_artifact_typed brainstorms brainstorm)"
IFS='|' read -r PROPOSALS_DIR PROP_TYPE    <<< "$(resolve_artifact_typed proposals proposals)"
IFS='|' read -r REFACTOR_DIR REFAC_TYPE    <<< "$(resolve_artifact_typed refactoring work/refactoring-sessions)"
IFS='|' read -r REQUIREMENTS_DIR REQ_TYPE  <<< "$(resolve_artifact_typed requirements requirements)"
IFS='|' read -r PRODUCT_DIR PROD_TYPE      <<< "$(resolve_artifact_typed product-knowledge .)"
```

---

## Process

### Step 1: Parse Argument

Parse `$ARGUMENTS` to determine which artifact type(s) to rebuild.

**Valid arguments:** `work`, `brainstorms`, `proposals`, `refactoring`, `product-knowledge`, `requirements`, `all`

**If no argument or invalid argument:**
```
Error: Artifact type required.

Usage:
  /rebuild-index work
  /rebuild-index brainstorms
  /rebuild-index proposals
  /rebuild-index refactoring
  /rebuild-index product-knowledge
  /rebuild-index requirements
  /rebuild-index all

See docs/manifest-system.md for manifest schema details.
```

### Step 2: Sync Git Locations

For any artifact location with `type: git`, sync before scanning:

```bash
if [[ "$_TYPE" == "git" ]]; then
  _LOC=$(yq -r ".storage.artifacts.${artifact}.location" "$CONFIG")
  _BASE=$(yq -r ".storage.locations.${_LOC}.path" "$CONFIG")
  cd "$_BASE" && git pull --quiet
fi
```

### Step 3: Execute Rebuild(s)

For `all`, run each artifact type sequentially (or report results for each). For a single type, run just that one.

**Special cases:**
- `requirements` → Delegate to `/rebuild-requirements-index` skill
- `product-knowledge` → Delegate to `product-expert` agent

---

## Rebuild: Work

**Path:** `$WORK_DIR`

1. Back up existing `${WORK_DIR}/manifest.json` to `manifest.json.backup.{TIMESTAMP}`
2. Scan subdirectories of `$WORK_DIR`
3. For each subdirectory, read `state.json` and check the `type` field to detect work type:
   - `"implementation"` → type: `implementation`
   - `"proposal"` → type: `proposal`
   - `"epic"` → type: `epic`
   - `"requirements"` → type: `requirements`
4. Extract metadata from the state file:
   - `identifier`: from state file or directory name
   - `title`: from state file
   - `status`: from state file
   - `created_at`, `updated_at`: from state file
   - `current_phase`: derive from state file status fields
   - `progress`: derive from chunks or stages
   - `branch`: from state file branches section
   - `tags`: empty array (not tracked in state files)
5. Build manifest with `artifact_type: "work"`
6. Write to `${WORK_DIR}/manifest.json`

**Skip directories:** `manifest.json`, `manifest.json.backup.*`, any file (non-directory)

---

## Rebuild: Brainstorms

**Path:** `$BRAINSTORM_DIR`

1. Back up existing manifest
2. Scan subdirectories of `$BRAINSTORM_DIR`
3. For each subdirectory:
   - `slug`: directory name
   - `title`: extract from first heading in `brainstorm-summary.md` or `approaches.md`, or use slug
   - `created_at`: earliest file modification time in directory
   - `selected_approach`: extract from `brainstorm-summary.md` if exists
   - `alternatives_count`: count approach sections in `approaches.md` if exists
   - `tags`: empty array
4. Build manifest with `artifact_type: "brainstorms"`
5. Write to `${BRAINSTORM_DIR}/manifest.json`

---

## Rebuild: Proposals

**Path:** `$PROPOSALS_DIR`

1. Back up existing manifest
2. Scan subdirectories of `$PROPOSALS_DIR`
3. For each subdirectory:
   - `name`: directory name
   - `title`: extract from first heading in `proposal-final.md` or latest `proposal*.md`
   - `status`: `implemented` if `src/` exists, `final` if `proposal-final.md` exists, else `draft`
   - `created_at`: earliest file modification time
   - `updated_at`: latest file modification time
   - `iterations`: count of `proposal*.md` files
   - `tags`: empty array
4. Build manifest with `artifact_type: "proposals"`
5. Write to `${PROPOSALS_DIR}/manifest.json`

---

## Rebuild: Refactoring

**Path:** `$REFACTOR_DIR`

1. Back up existing manifest
2. Scan subdirectories of `$REFACTOR_DIR`
3. For each subdirectory with `session-state.json`:
   - `session_name`: from state file or directory name
   - `title`: from `target.scope` in state file, or directory name
   - `status`: from state file
   - `created_at`, `updated_at`: from state file
   - `files_affected`: count from `target.files` array in state file
   - `progress`: derive from `progress.completed`/`progress.completed + progress.pending` in state file
   - `tags`: empty array
4. Build manifest with `artifact_type: "refactoring"`
5. Write to `${REFACTOR_DIR}/manifest.json`

---

## Rebuild: Product Knowledge

**Path:** `$PRODUCT_DIR`

Delegate to `product-expert` agent:

```
Task(product-expert, "Build a fresh manifest.json for the product knowledge base.

Knowledge base path: ${PRODUCT_DIR}

Process:
1. Scan all .md files recursively in the knowledge base
2. For each file:
   - Extract title from first heading (or use filename)
   - Determine category from parent directory name
   - Extract tags from content (look for tags/keywords sections, or infer from headings)
   - Create a one-line summary from the first paragraph
3. Build categories and tags frequency maps
4. Write manifest.json to ${PRODUCT_DIR}/manifest.json

Use the manifest schema from docs/manifest-system.md (artifact_type: product-knowledge).
Include the extra 'categories' and 'tags' top-level fields.
")
```

---

## Rebuild: Requirements

Delegate entirely to the existing `/rebuild-requirements-index` skill:

```
The requirements knowledge base uses its own index.json format with richer metadata.
Delegating to /rebuild-requirements-index...
```

Trigger the `/rebuild-requirements-index` skill.

---

## Step 4: Report Results

For each artifact type rebuilt, report:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Index Rebuilt: {artifact_type}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Path: {artifact_dir}
Items found: {count}
Backup: manifest.json.backup.{timestamp}

Items:
  - {item_1_key}: {title} ({status})
  - {item_2_key}: {title} ({status})
  ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

For `all`, show a summary table:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Index Rebuild Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Artifact           Items  Status
──────────────────────────────────────────────
Work                  3   Rebuilt
Brainstorms           1   Rebuilt
Proposals             2   Rebuilt
Refactoring           0   Empty (no sessions)
Product Knowledge     8   Rebuilt (via agent)
Requirements          5   Rebuilt (via /rebuild-requirements-index)

Total: 19 items indexed across 6 artifact types.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Handling

**Artifact directory doesn't exist:**
```
⚠ {artifact_type}: Directory not found: {path}
  Skipping — no items to index.
```

**No items found:**
```
{artifact_type}: 0 items found in {path}
  Created empty manifest.json.
```

**Corrupt existing manifest:**
```
⚠ {artifact_type}: Existing manifest.json is invalid JSON
  Backed up to: manifest.json.corrupt.{timestamp}
  Building fresh manifest from directory scan.
```

**Agent delegation failure (product-knowledge):**
```
⚠ product-knowledge: Agent failed to build manifest
  Error: {error_message}

  Options:
  [r] Retry agent
  [s] Skip product-knowledge
  [a] Abort
```

Use AskUserQuestion for selection.

---

## See Also

- [Manifest System Reference](../../docs/manifest-system.md) — Schema details and update patterns
- `/rebuild-requirements-index` — Requirements-specific index rebuild
- `/load-context` — Uses manifests for fast listing and lookup
- `/resume-work` — Uses work manifest to find incomplete work
