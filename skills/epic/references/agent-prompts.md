# Epic Agent Prompts

Prompt templates for Phase 2 (always-run agents) and Phase 2.5.2 (conditional specialist agents).

## Phase 2: Always-run Agents

### business-analyst

```
Analyze this initiative and break it down:

Epic: {description}

Requirements:
1. Identify major components/features needed
2. Understand technical scope (frontend, backend, DB, infrastructure)
3. Identify external dependencies (APIs, services)
4. Consider security/compliance requirements
5. Estimate overall complexity

Provide:
- List of major components
- Technical areas involved
- Dependencies and constraints
- Risk factors
```

### architect

```
Review the technical approach for this initiative:

Epic: {description}
Components identified: {from business-analyst}

Validate:
1. Architecture patterns to use
2. Layer compliance
3. File structure/organization
4. Integration points
5. Any architectural risks

Provide:
- Recommended architecture approach
- File structure suggestions
- Integration strategy
- Risk mitigation
```

Run both agents in parallel.

## Phase 2.5.2: Conditional Specialist Agents

Run only the agents whose Phase 2 signals matched. Execute all applicable agents in a single message with multiple Task tool calls.

### data-modeler (IF DB changes detected)

```
Analyze database implications for this initiative.

Epic: {description}
Components identified: {from business-analyst}
Architecture approach: {from architect}

Analyze:
1. Existing entity relationships and constraints in affected areas
2. Required schema changes across the initiative
3. Migration complexity and ordering
4. Index needs for new queries
5. Data integrity considerations across tickets

Return concise schema analysis (~1000 tokens) focused on what impacts ticket breakdown.
```

### integration-analyst (IF external APIs involved)

```
Analyze external API integrations for this initiative.

Epic: {description}
External dependencies identified: {from business-analyst}
Integration points: {from architect}

Analyze:
1. API contracts and versioning requirements
2. Authentication/authorization for external services
3. Error handling and retry patterns needed
4. Rate limits and throttling considerations
5. Integration testing requirements

Return concise integration analysis (~1000 tokens) focused on what impacts ticket breakdown.
```

### aws-architect (IF AWS/cloud changes needed)

```
Review infrastructure requirements for this initiative.

Epic: {description}
Infrastructure scope: {from architect}

Analyze:
1. Required AWS services (new or modifications to existing)
2. IAM permissions and security boundaries
3. Infrastructure-as-Code changes needed
4. Cross-service dependencies
5. Cost implications and resource sizing

Return concise infrastructure analysis (~1000 tokens) focused on what impacts ticket breakdown.
```

### security-requirements (IF security-sensitive scope)

```
Identify security and compliance requirements for this initiative.

Epic: {description}
Sensitive areas identified: {from business-analyst}
Security boundaries: {from architect}

Analyze:
1. Authentication/authorization requirements across the initiative
2. Data sensitivity classification
3. Compliance requirements (GDPR, PCI, etc.)
4. Security boundaries and constraints between components
5. Audit logging needs

Return concise security analysis (~1000 tokens) focused on what impacts ticket breakdown.
```
