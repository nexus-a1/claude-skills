# Epic State Schema

JSON schema for `$WORK_DIR/{epic-slug}/state.json`.

```json
{
  "schema_version": 1,
  "type": "epic",
  "identifier": "{epic-slug}",
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
      "slug": "{epic-slug}-001",
      "title": "{Title}",
      "type": "database",
      "estimate": "small",
      "status": "pending",
      "blocked_by": [],
      "blocks": ["{epic-slug}-002", "{epic-slug}-004"],
      "requirements_file": "{epic-slug}-001/{epic-slug}-001-TECHNICAL_REQUIREMENTS.md",
      "implementation_status": null
    },
    {
      "slug": "{epic-slug}-002",
      "title": "{Title}",
      "type": "backend",
      "estimate": "medium",
      "status": "pending",
      "blocked_by": ["{epic-slug}-001"],
      "blocks": ["{epic-slug}-005"],
      "requirements_file": "{epic-slug}-002/{epic-slug}-002-TECHNICAL_REQUIREMENTS.md",
      "implementation_status": null
    }
  ],

  "waves": [
    {
      "wave": 1,
      "tickets": ["{epic-slug}-001", "{epic-slug}-003"],
      "status": "pending"
    },
    {
      "wave": 2,
      "tickets": ["{epic-slug}-002", "{epic-slug}-004"],
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
