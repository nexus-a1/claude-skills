# Implementation State File Schema

`$WORK_DIR/{identifier}/state.json`:

```json
{
  "schema_version": 1,
  "type": "implementation",
  "identifier": "JIRA-123",
  "status": "in_progress",
  "started_at": "2024-01-15T10:00:00Z",
  "completed_at": null,

  "phases": {
    "plan": {"status": "completed"},
    "implement": {"status": "in_progress", "chunks_completed": 2, "chunks_total": 3},
    "qa": {"status": "pending", "note": "tests + review + security run in parallel"},
    "qa_gate": {
      "status": "pending",
      "findings": {
        "critical": {"total": 0, "resolved": 0, "unresolved": 0},
        "important": {"total": 0},
        "minor": {"total": 0}
      },
      "auto_fixes_applied": 0,
      "auto_fixes_failed": 0,
      "gate_result": null,
      "report_path": null
    },
    "pr": {"status": "pending"}
  },

  "plan": {
    "chunks": [
      {"id": 1, "description": "Create service", "files": ["..."], "status": "completed", "commit": "abc123"},
      {"id": 2, "description": "Add endpoint", "files": ["..."], "status": "completed", "commit": "def456"},
      {"id": 3, "description": "Add UI", "files": ["..."], "status": "pending"}
    ]
  },

  "implemented_files": ["src/Service/...", "src/Controller/..."],
  "commits": ["abc123", "def456"],
  "pr": null,

  "updates": [
    {"timestamp": "2024-01-15T14:22:00Z", "note": "Discovered webhook requirement — adds scope to chunk 3"}
  ]
}
```
