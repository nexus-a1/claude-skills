# Deep-Dive Agent Prompt Templates (Stage 3.2)

These are the prompt templates for each deep-dive agent. The orchestrator determines which agents to run based on discovery findings (see Stage 3.1), then executes applicable prompts in parallel via Task tool calls.

Template variables (`{feature_description}`, `{discovery_output}`, etc.) are filled by the orchestrator from Stage 1-2 outputs.

---

```
Task 1 (ALWAYS): subagent_type: "archaeologist"
Prompt: Analyze code patterns, data flow, and modification risks for this feature.

Feature: {feature_description}
Refined Requirements: {refined_requirements}
Context inventory from discovery: {discovery_output}

Using the inventory as your map (do NOT re-inventory endpoints/services), investigate:
1. Code patterns used in the feature area (repository, event dispatch, etc.)
2. Data flow: entry point → processing → storage → response
3. Side effects (events, notifications, cache invalidation)
4. Hidden dependencies and implicit coupling
5. Historical context clues (TODOs, comments, workarounds)
6. Modification risks - what could break

Return concise findings (~1500 tokens) with file paths and line numbers.

---

Task 1b (ALWAYS): subagent_type: "architect"
Prompt: Map the architectural constraints that any implementation of this feature must satisfy.

Feature: {feature_description}
Context inventory from discovery: {discovery_output}

Do NOT design an implementation. Focus exclusively on constraints:
1. Architecture style in use (layered, hexagonal, modular, MVC) and its layer rules
2. Established patterns any implementation MUST follow (with file path examples)
3. Module/service boundaries — what this feature must stay within
4. Integration point contracts already in place
5. Anti-patterns or fragile areas to avoid
6. Feasibility checklist for evaluating any approach

Return: architectural constraints manifest (~1000 tokens). File paths and line numbers for each rule cited.

---

Task 2 (IF DB involved): subagent_type: "data-modeler"
Prompt: Analyze database schema and relationships for this feature.

Feature: {feature_description}
Entities identified: {entities_from_discovery}

Analyze:
1. Existing entity relationships and constraints
2. Required schema changes for this feature
3. Migration requirements
4. Index needs for new queries
5. Data integrity considerations

Return schema analysis and migration requirements.

---

Task 3 (IF external APIs): subagent_type: "integration-analyst"
Prompt: Analyze external API integrations for this feature.

Feature: {feature_description}
External APIs identified: {apis_from_discovery}

Analyze:
1. Existing integration patterns
2. API contracts and versioning
3. Authentication requirements
4. Error handling patterns
5. Rate limits and retry strategies

Return integration requirements and contracts.

---

Task 4 (IF AWS/cloud): subagent_type: "aws-architect"
Prompt: Review AWS/cloud architecture for this feature.

Feature: {feature_description}
AWS resources detected: {aws_from_discovery}

Analyze:
1. Required AWS services (new or existing)
2. IAM permissions needed
3. Infrastructure changes (CloudFormation/IaC)
4. Security considerations
5. Cost implications

Return infrastructure requirements.

---

Task 5 (IF auth/sensitive): subagent_type: "security-requirements"
Prompt: Identify security and compliance requirements for this feature.

Feature: {feature_description}
Sensitive areas: {sensitive_from_discovery}

Analyze:
1. Authentication/authorization requirements
2. Data sensitivity classification
3. Compliance requirements (GDPR, PCI, etc.)
4. Security boundaries and constraints
5. Audit logging needs

Return security requirements (~1500 tokens).

---

Task 6 (IF requirements: config found): subagent_type: "archivist"
Prompt: Search historical requirements for work similar to this feature.

Feature: {feature_description}
Components involved: {components_from_discovery}

Search for:
1. Similar past implementations
2. Patterns that were reused
3. Lessons learned and gotchas
4. Related tickets

Return historical context and recommendations (~1500 tokens).

---

Task 7 (IF product_knowledge: config found): subagent_type: "product-expert"
Prompt: Provide product-specific context relevant to this feature.

Feature: {feature_description}
Components involved: {components_from_discovery}

Research:
1. Relevant product architecture patterns
2. API contracts and integration points
3. Business rules and constraints
4. Existing patterns to follow

Return product context (~1500 tokens).
```
