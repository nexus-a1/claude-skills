# Stage 4.5: Resolve Flagged Issues

**Goal**: If the business-analyst flagged contradictions, coverage gaps, or unresolved assumptions in its output, resolve them by spawning targeted re-analysis agents.

**Check for flags**: Read the saved business-analyst output at `$WORK_DIR/{identifier}/context/business-analyst.md`. Look for:
- Explicit contradiction flags between agent findings
- Coverage gaps (areas no agent analyzed)
- Challenged assumptions or severity mismatches

**If NO flags found**: Update state and skip to Stage 4.9 (Update Final State).

```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "resolve_flags": {"stage": 4.5, "status": "skipped", "reason": "no flags found"}
  }
}
```

**If flags found**: Continue with targeted re-analysis.

Update state:
```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "resolve_flags": {"stage": 4.5, "status": "in_progress", "flags_found": ["contradiction: ...", "gap: ...", "assumption: ..."]}
  }
}
```

## Sub-agent Mode (`EXEC_MODE == "subagent"`)

For each flagged issue, identify which agent(s) from Stage 3 need to provide targeted clarification. Spawn them **in parallel** via Task tool calls in a single message.

**IMPORTANT**: Do NOT re-run general analysis. Each prompt must be a SPECIFIC question about the flagged issue.

Example prompts:

```
Task 1 (contradiction resolution): subagent_type: "{agent-name}"
Prompt: Your finding about {Agent A's position} conflicts with {Agent B's finding}.
Specifically: {describe the contradiction}.
Analyze whether these two approaches can coexist, and recommend a compatible approach.
If they cannot coexist, recommend which approach should take priority and why.

Task 2 (coverage gap): subagent_type: "{appropriate-agent}"
Prompt: During synthesis, a coverage gap was identified: {describe the gap}.
No agent analyzed {gap area}. Investigate this specific area and provide findings:
- What exists currently in the codebase for {gap area}
- What changes are needed for the feature
- What risks does this gap introduce

Task 3 (assumption challenge): subagent_type: "{agent-name}"
Prompt: Your analysis assumed {describe assumption}. This assumption was challenged because {reason}.
Verify whether this assumption holds. If it does not, re-analyze your recommendation
for {specific area} under the corrected assumption.
```

Save each targeted response to `$WORK_DIR/{identifier}/context/{agent-name}-reanalysis.md`.

## Team Mode (`EXEC_MODE == "team"`)

Business-analyst sends targeted messages to relevant agents via SendMessage:

```
SendMessage(
  type="message",
  recipient="{agent-name}",
  content="Your finding about {issue} conflicts with {other agent's finding}. {specific question}. Please respond with your clarification.",
  summary="Resolve: {brief issue description}"
)
```

Collect responses from agents. Save each to `$WORK_DIR/{identifier}/context/{agent-name}-reanalysis.md`.

## Save and Update State

**VERIFICATION** (required):
```bash
# List re-analysis files
for file in $WORK_DIR/{identifier}/context/*-reanalysis.md; do
  if [[ -f "$file" ]] && [[ -s "$file" ]]; then
    echo "  ✓ $(basename $file)"
  fi
done

echo "✓ Targeted re-analysis outputs saved"
```

Update state:
```json
{
  "updated_at": "{ISO_TIMESTAMP}",
  "stages": {
    "resolve_flags": {"stage": 4.5, "status": "completed", "agents_rerun": ["agent-name", ...]}
  }
}
```
