---
name: todo
model: haiku
category: project-setup
description: Add a new item to the project TODO.md with priority, category, and scope through an interactive wizard.
argument-hint: "[title or description of the TODO item]"
userInvocable: true
allowed-tools: Read, Write, Edit, Glob, AskUserQuestion
---

# Add TODO

Interactively add a new item to the project's `TODO.md` file.

## Purpose

Quickly capture TODO items with consistent formatting, priority, category, and scope. Creates `TODO.md` if it doesn't exist, appends to it if it does.

## When to Use

- Capturing a new feature idea, bug, or improvement
- Recording a decision that needs to be made
- Adding follow-up work discovered during implementation
- Noting technical debt to address later

## Arguments

```bash
/todo [title or description]
```

**title** (optional): Short description of the TODO item.
- If provided: Used as the item title, skip the title question.
- If omitted: Ask the user for a title interactively.

---

## Process

### Step 1: Read Existing TODO.md

Check if `TODO.md` exists in the project root:

```bash
TODO_FILE="TODO.md"
```

If it exists, read it to:
- Understand existing structure and formatting
- Count existing items (for the "Related" question)
- Detect the heading style used (to match it)

If it does NOT exist, note that we'll create it fresh.

### Step 2: Collect Title

**If `$ARGUMENTS` is provided and non-empty:** Use it as the title. Skip this question.

**If no arguments:** Use AskUserQuestion:
- header: "Title"
- question: "What's the TODO item about? (short title)"
- options:
  - "Enter title" / "I'll type the title in the text field below"
  - "Cancel" / "Never mind, don't add anything"
- multiSelect: false

If user selects "Cancel", stop with: "No TODO item added."

The user's response via the "Other" text input becomes the title. If they selected "Enter title" without typing anything, ask again.

### Step 3: Ask Priority

Use AskUserQuestion:
- header: "Priority"
- question: "What priority level for this item?"
- options:
  - "Medium (Recommended)" / "Normal priority — will be addressed in due course"
  - "Low" / "Nice to have — address when convenient"
  - "High" / "Important — should be addressed soon"
  - "Emergency" / "Critical blocker — needs immediate attention"
- multiSelect: false

Map selection to priority value: `low`, `medium`, `high`, `emergency`.
Default (if somehow unclear): `medium`.

### Step 4: Ask Category

Use AskUserQuestion:
- header: "Category"
- question: "What type of work is this?"
- options:
  - "Feature" / "New functionality or enhancement"
  - "Improvement" / "Refactoring, optimization, or technical debt"
  - "Decision" / "Assessment, discussion, or architectural decision needed"
  - "Documentation" / "Docs, guides, knowledge base, or examples"
- multiSelect: false

Map selection to category value. If user selects "Other" and provides text, use that as the category.

### Step 5: Ask Scope

Use AskUserQuestion:
- header: "Scope"
- question: "How much effort do you estimate?"
- options:
  - "Medium" / "A few hours to a day of work"
  - "Quick win" / "Under an hour — small, well-defined change"
  - "Small" / "A couple hours of focused work"
  - "Large" / "Multiple days or involves significant changes"
- multiSelect: false

Map selection to scope value: `quick win`, `small`, `medium`, `large`.

### Step 6: Ask for Description

Use AskUserQuestion:
- header: "Details"
- question: "Any additional details, context, or acceptance criteria? (Select 'Other' to type details, or 'Skip' to leave blank.)"
- options:
  - "Skip" / "No additional details — the title is enough"
  - "Add later" / "Leave blank now; I'll edit TODO.md manually to add details later"
- multiSelect: false

Free-form details are captured via the built-in "Other" option. Handle the response:

- "Skip" or "Add later" → leave description empty
- "Other" with typed text → use that text as the description
- "Other" with no text → leave description empty (do not re-ask)

### Step 7: Ask About Related TODOs

**Only ask this if TODO.md exists AND has existing items.**

Scan TODO.md for existing `###` headings to extract item titles.

If there are existing items, use AskUserQuestion:
- header: "Related"
- question: "Is this related to any existing TODO items?"
- options:
  - "None" / "This is independent — no relation to existing items"
  - "Yes, I'll specify" / "I'll type the related item title in the text field"
- multiSelect: false

If user provides a related item reference, include it in the entry.

### Step 8: Format the Entry

Build the TODO entry using this format:

```markdown

---

### {Title}

**Status:** {status_from_category}
**Priority:** {priority_emoji} {Priority}
**Category:** {Category}
**Scope:** {Scope}

{Description — if provided}

{Related: {related_item} — if provided}
```

**Priority emoji mapping:**
- `low` → (no emoji)
- `medium` → (no emoji)
- `high` → 🔴
- `emergency` → 🚨

**Status mapping from category:**
- Feature → `Proposed`
- Improvement → `Proposed`
- Decision → `Needs discussion`
- Documentation → `Not started`
- Other → `Proposed`

### Step 9: Write to TODO.md

**If TODO.md does NOT exist:**

Create a new file with the standard header and the entry:

```markdown
# TODO

## Pending

{formatted_entry}
```

Use the Write tool.

**If TODO.md exists:**

Append the formatted entry to the end of the file using the Edit tool. Find a suitable insertion point:

1. If the file has a `## Pending` section, append before the next `## ` heading (or at end of file).
2. If no `## Pending` section exists, append at the end of the file.

### Step 10: Show Confirmation

Display a summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  TODO Added
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Title:    {title}
Priority: {priority}
Category: {category}
Scope:    {scope}
Status:   {status}
{Related: {related} — if applicable}

Written to: TODO.md
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Examples

### Example 1: Quick Add with Argument

```bash
/todo Add retry logic to API client
```

Skips the title question, asks priority/category/scope/details.

### Example 2: Full Interactive

```bash
/todo
```

Asks all questions: title → priority → category → scope → details → related.

### Example 3: Minimal Entry

```bash
/todo Fix broken link in README
```

Select: Medium priority, Documentation, Quick win, Skip details.

Result:

```markdown
---

### Fix broken link in README

**Status:** Not started
**Priority:** Medium
**Category:** Documentation
**Scope:** Quick win
```

### Example 4: High Priority Feature

```bash
/todo
```

Enter title: "Add webhook support for event notifications"
Select: High priority, Feature, Large, enter detailed description.

Result:

```markdown
---

### Add webhook support for event notifications

**Status:** Proposed
**Priority:** 🔴 High
**Category:** Feature
**Scope:** Large

Need to support outbound webhooks so external systems can subscribe to events (user created, order completed, etc.). Should include retry logic, signature verification, and a management UI for configuring endpoints.
```

## Error Handling

### TODO.md Is Read-Only or in a Protected Location

```
Unable to write to TODO.md — check file permissions.
```

### Empty Title

If the user provides no title (empty argument and empty text input), ask again once. If still empty:

```
Cannot add a TODO item without a title. Try again with: /todo [your title]
```

## Notes

- **Appends only**: Never modifies or reorders existing entries
- **Format-preserving**: Matches the existing TODO.md style if one exists
- **Lightweight**: No state files, no configuration needed — just TODO.md
- **Works anywhere**: No dependency on `.claude/configuration.yml`
