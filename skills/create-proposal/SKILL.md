---
name: create-proposal
category: planning
model: claude-opus-4-7
userInvocable: true
description: Create a formal design document for a feature or component. Guides through requirements, approach brainstorming, and iterative proposal drafts with approval gate before optional implementation. Use when you need a written design approved before committing to code.
argument-hint: "[--light] [proposal-name or identifier]"
allowed-tools: "Read, Write, Edit, Glob, Grep, Bash(git:*), Bash(mkdir:*), Bash(yq:*), Bash(grep:*), Bash(cp:*), Task, AskUserQuestion"
---

# Create Proposal

## Context

Current directory: !`pwd`
Git branch: !`git branch --show-current 2>/dev/null || echo "not a git repo"`
Arguments: $ARGUMENTS

---

This skill guides you through creating comprehensive technical proposals for new features, components, or workflows. It adapts to your project's technology stack and follows a structured 5-phase approach with **state persistence** to enable resuming interrupted work.

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults:

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work state and context |
| `storage.artifacts.proposals` | `location: local, subdir: proposals` | Final proposal output |

```bash
# Source resolve-config: marketplace installs get ${CLAUDE_PLUGIN_ROOT} substituted
# inline before bash runs; ./install.sh users fall back to ~/.claude. If neither
# path resolves, fail loudly rather than letting resolve_artifact be undefined.
if [ -f "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-config.sh"
elif [ -f "$HOME/.claude/shared/resolve-config.sh" ]; then
  source "$HOME/.claude/shared/resolve-config.sh"
else
  echo "ERROR: resolve-config.sh not found. Install via marketplace or run ./install.sh" >&2
  exit 1
fi
WORK_DIR=$(resolve_artifact work work)
PROPOSALS_DIR=$(resolve_artifact proposals proposals)
```

Use `$WORK_DIR` and `$PROPOSALS_DIR` instead of hardcoded paths throughout this workflow.

**Important:** All path references in this skill MUST use `$WORK_DIR` and `$PROPOSALS_DIR` variables. Never use hardcoded `.claude/work/` or `.claude/proposals/` paths.

---

## When to Use This Skill

Use this skill when the user wants to:
- Plan and document a new feature or change
- Design a new feature or component (e.g., SSO integration, payment system)
- Plan a new API endpoint or workflow
- Architect a database schema or entity structure
- Implement authentication or authorization systems
- Create any significant technical change requiring planning

## Outputs

This skill produces:
1. **`state.json`** - State file for resume capability
2. **`context/`** - Cached agent outputs for reference
3. **Iterative proposals** - `proposal1.md`, `proposal2.md`, etc.
4. **Implementation** - `src/` directory with code (after approval)
5. **Documentation** - `README.md` with installation guide

Work directory: `$WORK_DIR/{identifier}/`
Final output: `$PROPOSALS_DIR/{proposal_name}/` (copied on completion)

---

## Lightweight Mode

If `$ARGUMENTS` begins with `--light`, strip the flag and enable lightweight mode:

- Output to user: "Lightweight mode enabled: reasoning agents use Sonnet. Quality gate unchanged."
- **Explore**: unchanged (already Sonnet)
- **Plan**: spawn with model **sonnet** instead of opus
- **business-analyst**: spawn with model **sonnet** instead of opus (ALWAYS Opus in standard mode — reasoning-heavy synthesis)
- **architect**: unchanged (already Sonnet)
- **quality-guard**: unchanged (ALWAYS Opus — quality gate)
- All orchestration flow, approval gates, and output formats remain identical

This reduces cost for the requirements-gathering and approach-generation phases while keeping the final quality-guard challenge at full strength.

---

## Phase 0: Setup

**Goal**: Establish identifier, initialize state, prepare work directory.

### 0.1 Get Identifier

Use AskUserQuestion:
```
What identifier should we use for this proposal?

Options:
- Ticket number (e.g., PROJ-123, SSO-001)
- Descriptive slug (e.g., sso-integration, payment-system)

This will be used for:
- Work directory: $WORK_DIR/{identifier}/
- Resume capability: /resume-work {identifier}
```

Store as `{identifier}`.

### 0.2 Get Proposal Name

If identifier is a ticket number, ask for a descriptive name:
```
What should we call this proposal? (e.g., sso-integration, user-export)
```

Store as `{proposal_name}`. If identifier is already descriptive, use it as proposal_name.

### 0.3 Get Feature Description

If not provided in $ARGUMENTS, use AskUserQuestion:
```
Describe the feature or system you want to design:
```

Store as `{feature_description}`.

### 0.4 Detect Ecosystem

Identify the project's technology stack to tailor Phase 5 implementation guidance.

**Check configuration first** (skip interactive question if set):
```bash
ECOSYSTEM=$(yq -r '.project.ecosystem // ""' "$CONFIG" 2>/dev/null)
```

**If not configured, auto-detect from project files:**
```bash
if [[ -z "$ECOSYSTEM" ]]; then
  if [[ -f "composer.json" ]]; then
    if grep -q "symfony/framework-bundle" composer.json 2>/dev/null; then
      ECOSYSTEM="php-symfony"
    else
      ECOSYSTEM="php"
    fi
  elif [[ -f "package.json" ]]; then
    if grep -qE '"react"|"next"' package.json 2>/dev/null; then
      ECOSYSTEM="react"
    else
      ECOSYSTEM="node"
    fi
  elif [[ -f "go.mod" ]]; then
    ECOSYSTEM="go"
  elif [[ -f "pom.xml" ]]; then
    ECOSYSTEM="java"
  elif [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
    ECOSYSTEM="python"
  else
    ECOSYSTEM="unknown"
  fi
fi
```

**Confirm with user** (skip if `ECOSYSTEM` was found in `configuration.yml`):

Use AskUserQuestion:
```
header: "Technology Stack"
question: "Detected: {ECOSYSTEM}. Confirm or change."
options:
  - "PHP/Symfony" / "Symfony framework, PHP 8+, Doctrine ORM"
  - "PHP" / "PHP without a specific framework"
  - "React/TypeScript" / "React frontend with TypeScript"
  - "Node.js" / "Node.js backend"
  - "Go" / "Go backend service"
  - "Python" / "Python service or application"
  - "Other" / "Specify in the text field"
```

Store confirmed value as `{ecosystem}`.

> **Tip:** Add `project.ecosystem: php-symfony` to `.claude/configuration.yml` to skip this question on future proposals.

### 0.5 Initialize Work Directory

```bash
mkdir -p $WORK_DIR/{identifier}/context
mkdir -p $WORK_DIR/{identifier}/notes
```

### 0.6 Initialize State File

Write `$WORK_DIR/{identifier}/state.json`:

```json
{
  "schema_version": 1,
  "type": "proposal",
  "identifier": "{identifier}",
  "proposal_name": "{proposal_name}",
  "title": "{feature_description_summary}",
  "ecosystem": "{ecosystem}",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",

  "phases": {
    "requirements_gathering": {"status": "pending", "agent": "business-analyst"},
    "brainstorming": {"status": "pending", "agent": "Plan"},
    "proposal_drafts": {"status": "pending", "current_iteration": 0},
    "confirm_implementation": {"status": "pending"},
    "implementation": {"status": "pending"}
  },

  "iterations": [],

  "outputs": {
    "final_proposal": null,
    "readme": null
  }
}
```

### 0.7 Update Work Manifest

After creating the state file, upsert into `${WORK_DIR}/manifest.json` (see [docs/manifest-system.md](../../docs/manifest-system.md)).

Read or initialize manifest, then upsert item using `identifier` as unique key:

```json
{
  "identifier": "{identifier}",
  "title": "{feature_description_summary}",
  "type": "proposal",
  "status": "in_progress",
  "created_at": "{ISO_TIMESTAMP}",
  "updated_at": "{ISO_TIMESTAMP}",
  "current_phase": "requirements_gathering",
  "progress": "Phase 1/5",
  "branch": null,
  "tags": [],
  "path": "{identifier}/"
}
```

Update `last_updated` and `total_items` in the envelope.

Register active session for the optional `auto-context.sh` PostToolUse hook (no-op when `CLAUDE_SESSION_ID` is unset):

```bash
if [ -n "${CLAUDE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
  mkdir -p "$WORK_DIR"
  touch "$WORK_DIR/.active-sessions.lock"
  (
    flock -x -w 2 200 || exit 0
    [ -s "$WORK_DIR/.active-sessions" ] || echo '{}' > "$WORK_DIR/.active-sessions"
    jq --arg s "$CLAUDE_SESSION_ID" --arg w "{identifier}" \
       '. + {($s): $w}' "$WORK_DIR/.active-sessions" \
       > "$WORK_DIR/.active-sessions.tmp.$$" \
       && mv "$WORK_DIR/.active-sessions.tmp.$$" "$WORK_DIR/.active-sessions" \
       || rm -f "$WORK_DIR/.active-sessions.tmp.$$"
  ) 200>"$WORK_DIR/.active-sessions.lock"
fi
```

---

## Proposal Workflow (5 Phases)

### Phase 1: Requirements Gathering

**Goal**: Gather and document requirements using `business-analyst` agent.

#### 1.1 Run Business Analyst

**Use Task tool with `subagent_type: "business-analyst"`:**

```
Prompt: Analyze requirements for the following feature request.

Feature: {feature_description}

Gather and document:
1. Problem Statement - What problem are we solving?
2. Stakeholders - Who are the users and stakeholders?
3. Technical Constraints - What limitations exist?
4. Integration Points - What existing systems need to integrate?
5. Security Requirements - What security considerations apply?
6. Performance Requirements - What are the performance expectations?

Key components to identify:
- Endpoints/routes needed
- External services/APIs
- Database entities
- Authentication/authorization needs
- Error handling requirements

Document all assumptions clearly.

Return a structured requirements summary that can be used for technical proposal creation.
```

#### 1.1b Explore Codebase (Parallel with 1.1)

**Use Task tool with `subagent_type: "Explore"`:**

```
Prompt: Explore the codebase to understand existing patterns relevant to this feature.

Feature: {feature_description}

Find:
1. Similar features already implemented
2. Existing patterns and conventions
3. Related entities, services, controllers
4. External integrations or APIs involved
5. Infrastructure that could be leveraged

Provide file paths and code examples of relevant existing implementations.
```

**Run business-analyst (1.1) and Explore (1.1b) in parallel.**

#### 1.2 Save Agent Outputs

Save business-analyst output to `$WORK_DIR/{identifier}/context/requirements.json`
Save Explore output to `$WORK_DIR/{identifier}/context/exploration.md`

Also write human-readable version of requirements to `$WORK_DIR/{identifier}/notes/requirements.md`

#### 1.3 Review with User

**After agent completes**, review the requirements with the user:
- Present the gathered requirements
- Ask clarifying questions for any gaps
- Confirm understanding before proceeding

**Example follow-up questions for an SSO proposal:**
- "Which identity provider are you integrating with?"
- "Do you need to support multiple user pools?"
- "What happens when a user doesn't exist?"
- "Should tokens be one-time use?"
- "What's the token expiration time?"

#### 1.4 Update State

Update `state.json`:
```json
{
  "phases": {
    "requirements_gathering": {"status": "completed", "agent": "business-analyst"},
    "brainstorming": {"status": "in_progress", "agent": "Plan"}
  }
}
```

### Phase 2: Brainstorming & Exploration

**Goal**: Explore approaches and select direction using `Plan` agent.

#### 2.1 Run Plan Agent

**Use Task tool with `subagent_type: "Plan"`:**

```
Prompt: Design implementation approaches for the following feature.

Feature: {feature_description}
Requirements: {load from context/requirements.json}
Codebase Patterns: {load from context/exploration.md}

Tasks:
1. Using the codebase patterns already discovered, present 2-3 different implementation approaches
2. For each approach, document:
   - Architecture pattern (MVC, service layer, etc.)
   - Technology choices (libraries, frameworks)
   - Data flow and state management
   - Pros and cons
   - Security considerations
   - Scalability implications
3. Identify risks and mitigation strategies
4. Recommend preferred approach with justification

Return a structured comparison of approaches with clear recommendation.
```

#### 2.2 Save Agent Output

Save Plan agent output to `$WORK_DIR/{identifier}/context/approaches.json`

#### 2.2b Validate Approaches

**Use Task tool with `subagent_type: "architect"`:**

```
Prompt: Validate the feasibility of these implementation approaches against project architecture.

Approaches: {load from context/approaches.json}
Codebase Patterns: {load from context/exploration.md}

For each approach, assess:
1. Architectural feasibility - does it fit the project's existing architecture?
2. Pattern consistency - does it follow established patterns?
3. Risk areas - what could go wrong architecturally?
4. Missing considerations

Annotate each approach with a feasibility assessment.
```

Save architect output to `$WORK_DIR/{identifier}/context/architecture-validation.md`

Include architect feedback when presenting approaches to the user.

#### 2.3 Select Approach

**After agent completes**:
1. Present the approaches to the user
2. Discuss pros and cons of each
3. Ask for feedback on preferred direction
4. Record the selected approach

Save decision to `$WORK_DIR/{identifier}/notes/decisions.md`:
```markdown
# Design Decisions

## Selected Approach
{approach_name}

## Rationale
{why this approach was chosen}

## Trade-offs Accepted
{what we're giving up}
```

#### 2.4 Update State

Update `state.json`:
```json
{
  "phases": {
    "requirements_gathering": {"status": "completed"},
    "brainstorming": {"status": "completed", "agent": "Plan", "selected_approach": "{approach_name}"},
    "proposal_drafts": {"status": "in_progress", "current_iteration": 1}
  }
}
```

### Phase 3: Create Proposal Drafts

**Goal**: Create iterative proposal documents, tracking each version.

#### 3.1 Create Proposal Draft

Create proposal documents in the work directory:

**Directory structure:**
```
$WORK_DIR/{identifier}/
├── state.json
├── context/
│   ├── requirements.json
│   └── approaches.json
├── notes/
│   ├── requirements.md
│   ├── questions.md
│   └── decisions.md
├── proposal1.md  # Initial approach
├── proposal2.md  # Refined after feedback
└── proposal3.md  # Final design (if needed)
```

Read `references/proposal-template.md` for the full proposal document format (sections: Overview, Problem Statement, Proposed Solution, Architecture, API Endpoints, Security, Dependencies, Testing Strategy, Deployment).

#### 3.2 Iterate on Proposals

- Number proposals sequentially (proposal1.md, proposal2.md, etc.)
- Each iteration addresses feedback and refines the design
- Keep previous versions for reference

#### 3.3 Track Iterations

After each proposal draft, update `state.json`:

```json
{
  "phases": {
    "proposal_drafts": {"status": "in_progress", "current_iteration": 2}
  },
  "iterations": [
    {
      "version": 1,
      "file": "proposal1.md",
      "created_at": "{ISO_TIMESTAMP}",
      "feedback": "Need more detail on token handling and error cases"
    },
    {
      "version": 2,
      "file": "proposal2.md",
      "created_at": "{ISO_TIMESTAMP}",
      "feedback": null
    }
  ]
}
```

#### 3.4 Record Feedback

When user provides feedback on a proposal:
1. Record feedback in the current iteration entry
2. Increment `current_iteration`
3. Create next proposal version addressing feedback

Save questions and clarifications to `$WORK_DIR/{identifier}/notes/questions.md`

---

### Phase 3.5: Quality Guard Review

**Goal**: Independently validate the final proposal draft before presenting it for approval.

Use Task tool with `subagent_type: "quality-guard"`:

```
Prompt: Review this technical proposal before stakeholder approval.

Final proposal: $WORK_DIR/{identifier}/{latest_proposal}.md
Architecture validation: $WORK_DIR/{identifier}/context/architecture-validation.md (if exists)

Review:
1. Are all requirements from Phase 1 addressed? List any gaps.
2. Are the API contracts, schemas, or integration points fully specified (no "TBD" gaps)?
3. Are security considerations explicitly addressed?
4. Are the proposed patterns consistent with the codebase exploration findings?
5. Is the implementation plan realistic — are there hidden dependencies or missing steps?
6. Are there contradictions between sections of the proposal?

Return: APPROVED / CONDITIONAL / REJECTED with specific findings.
```

**Process the verdict:**

- **APPROVED**: Proceed to Phase 4.
- **CONDITIONAL**: Incorporate the findings into the proposal as a "Known Concerns" section, or address them with a targeted revision. Proceed to Phase 4.
- **REJECTED**: Return to Phase 3 — create a new proposal iteration addressing the fundamental issues.

Save quality-guard output to `$WORK_DIR/{identifier}/context/quality-guard.md`.

---

### Phase 4: Confirm Implementation

**Goal**: Get explicit approval before implementing.

#### 4.1 Review Final Proposal

Before implementing, confirm with the user:

1. **Review final proposal** together
2. **Confirm all requirements** are addressed
3. **Get explicit approval** to proceed
4. **Ask**: "Are you ready to implement this proposal, or would you like to refine anything?"

**Only proceed to implementation after explicit confirmation.**

#### 4.2 Update State on Approval

Update `state.json`:

```json
{
  "phases": {
    "proposal_drafts": {"status": "completed", "current_iteration": 2, "final_version": "proposal2.md"},
    "confirm_implementation": {"status": "completed", "approved_at": "{ISO_TIMESTAMP}"},
    "implementation": {"status": "in_progress"}
  }
}
```

#### 4.3 If User Wants Changes

If user requests more iterations:
1. Return to Phase 3
2. Create next proposal version
3. Update iteration tracking
4. Return here for approval

### Phase 5: Implementation & Documentation

**Goal**: Implement the approved design and create documentation.

Read `references/implementation-guide.md` for the complete Phase 5 workflow — ecosystem-specific directory conventions, README.md structure, proposals directory copy, manifest updates, and completion report.

---

## Error Handling

Read `references/error-handling.md` for error-scenario message templates (agent fails, state file corrupted).

---

## Resume Support

This skill integrates with `/resume-work`:

```bash
/resume-work              # Shows incomplete proposals
/resume-work {identifier} # Resumes specific proposal
```

**Resume behavior by phase:**

| Current Phase | Resume Action |
|--------------|---------------|
| requirements_gathering | Re-run business-analyst or continue from cached output |
| brainstorming | Re-run Plan agent or continue from cached approaches |
| proposal_drafts | Load latest iteration, continue feedback loop |
| confirm_implementation | Show latest proposal, ask for approval |
| implementation | Continue implementing from src/ |

---

## Project Conventions

Follow your project's established conventions. The exploration agent (Phase 1.1b) will map the existing patterns — use those as your reference. If no established patterns exist for this type of feature, define them explicitly in the proposal and get approval before implementing.

## Tips for Success

1. **Be thorough in Phase 1** - Better questions = better proposals
2. **Don't rush to implementation** - Design first, code later
3. **Iterate proposals** - Create proposal2.md, proposal3.md as needed
4. **Document decisions** - Capture why choices were made
5. **Follow conventions** - Consistency matters in codebases
6. **Test thoroughly** - Plan testing from the start
7. **Think about operations** - Logging, monitoring, cleanup tasks

## Examples of Good Proposals

Refer to existing proposals in `$PROPOSALS_DIR/` for patterns. If none exist yet, the first proposal is your template — take extra care with structure and documentation.

## Common Proposal Types and Pre-Implementation Checklist

Read `references/proposal-types.md` for the reference categories (Authentication/SSO, API Endpoints, Database Changes, Third-Party Integration) and the pre-implementation checklist.

## Output Files Summary

Read `references/output-files.md` for the expected work-directory and final-output structures.

## Remember

- **Never skip Phase 4 confirmation** - Always get explicit approval before implementing
- **Proposals are living documents** - Update them as design evolves
- **Documentation is not optional** - README.md is the implementation guide
- **Follow existing patterns** - Look at the codebase for conventions
- **Think about the full lifecycle** - Installation, usage, maintenance, troubleshooting