# Team Mode Protocol

This file documents the three team-mode-only steps. Skip all of these when `EXEC_MODE == "subagent"`.

---

## Stage 2.1: Create Team and Task Graph

```
TeamCreate(team_name="req-{identifier}")
```

Update state:
```json
{
  "team": {
    "name": "req-{identifier}",
    "created": true
  }
}
```

Create task graph with dependencies using TaskCreate:

```
T1: "Run context-builder discovery" (no deps)
T2: "Run archaeologist deep-dive" (blocked by T1)
T2b: "Run architect deep-dive" (blocked by T1)
T3: "Run data-modeler deep-dive" (blocked by T1) — if applicable
T4: "Run integration-analyst deep-dive" (blocked by T1) — if applicable
T5: "Run aws-architect deep-dive" (blocked by T1) — if applicable
T6: "Run security-requirements deep-dive" (blocked by T1) — if applicable
T7: "Run archivist deep-dive" (blocked by T1) — if applicable
T8: "Run product-expert deep-dive" (blocked by T1) — if applicable
T9: "Run business-analyst synthesis" (blocked by ALL deep-dive tasks)
```

Use TaskUpdate to set `addBlockedBy` relationships.

---

## Stage 3.3: Monitor and Cross-Pollinate

While teammates are running:

1. Monitor progress via TaskList
2. When an agent finishes:
   a. **Read** `$WORK_DIR/{identifier}/context/{completed-agent}.md`
   b. **Distill** the findings into a summary of **at most 10 lines**: the key decision(s), 2–3 evidence bullets with file:line references, and any signal that affects another agent's scope. Do NOT pass the full document.
   c. Use SendMessage to notify still-running agents with the distilled summary:
   ```
   SendMessage(
     type="message",
     recipient="{agent-name}",
     content="From {completed-agent} (treat as settled):
   - Decision: {one line}
   - Evidence: {file:line}, {file:line}, {file:line}
   - Impact on you: {one line, if any}
   Read $WORK_DIR/{identifier}/context/{completed-agent}.md ONLY if you need code references beyond the above.",
     summary="{completed-agent} decision summary"
   )
   ```
3. Repeat for each agent that finishes while others are still running

**Why summaries, not file pointers:** Passing the full 200–300 line document causes downstream agents to re-validate settled decisions, which the business-analyst then re-reads on every synthesis pass. A 10-line decision summary preserves the cross-pollination signal without the duplication tax.

---

## Stage 4.8.5: Shutdown Team

Send shutdown requests to all teammates:

```
SendMessage(type="shutdown_request", recipient="context-builder", content="Work complete")
SendMessage(type="shutdown_request", recipient="archaeologist", content="Work complete")
... (for each spawned teammate)
```

After all teammates have shut down:

```
TeamDelete()
```

Update state:
```json
{
  "team": {
    "name": "req-{identifier}",
    "created": true,
    "deleted": true
  }
}
```
