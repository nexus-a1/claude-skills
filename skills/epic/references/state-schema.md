# Epic State Schema

JSON schema for `$WORK_DIR/{epic-id}/state.json`.

```json
{
  "schema_version": 1,
  "type": "epic",
  "identifier": "{epic-id}",
  "title": "{Epic Title}",
  "description": "{Full description}",
  "status": "planning",
  "created_at": "{ISO timestamp}",
  "updated_at": "{ISO timestamp}",

  "agents_used": {
    "always": ["business-analyst", "architect"],
    "specialists": ["data-modeler", "security-requirements"]
  },

  "tickets": [
    {
      "slug": "{epic-ticket}-001-{slug}",
      "title": "{Title}",
      "type": "database",
      "estimate": "small",
      "status": "pending",
      "blocked_by": [],
      "blocks": ["{epic-ticket}-002-{slug}", "{epic-ticket}-004-{slug}"],
      "spec_file": "{epic-ticket}-001-{slug}/spec.md",
      "implementation_status": null
    },
    {
      "slug": "{epic-ticket}-002-{slug}",
      "title": "{Title}",
      "type": "backend",
      "estimate": "medium",
      "status": "pending",
      "blocked_by": ["{epic-ticket}-001-{slug}"],
      "blocks": ["{epic-ticket}-005-{slug}"],
      "spec_file": "{epic-ticket}-002-{slug}/spec.md",
      "implementation_status": null
    }
  ],

  "waves": [
    {
      "wave": 1,
      "tickets": ["{epic-ticket}-001-{slug}", "{epic-ticket}-003-{slug}"],
      "status": "pending"
    },
    {
      "wave": 2,
      "tickets": ["{epic-ticket}-002-{slug}", "{epic-ticket}-004-{slug}"],
      "status": "pending"
    }
  ],

  "progress": {
    "total_tickets": 6,
    "completed": 0,
    "in_progress": 0,
    "pending": 6
  }
}
```
