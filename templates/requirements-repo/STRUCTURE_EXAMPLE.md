# Requirements Repository Structure Example

This document shows what a populated requirements repository looks like after archiving several tickets.

## Directory Tree

```
requirements-repo/
│
├── README.md                           # Setup and usage guide
├── .gitignore                          # Git ignore rules
├── index.json                          # Searchable index (3 tickets)
│
├── templates/                          # Templates for manual archival
│   ├── metadata.template.json
│   ├── requirements.template.md
│   └── index.template.json
│
├── USER-123/                           # User export feature
│   ├── metadata.json                   # Ticket metadata
│   ├── requirements.md                 # Human-readable summary
│   ├── requirements-state.json         # Original workflow state
│   └── context/                        # Agent outputs
│       ├── discovery.json              # context-builder output
│       ├── archivist.md                # Past similar work found
│       ├── archaeologist.md            # Code analysis
│       ├── data-modeler.md             # Database analysis
│       └── business-analyst.md         # Synthesis
│
├── AUTH-456/                           # JWT authentication
│   ├── metadata.json
│   ├── requirements.md
│   ├── requirements-state.json
│   └── context/
│       ├── discovery.json
│       ├── archivist.md
│       ├── archaeologist.md
│       ├── security-requirements.md   # Security analysis
│       └── business-analyst.md
│
├── API-789/                            # REST API refactor
│   ├── metadata.json
│   ├── requirements.md
│   ├── requirements-state.json
│   └── context/
│       ├── discovery.json
│       ├── archivist.md
│       ├── archaeologist.md
│       ├── integration-analyst.md     # API analysis
│       └── business-analyst.md
│
└── archive/                            # Archived old requirements
    └── 2025/
        └── OLD-100/                    # Deprecated feature
            ├── metadata.json
            ├── requirements.md
            └── context/
```

## Index.json Example

```json
{
  "version": "1.0",
  "last_updated": "YYYY-MM-DDT14:30:00Z",
  "total_tickets": 3,

  "tickets": [
    {
      "id": "USER-123",
      "title": "User data export to Excel with async processing",
      "description": "Add user export functionality with PhpSpreadsheet library and queue-based processing",
      "status": "completed",
      "project": "main-app",
      "date": "YYYY-MM-DD",
      "tags": ["export", "excel", "queue", "user-data"],
      "components": ["UserController", "ExportService", "ExportJob"],
      "apis": ["POST /api/export/users", "GET /api/export/status/{id}"],
      "path": "USER-123/",
      "archived": false
    },
    {
      "id": "AUTH-456",
      "title": "JWT authentication with refresh tokens",
      "description": "Implement JWT-based authentication system with refresh token rotation",
      "status": "completed",
      "project": "main-app",
      "date": "YYYY-MM-DD",
      "tags": ["authentication", "jwt", "security", "api"],
      "components": ["AuthController", "AuthService", "TokenService"],
      "apis": ["POST /api/auth/login", "POST /api/auth/refresh", "POST /api/auth/logout"],
      "path": "AUTH-456/",
      "archived": false
    },
    {
      "id": "API-789",
      "title": "REST API refactoring for v2",
      "description": "Refactor API endpoints to follow RESTful conventions and versioning",
      "status": "completed",
      "project": "api-service",
      "date": "YYYY-MM-DD",
      "tags": ["api", "refactor", "rest", "versioning"],
      "components": ["ApiController", "ResponseFormatter", "VersionMiddleware"],
      "apis": ["GET /v2/users", "POST /v2/users", "PUT /v2/users/{id}"],
      "path": "API-789/",
      "archived": false
    }
  ],

  "tags": {
    "export": 1,
    "excel": 1,
    "queue": 1,
    "user-data": 1,
    "authentication": 1,
    "jwt": 1,
    "security": 1,
    "api": 3,
    "refactor": 1,
    "rest": 1,
    "versioning": 1
  },

  "components": {
    "UserController": 1,
    "ExportService": 1,
    "ExportJob": 1,
    "AuthController": 1,
    "AuthService": 1,
    "TokenService": 1,
    "ApiController": 1,
    "ResponseFormatter": 1,
    "VersionMiddleware": 1
  },

  "projects": {
    "main-app": 2,
    "api-service": 1
  }
}
```

## Metadata Example (USER-123/metadata.json)

```json
{
  "id": "USER-123",
  "title": "User data export to Excel with async processing",
  "description": "Add user export functionality to admin panel with PhpSpreadsheet library and queue-based processing for large datasets",
  "status": "completed",
  "project": "main-app",

  "dates": {
    "created": "YYYY-MM-DD",
    "completed": "YYYY-MM-DD",
    "archived": "YYYY-MM-DD"
  },

  "tags": [
    "export",
    "excel",
    "queue",
    "user-data",
    "phpspreadsheet"
  ],

  "components": [
    "UserController",
    "ExportService",
    "ExportJob",
    "ExportRepository"
  ],

  "apis": {
    "added": [
      "POST /api/export/users",
      "GET /api/export/status/{id}"
    ],
    "modified": [
      "GET /api/users"
    ],
    "removed": []
  },

  "database": {
    "tables_affected": [
      "users",
      "export_jobs"
    ],
    "migrations": [
      "YYYY_MM_DD_create_export_jobs_table.php",
      "YYYY_MM_DD_add_export_columns_to_users.php"
    ],
    "schema_changes": [
      "Created table: export_jobs",
      "Added column: users.last_exported_at"
    ]
  },

  "external_integrations": [
    "AWS S3",
    "PhpSpreadsheet",
    "Laravel Queue"
  ],

  "related_tickets": [
    "USER-100",
    "EXPORT-200"
  ],

  "dependencies": {
    "blocks": [],
    "blocked_by": [],
    "relates_to": [
      "EXPORT-200"
    ]
  },

  "branch": "feature/USER-123",
  "pr_url": "https://github.com/org/repo/pull/456",

  "agents_used": [
    "context-builder",
    "archivist",
    "archaeologist",
    "data-modeler",
    "business-analyst"
  ],

  "implementation": {
    "approach": "Queue-based async processing with PhpSpreadsheet library and S3 storage",
    "patterns_used": [
      "Repository pattern",
      "Job/Queue pattern",
      "Service layer"
    ],
    "technologies": [
      "PhpSpreadsheet",
      "Laravel Queue",
      "AWS S3"
    ]
  },

  "notes": [
    "Chose async queue approach over sync to avoid timeouts on large datasets (10k+ users)",
    "PhpSpreadsheet chosen over CSV for rich formatting and multi-sheet support",
    "S3 storage ensures exports accessible for 7 days before cleanup",
    "Consider adding export templates in future iteration"
  ]
}
```

## Requirements Summary Example (USER-123/requirements.md)

```markdown
# USER-123: User Data Export to Excel with Async Processing

**Status:** Completed
**Created:** YYYY-MM-DD
**Completed:** YYYY-MM-DD
**Branch:** feature/USER-123
**PR:** [#456](https://github.com/org/repo/pull/456)

---

## Overview

Add user data export functionality to admin panel with Excel format support and asynchronous processing for large datasets.

**Problem:** Admins need to export user data for reporting and analysis, but sync export times out on large datasets (10k+ users).

**Solution:** Queue-based async processing with PhpSpreadsheet library, S3 storage, and status polling.

---

## Requirements

### Functional Requirements

- **FR1:** Export all user data to Excel format
- **FR2:** Support filtering (date range, status, role)
- **FR3:** Async processing for datasets > 1000 records
- **FR4:** Email notification when export ready
- **FR5:** Download link valid for 7 days

### Non-Functional Requirements

- **NFR1:** Export 10k users within 2 minutes
- **NFR2:** Admin-only access (authentication required)
- **NFR3:** Handle concurrent export requests

### Acceptance Criteria

- [x] Admin can trigger export from user management page
- [x] Export processes in background (no timeout)
- [x] Admin receives email with download link
- [x] Excel file includes all user fields with formatting
- [x] Old exports automatically cleaned up after 7 days

---

## Architecture

### Components Affected

| Component | Change Type | Description |
|-----------|-------------|-------------|
| ExportService | New | Business logic for export generation |
| ExportJob | New | Queue job for async processing |
| ExportController | New | API endpoints for export |
| ExportRepository | New | Data access for exports |

### Data Model

**Tables affected:**
- `users` - Added last_exported_at column
- `export_jobs` - New table for tracking export status

**Migrations:**
- `YYYY_MM_DD_create_export_jobs_table.php`
- `YYYY_MM_DD_add_export_columns_to_users.php`

### API Endpoints

**New endpoints:**
- `POST /api/export/users` - Trigger export (returns job ID)
- `GET /api/export/status/{id}` - Check export status

**Modified endpoints:**
- `GET /api/users` - Added export_count field

### External Integrations

- **AWS S3** - File storage for generated Excel files
- **PhpSpreadsheet** - Excel generation library
- **Laravel Queue** - Async job processing

---

## Implementation Approach

### Chosen Approach

Queue-based async processing with PhpSpreadsheet and S3 storage.

**Flow:**
1. Admin triggers export → creates ExportJob
2. Queue worker picks up job → generates Excel
3. Excel uploaded to S3 → signed URL generated
4. Email sent to admin → download link (7-day expiry)

### Alternatives Considered

1. **Sync CSV export**
   - Pros: Simple, no queue infrastructure
   - Cons: Timeouts on large datasets, limited formatting
   - Decision: Rejected due to timeout issues

2. **Third-party service (e.g., Exportable.io)**
   - Pros: No infrastructure to maintain
   - Cons: Cost, data privacy, vendor lock-in
   - Decision: Rejected due to data privacy concerns

### Design Patterns Used

- **Repository pattern:** Data access abstraction
- **Job/Queue pattern:** Async processing
- **Service layer:** Business logic separation

---

## Technical Decisions

### Decision 1: PhpSpreadsheet vs CSV

**Context:** Need to export user data in downloadable format

**Options:**
1. CSV (simple text format)
2. PhpSpreadsheet (full Excel with formatting)
3. Third-party API

**Decision:** Chose PhpSpreadsheet

**Rationale:**
- Rich formatting (headers, colors, column widths)
- Multi-sheet support (future: multiple tabs)
- Native Excel format (better UX for admins)
- Open source (no licensing cost)

**Consequences:**
- Higher memory usage (addressed with chunk processing)
- Longer generation time (acceptable with async processing)

---

### Decision 2: Queue-based Processing

**Context:** Large datasets (10k+ users) cause timeouts

**Options:**
1. Sync processing
2. Queue-based async processing
3. Streaming response

**Decision:** Chose queue-based async processing

**Rationale:**
- No timeout limits
- Better resource management
- User gets immediate response
- Can retry failed exports

**Consequences:**
- Requires queue infrastructure (already have Laravel Queue)
- Need status polling mechanism
- Slightly more complex flow

---

## Implementation Notes

### Key Files Changed

```
src/
├── Controller/
│   └── Api/
│       └── ExportController.php (new)
├── Service/
│   └── Export/
│       ├── ExportService.php (new)
│       └── ExportGenerator.php (new)
├── Jobs/
│   └── ExportJob.php (new)
├── Repository/
│   └── ExportRepository.php (new)
└── Entity/
    └── ExportJob.php (new)
```

### Code Highlights

**Chunk processing to avoid memory issues:**
```php
public function generateExport(ExportJob $job) {
    $users = $this->userRepository->chunked(1000);

    foreach ($users as $chunk) {
        $this->appendToSheet($sheet, $chunk);
        gc_collect_cycles(); // Free memory
    }
}
```

### Gotchas & Considerations

- **Memory:** PhpSpreadsheet can use lots of memory. Use chunking and gc_collect_cycles()
- **Queue timeout:** Set queue timeout > expected export time (default: 120s, set to 300s)
- **S3 permissions:** Ensure queue worker has S3 write access
- **Cleanup:** Scheduled job runs daily to delete exports > 7 days old

---

## Testing

### Test Coverage

- Unit tests: 95% (ExportService, ExportGenerator)
- Integration tests: 90% (ExportController, ExportJob)
- E2E tests: Key user flows covered

### Test Scenarios

1. **Small export (< 1000 users):**
   - Given: 500 users in database
   - When: Admin triggers export
   - Then: Excel generated with all 500 users

2. **Large export (> 1000 users):**
   - Given: 15,000 users in database
   - When: Admin triggers export
   - Then: Job queued, processed in chunks, email sent

---

## Related Work

### Similar Past Implementations

- **EXPORT-200:** Report export feature
  - What we learned: Async processing essential for large datasets
  - What we reused: Queue job structure, S3 upload pattern

### Dependencies

- **Blocks:** None
- **Blocked by:** None
- **Related:** EXPORT-200 (similar export pattern)

---

## Lessons Learned

### What Went Well

- Queue-based approach handled large datasets without issues
- PhpSpreadsheet formatting well-received by admins
- Chunk processing prevented memory issues

### What Could Be Improved

- Add progress indicator (currently just "processing")
- Consider export templates for custom fields
- Add ability to schedule recurring exports

### Recommendations for Similar Work

- Always use async processing for exports > 1000 records
- Chunk processing essential with PhpSpreadsheet
- Set queue timeout higher than expected processing time
- Test with production-scale data volumes

---

**Tags:** export, excel, queue, user-data, phpspreadsheet

**Archived by:** Archivist Agent
**Archived on:** YYYY-MM-DD
```

## Search Results Example

When archivist searches for "export excel", it returns:

```json
{
  "results": [
    {
      "id": "USER-123",
      "title": "User data export to Excel with async processing",
      "relevance": 0.95,
      "summary": "Queue-based async processing with PhpSpreadsheet. Handles 10k+ users without timeout. S3 storage with 7-day retention.",
      "tags": ["export", "excel", "queue", "user-data"],
      "date": "YYYY-MM-DD",
      "match_reason": "High keyword match: 'export', 'excel'. Similar components: ExportService."
    }
  ],
  "total": 1,
  "query": "export excel",
  "execution_time_ms": 45
}
```

## Usage in Workflow

### Stage 3: Archivist Finds Similar Work

When working on new ticket "REPORT-555: Export reports to Excel":

```
Stage 3: Deep Dive (running in parallel)
├─ archaeologist: Analyzing current codebase...
├─ archivist: Searching for similar past work...
│  └─ Found: USER-123 (95% similarity)
│     "User data export to Excel with async processing"
│     Patterns: Queue-based async, PhpSpreadsheet, S3 storage
├─ data-modeler: Analyzing database schema...
└─ business-analyst: [waiting for inputs]

Archivist suggests loading USER-123 for context. Load? [y/n]
```

If yes, Stage 4 synthesis includes:

```markdown
## Historical Context (from archivist)

Similar work: USER-123 (User export feature)
- Used PhpSpreadsheet with queue-based async processing
- Handled 10k+ records without timeout
- Key lesson: Chunk processing prevents memory issues
- Recommendation: Reuse ExportService pattern

## Recommended Approach

Following USER-123 pattern:
1. Create ReportExportService (similar to ExportService)
2. Use queue-based async processing
3. Store in S3 with 7-day retention
4. Implement chunk processing for large datasets
```

---

This example shows how a populated requirements repository provides rich historical context for future work.
