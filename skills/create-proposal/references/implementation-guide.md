# Phase 5: Implementation & Documentation

**Goal**: Implement the approved design and create documentation.

## 5.1 Implementation Structure

Create implementation in the work directory:
```
$WORK_DIR/{identifier}/src/
```

Follow your project's existing conventions. The exploration agent (Phase 1.1b) mapped the existing patterns — use those as your reference. If no established patterns exist for this type of feature, define them explicitly in the proposal and get approval before implementing.

**General principles:**
- Mirror the directory structure of similar existing features
- Follow the naming conventions already established (check exploration.md context)
- Keep business logic in service/domain layers, not in entry points (controllers, handlers, lambdas)
- One responsibility per class/module
- Inject dependencies; avoid global state

**Ecosystem structure reference** — use `{ecosystem}` as a starting point, adapt to what already exists in the codebase:

| Ecosystem | Source Dir | Entry Points | Business Logic |
|-----------|-----------|--------------|----------------|
| `php-symfony` | `src/` | `Controller/` | `Service/` |
| `node` | `src/` | `routes/` | `services/` |
| `react` | `src/` | `pages/` | `hooks/`, `contexts/` |
| `go` | root | `cmd/`, `handlers/` | `pkg/`, `internal/` |
| `python` | module dir | `routes/`, `views/` | `services/` |

## 5.2 Create README.md

After implementation, create comprehensive documentation:

```
$WORK_DIR/{identifier}/README.md
```

**Ecosystem command reference** — substitute based on `{ecosystem}` when generating the README:

| | `php-symfony` | `node` / `react` | `go` | `python` |
|--|---------------|-----------------|------|----------|
| Install | `composer require vendor/pkg` | `npm install pkg` | `go get github.com/vendor/pkg` | `pip install pkg` |
| Migrate | `php bin/console doctrine:migrations:migrate` | *(ORM-specific)* | *(tool-specific)* | `python manage.py migrate` (Django) / `alembic upgrade head` |

**README.md structure:**
```markdown
# [Feature Name]

Brief description

## Architecture Overview
High-level description with component list

## Directory Structure
```
{source_dir}/
├── {entry_points_dir}/
├── {business_logic_dir}/
...
```
Fill in based on {ecosystem} and existing project conventions.

## Installation

### 1. Copy Files
Explain file placement

### 2. Install Dependencies
```bash
{ecosystem_install_command}
```

### 3. Configure Services
Service configuration examples

### 4. Environment Variables
List all required env vars with examples

### 5. Run Migrations (if applicable)
```bash
{ecosystem_migration_command}
```

## Usage

### Endpoint Documentation
For each endpoint:
- Request/response examples
- Error cases
- Authentication requirements

## Maintenance
Commands, cleanup tasks, scheduled jobs

## Security Considerations
Security features and best practices

## Logging
Logging configuration and channels

## Testing
Test cases to implement

## Troubleshooting
Common issues and solutions

## Architecture & Design Patterns
Explain patterns used and rationale

## Implementation Notes
Completed features and TODOs

## Compatibility
Versions and dependencies

## Support
Links to related docs
```

## 5.3 Finalize and Copy to Proposals

After implementation is complete:

1. **Update final state:**

```json
{
  "status": "completed",
  "completed_at": "{ISO_TIMESTAMP}",
  "phases": {
    "requirements_gathering": {"status": "completed"},
    "brainstorming": {"status": "completed"},
    "proposal_drafts": {"status": "completed", "final_version": "proposal2.md"},
    "confirm_implementation": {"status": "completed"},
    "implementation": {"status": "completed"}
  },
  "outputs": {
    "final_proposal": "proposal2.md",
    "readme": "README.md",
    "proposals_dir": "$PROPOSALS_DIR/{proposal_name}/"
  }
}
```

2. **Copy to proposals directory:**

```bash
mkdir -p $PROPOSALS_DIR/{proposal_name}
cp $WORK_DIR/{identifier}/{final_proposal} $PROPOSALS_DIR/{proposal_name}/proposal-final.md
cp $WORK_DIR/{identifier}/README.md $PROPOSALS_DIR/{proposal_name}/
cp -r $WORK_DIR/{identifier}/notes $PROPOSALS_DIR/{proposal_name}/
cp -r $WORK_DIR/{identifier}/src $PROPOSALS_DIR/{proposal_name}/
```

3. **Update manifests:**

Update **work manifest** (`${WORK_DIR}/manifest.json`) to reflect completion:
```json
{
  "identifier": "{identifier}",
  "type": "proposal",
  "status": "completed",
  "current_phase": "completed",
  "progress": "Phase 5/5",
  "updated_at": "{ISO_TIMESTAMP}"
}
```

Update **proposals manifest** (`${PROPOSALS_DIR}/manifest.json`) with the new proposal (see [docs/manifest-system.md](../../../../docs/manifest-system.md)):
```json
{
  "name": "{proposal_name}",
  "title": "{feature_description_summary}",
  "status": "final",
  "created_at": "{from_state}",
  "updated_at": "{ISO_TIMESTAMP}",
  "iterations": "{iteration_count}",
  "tags": [],
  "path": "{proposal_name}/"
}
```

4. **Report completion:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Proposal Complete: {identifier}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Proposal: {title}
Iterations: {iteration_count}

Work Directory: $WORK_DIR/{identifier}/
Final Output: $PROPOSALS_DIR/{proposal_name}/

Files:
  ✓ $PROPOSALS_DIR/{proposal_name}/proposal-final.md
  ✓ $PROPOSALS_DIR/{proposal_name}/README.md
  ✓ $PROPOSALS_DIR/{proposal_name}/src/
  ✓ $PROPOSALS_DIR/{proposal_name}/notes/

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Next Steps:
  1. Review: $PROPOSALS_DIR/{proposal_name}/README.md
  2. Copy src/ to your project
  3. Follow installation instructions
```

```bash
# Clear auto-context sentinel on completion
if [ -n "${CLAUDE_SESSION_ID:-}" ] \
   && [ -f "$WORK_DIR/.active-sessions" ] \
   && command -v jq >/dev/null 2>&1; then
  (
    flock -x -w 2 200 || exit 0
    jq --arg s "$CLAUDE_SESSION_ID" 'del(.[$s])' "$WORK_DIR/.active-sessions" \
       > "$WORK_DIR/.active-sessions.tmp.$$" \
       && mv "$WORK_DIR/.active-sessions.tmp.$$" "$WORK_DIR/.active-sessions" \
       || rm -f "$WORK_DIR/.active-sessions.tmp.$$"
  ) 200>"$WORK_DIR/.active-sessions.lock"
fi
```
