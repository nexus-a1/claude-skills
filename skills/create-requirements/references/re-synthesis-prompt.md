# Re-Synthesis Business Analyst Prompt (Stage 4.6)

This prompt template is used when Stage 4.5 (Resolve Flagged Issues) ran and produced re-analysis files. It re-runs business-analyst to incorporate the targeted findings.

**Sub-agent mode** — Use Task tool with `subagent_type: "business-analyst"`.

**Team mode** — Use Task tool with `subagent_type: "business-analyst"`, `team_name: "req-{identifier}"`, `name: "business-analyst"`.

Prompt (same for both modes):
```
Re-synthesize requirements incorporating targeted re-analysis findings.

Feature: {feature_description}
Refined Requirements: {refined_requirements}
Work directory: $WORK_DIR/{identifier}/

CONTEXT: During initial synthesis, you flagged contradictions, coverage gaps, or
assumption issues. Targeted agents have now re-analyzed those specific issues.

Read ALL context files:
- Original agent outputs: $WORK_DIR/{identifier}/context/*.md (excluding *-reanalysis.md)
- Original discovery: $WORK_DIR/{identifier}/context/discovery.json
- Targeted re-analysis: $WORK_DIR/{identifier}/context/*-reanalysis.md (NEW — these address your flags)

Tasks:
1. Read all original context files AND the new re-analysis files
2. Incorporate the targeted re-analysis findings into your synthesis
3. If contradictions are now resolved, update the requirements accordingly
4. If contradictions STILL remain after re-analysis, document them clearly as
   "REQUIRES HUMAN DECISION" with the competing options and trade-offs — do NOT
   attempt further resolution
5. Re-prioritize requirements (MoSCoW) if the re-analysis changed priorities
6. Update risk assessment based on new findings

Produce FOUR documents, separated by the exact markers shown below. Use the **Spec-Driven triad** contract — the same four-block format as the initial synthesis (see the Stage 4.1 prompt in `SKILL.md`):

- `SPEC`   — WHAT / WHY (user stories, Given/When/Then acceptance criteria, security AC, out of scope, open questions). No file paths, no class names.
- `PLAN`   — HOW (approach, files to touch, architecture constraints, data model, integrations, risks, decision log).
- `TASKS`  — EXECUTE (dependency-ordered list; every task cites AC IDs from SPEC).
- `JIRA_TICKET` — derived paste-ready view of SPEC.

**Token budgets**: SPEC ≤1500, PLAN ≤2500, TASKS ≤1200, JIRA_TICKET ≤800.

Use this EXACT format:

---BEGIN SPEC---
(User stories + Given/When/Then AC — incorporate re-analysis findings. If any issue still requires human decision, list it under `## Open Questions`.)
---END SPEC---

---BEGIN PLAN---
(Updated technical approach. If any contradiction remains unresolved after re-analysis, add a `## Decisions Required` section with competing options and trade-offs.)
---END PLAN---

---BEGIN TASKS---
(Re-derived task list. Ensure every AC in SPEC is covered; update dependencies if re-analysis changed the shape of the work.)
---END TASKS---

---BEGIN JIRA_TICKET---
(Paste-ready view of SPEC. If any issue requires human decision, note it briefly under a `**Decisions Required**` subsection.)
---END JIRA_TICKET---

IMPORTANT: Use the exact ---BEGIN/END--- markers. They are used to extract each document into separate files. Do NOT include HOW details in SPEC or JIRA_TICKET.
```

**Team mode extra**: Add to prompt: `"Mark your task as completed when done."`
