# Brainstorm Agent Prompts

Prompt templates for every phase that spawns an agent. Fill in the `{placeholders}` from prior-phase outputs or user input.

## Phase 2.1: Explore (subagent_type: Explore)

```
Prompt: Explore the codebase to understand existing patterns for this feature.

Feature: {feature_description}

Find:
1. Similar features already implemented
2. Existing patterns we should follow
3. Related entities, services, controllers
4. External integrations or APIs involved
5. Existing infrastructure that could be leveraged

**Depth limit:** Describe interfaces and patterns — method signatures, key properties, how the system works conceptually. Do not reproduce full method implementations or dump complete file contents. One example of an existing pattern is sufficient. Full code reads are for implementation phases.

Provide file paths and interface descriptions of relevant existing implementations.
```

## Phase 2.2: business-analyst

```
Prompt: Analyze business requirements for this feature.

Feature: {feature_description}
Business Context: {from_phase_1}

Analyze:
1. Core problem being solved
2. User personas affected
3. Success metrics
4. Edge cases to consider
5. Assumptions to validate

Provide a structured business context summary.
```

## Phase 3.1: Plan (generate approaches)

```
Prompt: Design 2-3 different implementation approaches for this feature.

Feature: {feature_description}
Codebase patterns: {from_exploration}
Business requirements: {from_business_analyst}

For each approach, document:
1. **Name** - Short descriptive name
2. **Architecture** - How it's structured (components, layers)
3. **Technology choices** - Libraries, frameworks, services
4. **Pros** - Benefits of this approach
5. **Cons** - Drawbacks and risks
6. **Complexity** - Estimated complexity (Simple | Moderate | Complex)
7. **Timeline** - Rough estimate (Days | Weeks | Months)

Approaches must differ architecturally — in where logic lives, which layer enforces it, what triggers the check, or what system boundary it crosses. Do not present parameter-count or flag-count variants of the same architecture as separate approaches. If two approaches share the same component placement, migration path, and check points, merge them into one approach with a granularity sub-option.

Trade-off dimensions:
- Where the logic lives (service layer vs middleware vs database)
- Extension point (existing component vs new component)
- Synchronous vs asynchronous
- Configuration-driven vs code-driven

Provide 2-3 distinct, viable approaches.
```

## Phase 4.1: Plan (refine selected approach)

```
Prompt: Refine and detail the selected approach.

Feature: {feature_description}
Selected Approach: {approach_name}
User Feedback: {feedback_from_user}

Create a detailed implementation picture:

1. **Component Breakdown**
   - Controllers (which endpoints)
   - Services (what business logic)
   - Entities (database tables)
   - Models (request/response objects)
   - External integrations

2. **Data Flow**
   - Step-by-step request/response flow
   - Data transformations
   - State changes

3. **Database Changes**
   - New tables needed
   - Migrations required
   - Indexes for performance

4. **API Design** (if applicable)
   - Endpoints
   - Request/response formats
   - Error cases

5. **Security Considerations**
   - Authentication/authorization
   - Data validation
   - Sensitive data handling

6. **Testing Strategy**
   - Unit tests
   - Integration tests
   - Manual testing steps

Provide a clear, detailed implementation picture.
```

## Phase 4.2: architect

```
Prompt: Validate this implementation approach against architecture rules.

Implementation plan: {from_phase_4.1}

Check:
1. Follows project architectural patterns
2. Proper layer separation
3. Appropriate file structure
4. Integration points are sound
5. Scalability concerns addressed

Identify any architectural risks or violations.
Suggest improvements if needed.
```

## Phase 4.5: quality-guard

```
Prompt: Challenge this implementation picture for '{feature_description}'.

Read these files:
- $WORK_DIR/{slug}/implementation-picture.md
- $WORK_DIR/{slug}/context/architecture-validation.md
- $WORK_DIR/{slug}/context/approaches.md
- $WORK_DIR/{slug}/context/exploration.md (if exists)

Review:
1. Is the selected approach architecturally sound? Does it match the architectural constraints found in the codebase?
2. Are all component boundaries clearly defined with no hidden overlap or missing pieces?
3. What assumptions were made that weren't verified against actual code?
4. Are there missing components, edge cases, or failure modes not captured?
5. Is the scope realistic, or does it need further decomposition?
6. Are any stated trade-offs real, or are they assumptions?

Return: APPROVED / CONDITIONAL / REJECTED
- APPROVED: No blocking concerns.
- CONDITIONAL: List specific concerns that should be noted in work breakdown.
- REJECTED: Fundamental issue — describe what must change before proceeding.
```
