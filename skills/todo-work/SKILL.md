---
name: todo-work
model: haiku
category: project-setup
description: List pending items from TODO.md, pick one, mark it In progress, and propose a hand-off to /review-plan or /implement.
argument-hint: "[item number]"
userInvocable: true
allowed-tools: Read, Edit, AskUserQuestion
---

# Work on a TODO Item

Companion to `/todo`. Surfaces pending items from `TODO.md`, lets the user pick one, optionally marks it as `In progress`, and proposes a hand-off to the downstream skill (`/review-plan` or `/implement`) by printing the exact command to run next.

## Purpose

`/todo` is append-only — it captures items but never surfaces them back out. This skill closes the loop: read `TODO.md`, filter to pending items, pick one, and kick off work with a single interactive flow.

## When to Use

- Picking the next item to work on from `TODO.md`
- Starting ad-hoc work captured earlier in the session
- Deciding whether an item needs plan validation before implementation

## When NOT to Use

- Adding a new item → `/todo`
- Resuming an in-flight skill session → `/resume-work`
- Listing active work sessions (not TODO items) → `/status`

## Arguments

```bash
/todo-work [item number]
```

**item number** (optional): 1-indexed position in the sorted pending list. If provided, skip the pick question and jump to the next-action question.

---

## Process

### Step 1: Locate and Read TODO.md

```bash
TODO_FILE="TODO.md"
```

If `TODO.md` does not exist in the project root, stop with:

```
No TODO.md found in the project root. Use /todo to add your first item.
```

Otherwise, read the full file with the Read tool.

### Step 2: Parse Pending Items

Extract every `### {title}` block. For each block, pull these fields (match case-insensitively, accept the value on the same line):

- `**Status:** {status}`
- `**Priority:** {priority}` (strip leading emoji)
- `**Category:** {category}`
- `**Scope:** {scope}`

Plus the free-text description (everything between the metadata block and the next `---` or `### ` heading or end-of-file).

**Keep only pending items.** An item is pending if its status matches (case-insensitive): `Proposed`, `Not started`, `Needs discussion`. Skip anything else (`In progress`, `Done`, `Completed`, `Archived`, etc.).

If the item is missing any of the four metadata fields, treat the missing field as `unknown` — do not drop the item. Record which field was missing so the list display can flag it with `(missing metadata)`.

### Step 3: Sort

Sort pending items by priority (emergency → high → medium → low → unknown), with document order as tiebreaker. Number them 1..N in the sorted order; this number is what the optional `[item number]` argument selects and what the user sees in the list.

Priority sort key (higher wins):
- `emergency` = 4
- `high` = 3
- `medium` = 2
- `low` = 1
- anything else = 0

### Step 4: Handle Empty Result

If zero pending items, stop with:

```
No pending TODO items. Use /todo to add one, or /status to see active work sessions.
```

### Step 5: Pick Item

**If `$ARGUMENTS` contains a positive integer N and 1 ≤ N ≤ count(pending):** Use item N. Skip this step's AskUserQuestion.

**Otherwise:** Display the top 4 items and use AskUserQuestion to pick:

- header: `"Pick item"`
- question: `"Which TODO item should we work on?"`
- options (up to 4; each label is short, description shows priority + category + scope):
  - `{title}` / `priority · category · scope`
  - ... up to 4 ...
  - `Cancel` / `Don't start any item — exit`
- multiSelect: `false`

If more than 4 pending items exist, include this note above the question: *"Showing top 4 by priority. {count-4} more in TODO.md — re-run with `/todo-work {N}` to select a different one."*

If the user picks `Cancel`, stop with: `No item selected.`

### Step 6: Confirm Next Action

Display the selected item:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Selected: {title}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Priority: {priority}
Category: {category}
Scope:    {scope}
Status:   {status}

{description — if present}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then use AskUserQuestion:

- header: `"Next action"`
- question: `"How do you want to start on this item?"`
- options:
  - `"Validate plan first (Recommended for non-trivial)"` / `"Hand off to /review-plan — architect and quality-guard review the plan before implementation"`
  - `"Implement directly"` / `"Hand off to /implement — skip plan review, go straight to coding"`
  - `"Just show details"` / `"Print the item and stop — no handoff, no status change"`
- multiSelect: `false`

### Step 7: Mark In Progress (unless show-details-only)

**If the user chose `Just show details`:** Skip to Step 9. Do not modify `TODO.md`.

**Otherwise:** Update the selected item's status line in `TODO.md` from its current value to `In progress` using the Edit tool.

Find the exact line by matching the heading + the Status line belonging to this item. Use this Edit pattern:

```
old_string:
### {title}

**Status:** {current_status}

new_string:
### {title}

**Status:** In progress
```

If the Edit fails (e.g., because `{title}` or `{current_status}` is not unique in the file), surface a warning and continue without updating — do not abort the handoff:

```
⚠️  Could not mark item as In progress (status line not unique in TODO.md).
    Handoff will proceed; update the status manually if needed.
```

### Step 8: Propose Hand-off

Print a hand-off block that shows the user the exact command to run next. Do not invoke another skill — slash commands are user-invoked; `/todo-work` stops after printing.

**For `Validate plan first` → `/review-plan`:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Handing off to /review-plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Item:    {title}
Status:  {Proposed|Not started|Needs discussion} → In progress

Run next:

  /review-plan {title}
  {if description present:}
  {description}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**For `Implement directly` → `/implement`:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Handing off to /implement
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Item:    {title}
Status:  {Proposed|Not started|Needs discussion} → In progress

Run next:

  /implement {title}
  {if description present:}
  Context from TODO.md:

  {description}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**For `Just show details`:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  {title}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Priority: {priority}
Category: {category}
Scope:    {scope}
Status:   {status}   (unchanged)

{description — if present}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Examples

### Example 1: Pick interactively, validate plan first

```bash
/todo-work
```

Lists pending items sorted by priority. User picks item #2 ("Add webhook support"). Chooses "Validate plan first". Skill updates status to `In progress` and prints the hand-off block with `/review-plan Add webhook support` (plus the description) as the suggested next command.

### Example 2: Direct selection by number, implement directly

```bash
/todo-work 1
```

Jumps straight to item #1 ("Fix broken link in README"). User chooses "Implement directly". Status flips to `In progress`; the skill prints `/implement Fix broken link in README` as the next command to run.

### Example 3: Show details only, no status change

```bash
/todo-work
```

User picks item #3, chooses "Just show details". No Edit to `TODO.md`, no hand-off — just prints the item details and stops.

### Example 4: No pending items

```bash
/todo-work
```

Output:

```
No pending TODO items. Use /todo to add one, or /status to see active work sessions.
```

---

## Error Handling

### TODO.md missing
```
No TODO.md found in the project root. Use /todo to add your first item.
```

### All items completed/in-progress (none pending)
```
No pending TODO items. Use /todo to add one, or /status to see active work sessions.
```

### Argument out of range (e.g., `/todo-work 99` when 5 items pending)
```
No item #99 — only 5 pending items. Re-run /todo-work to pick interactively.
```

### Status line not unique when attempting mark-In-progress
Warn and continue with the handoff (see Step 7).

---

## Notes

- **Stateless** — no `.claude/work/` files, no configuration dependency
- **Read + targeted Edit** — only touches `TODO.md` via one `Status:` line change
- **Handoff is passive** — prints the proposed next command; does not auto-launch a skill, because slash commands are user-invoked
- **Priority ordering is stable** — document order is the tiebreaker within a priority tier
- **Missing metadata tolerated** — items with partial fields are listed with an `(missing metadata)` marker, not dropped
