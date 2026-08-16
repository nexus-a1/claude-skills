# Manifest Schema Reference

Shared envelope, per-artifact schemas, and update logic for `manifest.json` files. Read this from skills instead of linking to repo-root `docs/` (which isn't shipped with the plugin). Full narrative version with rationale: `docs/manifest-system.md` in the source repo.

> The requirements knowledge base uses its own `index.json` with richer metadata — not covered here.

## Common Envelope

Every `manifest.json` shares this outer structure:

```json
{
  "version": "1.0",
  "last_updated": "2026-02-10T12:00:00Z",
  "artifact_type": "<type>",
  "total_items": 0,
  "items": []
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Schema version. Currently `"1.0"`. |
| `last_updated` | ISO-8601 | Timestamp of the last write to this manifest. |
| `artifact_type` | string | One of: `work`, `brainstorms`, `proposals`, `refactoring`, `product-knowledge`, `meetings`. |
| `total_items` | integer | Count of items in the `items` array. |
| `items` | array | Artifact-specific item objects (see below). |

## Per-Artifact Item Schemas

### Work (`{WORK_DIR}/manifest.json`)

```json
{
  "identifier": "JIRA-123",
  "title": "User Export Feature",
  "type": "requirements|implementation|proposal|epic",
  "status": "in_progress|completed",
  "created_at": "2026-02-10T12:00:00Z",
  "updated_at": "2026-02-10T14:30:00Z",
  "current_phase": "implement",
  "progress": "2/3 chunks",
  "branch": "feature/JIRA-123",
  "tags": [],
  "path": "JIRA-123/"
}
```

Unique key: `identifier`. Required: `identifier`, `title`, `type`, `status`, `created_at`, `updated_at`, `path`.

### Brainstorms (`{BRAINSTORM_DIR}/manifest.json`)

```json
{
  "slug": "user-authentication",
  "title": "User Authentication Options",
  "status": "in_progress|completed|promoted",
  "created_at": "2026-02-10T12:00:00Z",
  "updated_at": "2026-02-10T14:30:00Z",
  "current_phase": "approaches",
  "selected_approach": "JWT with refresh tokens",
  "alternatives_count": 3,
  "promoted_to": "JIRA-123",
  "tags": [],
  "path": "user-authentication/"
}
```

Unique key: `slug`. Required: `slug`, `title`, `status`, `created_at`,
`updated_at`, `path`.

Brainstorms carry **both** catalog fields (`selected_approach`,
`alternatives_count`) and session fields (`status`, `current_phase`,
`updated_at`). A brainstorm is a resumable session until it is promoted, so
`/resume-work` and `/work-status` read this manifest alongside the work
manifest. `promoted_to` holds the requirements identifier once
`/brainstorm promote` or `/create-requirements --from-brainstorm` has run;
it is `null` beforehand.

### Proposals (`{PROPOSALS_DIR}/manifest.json`)

```json
{
  "name": "sso-integration",
  "title": "SSO Integration with Azure AD",
  "status": "draft|final|implemented",
  "created_at": "2026-02-10T12:00:00Z",
  "updated_at": "2026-02-10T14:30:00Z",
  "iterations": 2,
  "tags": [],
  "path": "sso-integration/"
}
```

Unique key: `name`. Required: `name`, `title`, `status`, `created_at`, `updated_at`, `path`.

### Refactoring (`{REFACTOR_DIR}/manifest.json`)

```json
{
  "session_name": "user-service-cleanup",
  "title": "Extract UserService from Controller",
  "status": "in_progress|completed|paused",
  "created_at": "2026-02-10T12:00:00Z",
  "updated_at": "2026-02-10T14:30:00Z",
  "files_affected": 5,
  "progress": "3/7",
  "tags": [],
  "path": "user-service-cleanup/"
}
```

Unique key: `session_name`. Required: `session_name`, `title`, `status`, `created_at`, `updated_at`, `path`.

### Product Knowledge (`{PRODUCT_DIR}/manifest.json`)

Scan-built (no write hooks) — the `product-expert` agent builds/refreshes this on startup when missing or stale (>24h).

```json
{
  "version": "1.0",
  "last_updated": "2026-02-10T12:00:00Z",
  "artifact_type": "product-knowledge",
  "total_items": 15,
  "items": [
    {
      "path": "apis/authentication.md",
      "title": "Authentication API",
      "category": "api",
      "tags": ["auth", "jwt"],
      "summary": "JWT-based authentication with refresh tokens"
    }
  ],
  "categories": {"api": 5, "architecture": 3},
  "tags": {"auth": 10, "jwt": 5}
}
```

Unique key: `path`. Extra top-level fields: `categories` (name→count), `tags` (name→frequency).

### Meetings (`{MEETINGS_DIR}/manifest.json`)

```json
{
  "path": "2026-08-16-1400-planning-sync/",
  "slug": "planning-sync",
  "title": "Planning Sync",
  "status": "wrapped",
  "date": "2026-08-16",
  "created_at": "2026-08-16T14:00:00Z",
  "updated_at": "2026-08-16T14:45:00Z",
  "promoted_to": null,
  "tags": []
}
```

**Unique key: `path`, not `slug`.** This is the one artifact type where that
distinction matters: recurring meetings deliberately reuse the same `slug`
across multiple timestamped directories (see the Work Directory Naming
Convention's meeting exception in `CLAUDE.md`) — a `slug`-keyed upsert would
silently overwrite an earlier occurrence's entry every time the same
recurring meeting wraps again. `path` is unique by construction (the
directory-collision-avoidance loop that creates it), so it is the only safe
key here.

Required: `path`, `slug`, `title`, `status`, `created_at`, `updated_at`.
`title` comes from the meeting's `topic` field (captured at creation, not
scraped from a document header — see `/meeting`'s Step L1). `status` keeps
`/meeting`'s own native kebab-case value (`wrapped`) deliberately, rather
than translating to this schema's snake_case convention elsewhere —
translating would desync the manifest from the meeting's own `state.json`,
which is the source of truth.

**Written once, at wrap only** — not at creation, unlike every other
artifact type in this file. Because of that, `wrapped` is the only value
that ever actually appears here: an in-progress meeting has no `summary.md`/
`changes.md` yet (what `/create-requirements --from-meeting` seeds from), so
it isn't cataloged — and isn't a valid candidate for that flow — until wrap
produces them. (The meeting's own `state.json` does pass through an
`in-progress` status before that, but this manifest entry doesn't exist
yet at that point to carry it.)

**Deliberately excluded**: `probed`/`findings` arrays and other
session-internal detail. This manifest is a catalog for picking a meeting
to seed from, not a mirror of the meeting's full state — mirrors how the
Brainstorms schema above carries `alternatives_count` (a summary int)
rather than the full alternatives array.

## Update Operations

**Initialize** (if `manifest.json` doesn't exist): write the Common Envelope above with `total_items: 0`, `items: []`, and the correct `artifact_type`.

**Upsert item:**
1. Read `manifest.json` (or initialize if missing).
2. Search `items` for an entry matching the artifact's unique key (table above).
3. If found: replace the entry with updated fields. If not found: append it.
4. Update `last_updated` to the current ISO-8601 timestamp and `total_items` to `items.length`.
5. Write `manifest.json`.

**Remove item:** filter out the matching entry, update `last_updated`/`total_items`, write.

## Error Handling

| Condition | Action |
|-----------|--------|
| Manifest missing | Initialize empty manifest, then proceed with upsert. |
| Manifest is invalid JSON | Log warning, back up corrupt file as `manifest.json.corrupt`, create fresh manifest. |
| Item has missing required fields | Log warning, skip the item during rebuild. |
| Artifact directory doesn't exist | Skip silently (nothing to index). |

## Reading Manifests

1. Check the manifest exists — if not, fall back to directory scanning.
2. Parse JSON — if parse fails, fall back to directory scanning.
3. Filter items by `status`, `type`, or other fields as needed.
4. Trust but verify — the manifest is a cache; if an item's `path` doesn't exist on disk, skip it.
