# Quality Checklist (Create Requirements)

## Stage 1: Setup
- [ ] Identifier established (must be ticket number: `PROJECT-123` format)
- [ ] Feature branch created locally: `feature/{identifier}`
- [ ] Verified on feature branch (not release/main/master)
- [ ] Work directory initialized
- [ ] State file created and validated as JSON
- [ ] Execution mode read from configuration

## Stage 2: Discovery
- [ ] [TEAM] Team created and task graph set up (if team mode)
- [ ] Context inventory built
- [ ] Endpoints, services, entities identified
- [ ] Gaps documented
- [ ] Feature branch pushed to remote

## Stage 3: Deep Dive
- [ ] `.claude/configuration.yml` checked for archivist/product-expert config
- [ ] Required agents determined from discovery findings
- [ ] All applicable agents run in parallel
- [ ] [TEAM] Cross-pollination messages sent as agents complete (if team mode)
- [ ] Findings saved to context/ (discovery.json validated as JSON, others as .md)

## Stage 4: Synthesis
- [ ] Business-analyst reads context files (not inlined in prompt)
- [ ] Conflicts resolved
- [ ] Requirements prioritized (MoSCoW)
- [ ] Risks identified
- [ ] {identifier}-TECHNICAL_REQUIREMENTS.md saved
- [ ] {identifier}-JIRA_TICKET.md saved
- [ ] context/business-analyst.md saved

## Stage 4.5-4.6: Feedback Loop (Conditional)
- [ ] Business-analyst output checked for flagged contradictions, gaps, assumptions
- [ ] If no flags: stages skipped and state updated
- [ ] If flags found: targeted agents spawned with SPECIFIC questions (not general re-analysis)
- [ ] Re-analysis outputs saved to context/*-reanalysis.md
- [ ] Business-analyst re-synthesis run with original + re-analysis context
- [ ] Unresolved contradictions documented as "REQUIRES HUMAN DECISION"
- [ ] One pass only — no further iteration after re-synthesis
- [ ] Output documents overwritten with updated versions

## Stage 4.7-4.11: Finalization
- [ ] [OPTIONAL] Architecture validation for shared/core service changes
- [ ] [TEAM] All teammates shut down and team deleted (if team mode)
- [ ] State updated to completed
- [ ] Work manifest updated
- [ ] Completion report displayed
