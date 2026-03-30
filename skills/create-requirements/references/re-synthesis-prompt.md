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

Produce TWO documents, separated by the exact markers shown below.

Use this EXACT format:

---BEGIN TECHNICAL_REQUIREMENTS---
(Complete technical specification for developers — updated with re-analysis findings)
- Full implementation details
- File paths and code references
- Data schemas
- API contracts
- Error handling
- Performance requirements
- If any issues required human decision, include a "Decisions Required" section
---END TECHNICAL_REQUIREMENTS---

---BEGIN JIRA_TICKET---
(Light version for JIRA - business + developer overview — updated)
- Summary (1 paragraph)
- Background (problem, impact, solution)
- Requirements (business terms)
- Acceptance criteria
- Technical notes (2-3 bullets max)
- Out of scope
- If any issues required human decision, note them in Technical notes
---END JIRA_TICKET---

IMPORTANT: Use the exact ---BEGIN/END--- markers. They are used to extract each document into separate files.
```

**Team mode extra**: Add to prompt: `"Mark your task as completed when done."`
