---
name: add-product-knowledge
model: claude-sonnet-4-6
category: context-indexing
description: Add a new entry to the product knowledge base. Wizard-guided — prompts for category, title, and content, then writes a structured markdown file and rebuilds the manifest.
argument-hint: "[title]"
userInvocable: true
allowed-tools: "Read, Write, Bash(yq:*), Bash(jq:*), Bash(find:*), Bash(git:*), Bash(date:*), Bash(mkdir:*), Bash(mv:*), Bash(mktemp:*), Bash(tr:*), Bash(sed:*), Bash(xargs:*), Bash(basename:*), Bash(sort:*), AskUserQuestion"
---

# Add Product Knowledge

Add a new entry to the product knowledge base used by the `product-expert` agent.

## Purpose

Use this skill to capture product context mid-conversation — after a requirements session, after debugging a complex domain flow, or when you learn something about the product that should be preserved for future sessions.

The `product-expert` agent reads all `.md` files in the configured `product-knowledge` directory. This skill creates a properly-structured file and updates the manifest so the new entry is immediately searchable.

## Arguments

```bash
/add-product-knowledge                  # Full wizard
/add-product-knowledge Payment Flow     # Pre-fill title, wizard for rest
```

## Context

Arguments: $ARGUMENTS

---

## Configuration

```bash
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found. Install via marketplace or run ./install.sh" >&2
  exit 1
fi

IFS='|' read -r KB_PATH _TYPE <<< "$(resolve_artifact_typed product-knowledge .)"
if [[ ! -d "$KB_PATH" ]]; then
  echo "ERROR: Knowledge base directory not found: $KB_PATH" >&2
  exit 1
fi
```

If the location type is `git`, sync before writing:

```bash
if [[ "$_TYPE" == "git" ]]; then
  git -C "$KB_PATH" pull --ff-only 2>/dev/null || true
fi
```

---

## Workflow

### Step 1: Resolve title

Parse `$ARGUMENTS`. If non-empty, treat the full string as the initial title suggestion.

If `$ARGUMENTS` is empty, use `AskUserQuestion`:

```
What do you want to document?
(e.g. "Payment Flow Architecture", "Auth Token Lifecycle", "Subscription Tier Rules")
```

Store as `{title}`.

### Step 2: Choose category

List existing categories (subdirectories of `$KB_PATH`):

```bash
find "$KB_PATH" -mindepth 1 -maxdepth 1 -type d -not -name '.*' \
  | xargs -I{} basename {} | sort
```

Use `AskUserQuestion` with the list as options plus "other":

```
Category for "{title}":
1. architecture
2. api
3. business-rules
4. data-models
... (existing categories)
N. other (enter a new category name)
```

Store as `{category}`. If "other", ask for the new category name.

### Step 3: Gather content

Use `AskUserQuestion`:

```
What should this entry document?

You can:
- Describe it in plain text (I'll structure it)
- Paste existing notes or diagrams
- Say "from conversation" to extract from our current discussion
```

Store as `{raw_content}`.

If the user says "from conversation", extract the most relevant product/domain insight from the current conversation context — focus on business rules, architecture patterns, API contracts, data models, or workflow states. Exclude code-level details (those belong to `archaeologist`).

### Step 4: Structure the content

Based on `{category}`, produce structured markdown using the appropriate template:

**architecture** — system components, integration patterns, service boundaries, data flow
**api** — endpoints, request/response shapes, auth requirements, rate limits
**business-rules** — domain logic, validation rules, workflow states, edge cases
**data-models** — entity definitions, field constraints, relationships, lifecycle
**other** — freeform with headings derived from the content

Keep it factual and cite evidence where possible. No speculation. If something is uncertain, mark it `*(unverified)*`.

### Step 5: Derive filename

```bash
# Slugify the title
SLUG=$(echo "{title}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
DEST="$KB_PATH/{category}/${SLUG}.md"
```

Check if the file already exists:

```bash
if [[ -f "$DEST" ]]; then
  # Show the user what's there and ask: overwrite, rename, or cancel
fi
```

### Step 6: Write the file

Write `$DEST` with this structure:

```markdown
---
tags: [{derived tags}]
---

# {title}

{structured content}
```

Tags are inferred from the title and content — use 3–6 short lowercase terms.

Create the category directory if it doesn't exist:

```bash
mkdir -p "$KB_PATH/{category}"
```

### Step 7: Rebuild manifest

Invalidate the manifest so `product-expert` picks up the new file immediately:

```bash
MANIFEST="$KB_PATH/manifest.json"
if [[ -f "$MANIFEST" ]]; then
  # Touch last_updated to force product-expert to rebuild on next read
  _TMP=$(mktemp) && jq '.last_updated = "1970-01-01T00:00:00Z"' "$MANIFEST" > "$_TMP" \
    && mv "$_TMP" "$MANIFEST"
fi
```

### Step 8: Commit (git locations only)

If `$_TYPE == "git"`:

```bash
git -C "$KB_PATH" add "$DEST" "$MANIFEST"
git -C "$KB_PATH" commit -m "docs(product-knowledge): add {title}"
git -C "$KB_PATH" push
```

### Step 9: Confirm

```
✓ Knowledge base entry created

  File:     {category}/{slug}.md
  Title:    {title}
  Tags:     {tags}
  Location: $DEST

The product-expert agent will pick this up on the next invocation.
Run /rebuild-index product-knowledge to rebuild the full manifest now.
```
