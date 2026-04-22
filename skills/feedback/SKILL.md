---
name: feedback
model: claude-sonnet-4-6
category: analysis
userInvocable: true
description: Generate a retrospective report analyzing agent pipeline execution, duplication, scope adherence, and output quality from a completed work session.
argument-hint: "[work-identifier] [--issue]"
allowed-tools: "Read, Write, Glob, Grep, Bash(git log:*), Bash(git diff:*), Bash(git branch:*), Bash(wc:*), Bash(jq:*), Bash(yq:*), Bash(mkdir:*), Bash(gh issue create:*), Task, AskUserQuestion"
---

# Feedback

Generate a scored retrospective report for a completed work session. Analyzes pipeline execution, agent quality, duplication, and scope adherence. Saves the report and creates a tracking issue in the plugin repository.

## Usage

```bash
/feedback                      # Auto-detect most recent session
/feedback JIRA-123             # Analyze specific work identifier
/feedback JIRA-123 --issue     # Analyze and create GitHub issue without prompting
```

## When to Use

- After running `/create-requirements`, `/implement`, `/brainstorm`, or `/epic`
- To evaluate how well the agent pipeline performed
- To identify duplication between agents
- To find improvements for agents, skills, and workflows

**This is a read-only analysis skill.** It reads existing artifacts and produces a feedback report. It does not modify work state or agent definitions.

---

## Configuration

Read `.claude/configuration.yml` for project-specific paths. If the file doesn't exist or a key is missing, use defaults.

| Config Key | Default | Purpose |
|-----------|---------|---------|
| `storage.artifacts.work` | `location: local, subdir: work` | Work session artifacts |
| `feedback.plugin_repo` | _(none)_ | GitHub repo for issue creation (e.g. `owner/repo`) |

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
PLUGIN_REPO=""
if [[ -f "$CONFIG" ]]; then
  PLUGIN_REPO=$(yq -r '.feedback.plugin_repo // ""' "$CONFIG")
fi
```

Use `$WORK_DIR` instead of hardcoded `.claude/work` throughout this workflow.
Use `$PLUGIN_REPO` for GitHub issue creation in Phase 7.

---

## Workflow

### Phase 1: Identify Work Session

**Goal:** Determine which work session to analyze and inventory its artifacts.

#### 1.1 Resolve Identifier

**Source-of-truth rule.** The identifier MUST come from `$ARGUMENTS` or from `${WORK_DIR}/` on disk. **DO NOT** infer the identifier from conversation context — e.g. tickets mentioned in earlier messages, loaded via `/load-context`, or referenced in the user's latest prompt. Tickets discussed in the session are not necessarily the session the user wants analyzed, and silently picking one up produces a feedback report attributed to the wrong work. If the disk-based sources below do not yield an identifier, ask the user — never guess from the transcript.

**From $ARGUMENTS:**
- If provided: use as work identifier (e.g., `JIRA-123`, `sso-integration`)
- If empty: auto-detect from `${WORK_DIR}/`, then confirm with the user (see below)

**Auto-detection** (when no argument). Compute the top 3 most recent sessions from disk:

```bash
# Check for manifest first
if [[ -f "${WORK_DIR}/manifest.json" ]]; then
  # Top 3 most recent non-archived sessions by updated_at, newest first
  jq -r '[.items[] | select(.status != "archived")] | sort_by(.updated_at) | reverse | .[0:3] | .[] | .identifier' "${WORK_DIR}/manifest.json"
else
  # Fall back to Glob for directory listing (preferred over ls)
  # Call: Glob("*/", path="${WORK_DIR}/")
  # Glob results are sorted by mtime ascending — reverse the order and take the first 3 as the most recent sessions.
  # If Glob returns no results, set identifier="" and proceed to the error path below.
fi
```

If no sessions exist, report and stop:
```
No work sessions found in ${WORK_DIR}/. Nothing to analyze.
```

**Confirm with the user before proceeding.** Even when auto-detection finds a clear "most recent" match, show it and require explicit approval — a silent pick is what produces wrong-ticket feedback reports. Use AskUserQuestion:

- header: `"Session"`
- question: `"Which work session should /feedback analyze?"`
- options (up to 4 total — at most 3 sessions plus `Cancel`):
  - `{identifier_1}` / `most recent — updated {updated_at_1}`
  - `{identifier_2}` / `updated {updated_at_2}` *(only if a second session exists)*
  - `{identifier_3}` / `updated {updated_at_3}` *(only if a third session exists)*
  - `Cancel` / `Stop — I will re-run with an explicit identifier`
- multiSelect: `false`

If the user picks `Cancel`, stop with:
```
No session selected. Re-run as /feedback <identifier> to target a specific session.
```

Do NOT skip this confirmation even when exactly one session exists on disk — the point is to prevent the skill from silently analyzing a session the user did not mean to target.

#### 1.2 Detect Work Type

Read whichever state file exists in `${WORK_DIR}/${identifier}/`:

All work types use `state.json`. Read it and check the `type` field to determine the work type:

| `type` field value | Work Type |
|-------------------|-----------|
| `"requirements"` | requirements |
| `"implementation"` | implementation |
| `"proposal"` | proposal |

Read the state file to extract:
- Current phase/stage
- Completion status
- Feature branch name (if any)
- Timestamps (created, updated)
- Agent outputs produced

#### 1.3 Inventory Available Data

Collect the list of available artifacts for analysis:

```bash
# State files
Glob("state.json", path="${WORK_DIR}/${identifier}/")

# Agent output files
Glob("context/*.md", path="${WORK_DIR}/${identifier}/")

# Output documents
Glob("*.md", path="${WORK_DIR}/${identifier}/")

# Check for feature branch
git branch -a --list "*${identifier}*"
```

Report what was found:

```
Work Session: ${identifier}
Type: ${work_type}
Status: ${phase} (${status})
Artifacts: ${count} files (${agent_outputs} agent outputs)
Branch: ${branch_name} (${commit_count} commits)
```

---

### Phase 2: Parallel Analysis

Launch two Explore agents in parallel (single message, two Task calls).

#### Agent 1: Pipeline Analyst

```
Task(Explore, "Analyze the pipeline execution of work session '${identifier}'.

Read the following files:
- ${WORK_DIR}/${identifier}/state.json (session state, check `type` field)
- ${WORK_DIR}/${identifier}/context/*.md (agent outputs, check file sizes)

Analyze and report on:

1. **Stage Completion**
   - Which stages/phases were completed vs skipped vs failed?
   - Were there any retries or feedback loops?
   - What was the execution mode (subagent vs team)?

2. **Timeline**
   - What timestamps exist? What was the total elapsed time?
   - Were there long gaps between stages (suggesting interruptions)?

3. **Parallelism**
   - Which agents ran in parallel vs sequentially?
   - Were there obvious opportunities for more parallelism?

4. **QA Gate**
   - Was there a QA/review phase? What were its results?
   - Were any issues flagged by code-reviewer, security-auditor, or test-writer?

Output a structured analysis in ~2000 tokens. Use this exact format:

### Pipeline Analysis

**Stages:**
| Stage | Status | Notes |
|-------|--------|-------|
| ... | ... | ... |

**Execution Mode:** subagent/team
**Feedback Loops:** count and description
**Timeline:** start → end, total duration
**Parallelism Score:** X/5 (1=fully sequential, 5=maximally parallel)
**QA Results:** summary

**Issues Found:**
- [list specific pipeline issues]
")
```

#### Agent 2: Output Quality Analyst

```
Task(Explore, "Analyze the output quality and duplication across agent outputs for work session '${identifier}'.

Read the following files:
- All files in ${WORK_DIR}/${identifier}/context/*.md (agent outputs)
- The agent definitions from ~/.claude/agents/ for each agent that produced output (if the path exists; skip scope adherence check if agent definitions are not available)

For each agent output file, analyze:

1. **Scope Adherence** (skip if agent definitions not found)
   - Compare what the agent actually wrote vs its defined purpose in ~/.claude/agents/{name}.md
   - Did it stay within its scope or drift into another agent's territory?
   - Rate: IN_SCOPE / MINOR_DRIFT / MAJOR_DRIFT

2. **Output Quality**
   - Is the output actionable and specific (not generic filler)?
   - Does it reference actual code, files, or endpoints from the project?
   - Rate size: CONCISE / ADEQUATE / VERBOSE / BLOATED
   - Rate quality: HIGH / MEDIUM / LOW

3. **Pairwise Duplication**
   - Compare each pair of agent outputs
   - For overlapping content, classify as:
     - REDUNDANT: Same finding, same detail, no added value
     - COMPLEMENTARY: Same topic but different perspective or added detail
   - Give 1-2 concrete examples of each type found

4. **Gap Analysis**
   - What aspects of the feature were NOT covered by any agent?
   - What questions remain unanswered after reading all outputs?

Output a structured analysis in ~2000 tokens. Use this exact format:

### Output Quality Analysis

**Per-Agent Assessment:**
| Agent | Scope | Quality | Size | Key Finding |
|-------|-------|---------|------|-------------|
| ... | ... | ... | ... | ... |

**Duplication Matrix:**
| Agent Pair | Overlap Type | Example |
|------------|-------------|---------|
| ... | ... | ... |

**Redundancy Rate:** X% (redundant findings / total findings)

**Coverage Gaps:**
- [list uncovered aspects]

**Top Quality Issues:**
- [list specific quality concerns]
")
```

---

### Phase 3: Gap Analysis (Conditional)

**Only runs if a feature branch exists with commits.**

Check for a feature branch:
```bash
git branch -a --list "*${identifier}*"
```

If a branch exists with commits beyond the base branch:

```bash
# Get the base branch from state file or default to master/main
git diff --stat ${base_branch}...${feature_branch}

# Get the requirements document
# Read ${WORK_DIR}/${identifier}/*-TECHNICAL_REQUIREMENTS.md or similar
```

Compare requirements against actual changes:

1. **Requirements not yet implemented** — items in the requirements doc with no corresponding code changes
2. **Unplanned changes (scope creep)** — code changes that don't map to any requirement

If no feature branch exists, skip this phase and note:
```
Phase 3 skipped: No feature branch found for '${identifier}'.
```

---

### Phase 4: Synthesize Report

Launch a Plan agent to synthesize all findings into a scored report.

```
Task(Plan, "Synthesize a feedback report from the following analysis results.

## Input Data

### Pipeline Analysis (from Phase 2, Agent 1):
${pipeline_analysis_output}

### Output Quality Analysis (from Phase 2, Agent 2):
${output_quality_output}

### Requirements-Implementation Gap (from Phase 3):
${gap_analysis_output_or_skipped}

### Session Metadata:
- Identifier: ${identifier}
- Work Type: ${work_type}
- Date: ${date}

## Scoring Rubric

Score out of 100 points using this fixed rubric:

### Pipeline Execution (25 points)
- All stages completed successfully: 25
- Deductions:
  - Stage failed or skipped without reason: -10 per stage
  - No QA gate: -5
  - Excessive retries (>2 feedback loops): -3
- Cap: minimum 0

### Agent Quality (25 points)
- All agents produced high-quality, in-scope output: 25
- Deductions:
  - Major scope drift: -5 per agent
  - Minor scope drift: -2 per agent
  - Low quality output: -5 per agent
  - Bloated output (>3x expected size): -3 per agent
- Cap: minimum 0

### Scope Adherence (20 points)
- Requirements fully covered, no scope creep: 20
- Deductions:
  - Unimplemented requirement: -4 per item
  - Scope creep (unplanned change): -3 per item
  - If gap analysis was skipped: award 15/20 (benefit of doubt)
- Cap: minimum 0

### Duplication (15 points)
- No redundant findings: 15
- Deductions:
  - Each redundant finding: -2
  - Redundancy rate > 20%: additional -3
- Cap: minimum 0

### Orchestration (15 points)
- Efficient agent coordination: 15
- Deductions:
  - Sequential execution where parallel was possible: -3
  - Agent used outside its expertise: -3 per instance
  - Missing agent that should have been included: -3 per instance
- Cap: minimum 0

## Output Format

Produce the report in EXACTLY this markdown structure:

# Feedback Report: ${identifier}

## Summary

| Metric | Value |
|--------|-------|
| Score | XX/100 |
| Work Type | ${work_type} |
| Date | ${date} |
| Grade | A/B/C/D/F |

Grade scale: A=90-100, B=80-89, C=70-79, D=60-69, F=<60

## Pipeline Execution (XX/25)

[Stage completion table, feedback loop activity, timeline, parallelism assessment]

## Agent Performance (XX/25)

[Per-agent scope/quality/size ratings with specific examples]

## Duplication Analysis (XX/15)

[Overlap matrix, redundancy rate, key examples of REDUNDANT vs COMPLEMENTARY findings]

## Requirements-Implementation Gap (XX/20)

[Gap table if applicable, or note that gap analysis was skipped]

## Orchestration (XX/15)

[Agent coordination efficiency, missed parallelism opportunities, agent selection appropriateness]

## Process Improvements

Ordered by impact (highest first). Each improvement must include:
1. **What:** Specific issue identified
2. **Why:** Impact on quality/efficiency
3. **Fix:** Concrete recommendation (which agent/skill/workflow to change and how)

## What Worked Well

[Patterns worth preserving — specific examples of good agent output, efficient coordination, or thorough coverage]
")
```

---

### Phase 5: Save Report

```bash
mkdir -p ${WORK_DIR}/feedback/
```

Save the synthesized report to `${WORK_DIR}/feedback/${identifier}-feedback.md`.

After saving, verify:
```bash
# Confirm file exists and is non-empty
wc -l ${WORK_DIR}/feedback/${identifier}-feedback.md
```

**No manifest update** — feedback reports are ephemeral analysis artifacts, not tracked in manifests.

---

### Phase 6: Present Summary

Display a concise summary to the user:

```
Feedback: ${identifier}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Score: XX/100 (Grade: X)

Pipeline:      XX/25
Agent Quality: XX/25
Scope:         XX/20
Duplication:   XX/15
Orchestration: XX/15

Top 3 Improvements:
1. {highest impact improvement}
2. {second highest}
3. {third highest}

Report saved: ${WORK_DIR}/feedback/${identifier}-feedback.md
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

### Phase 7: Create GitHub Issue

**Skip this phase if `$PLUGIN_REPO` is empty.** Notify the user:
```
Issue creation skipped — set feedback.plugin_repo in .claude/configuration.yml to enable.
```

If `$PLUGIN_REPO` is set, determine whether to create an issue:

#### 7.1 Determine intent

Parse `$ARGUMENTS` for the `--issue` flag:

```bash
CREATE_ISSUE=false
if echo "$ARGUMENTS" | grep -q -- "--issue"; then
  CREATE_ISSUE=true
fi
```

- If `--issue` flag is present: set `CREATE_ISSUE=true`, skip confirmation.
- If `--issue` flag is absent: ask the user using `AskUserQuestion`:

```
Create a GitHub issue for this report in ${PLUGIN_REPO}?

This will open a tracking issue with the full report so you can apply improvements later.

Reply yes/no.
```

Set `CREATE_ISSUE=true` only if the user confirms.

#### 7.2 Create the issue

If `CREATE_ISSUE=true`:

**Issue title:**
```
[Feedback] ${identifier}: ${score}/100 (Grade: ${grade}) — ${date}
```

**Issue body:** the full report markdown from Phase 4, prefixed with a metadata header:

```markdown
## Session

| Field | Value |
|-------|-------|
| Identifier | ${identifier} |
| Work Type | ${work_type} |
| Score | ${score}/100 (Grade: ${grade}) |
| Date | ${date} |
| Report | `${WORK_DIR}/feedback/${identifier}-feedback.md` |

---

${full_report_content}
```

```bash
gh issue create \
  --repo "${PLUGIN_REPO}" \
  --title "[Feedback] ${identifier}: ${score}/100 (Grade: ${grade}) — ${date}" \
  --body "$(cat ${WORK_DIR}/feedback/${identifier}-feedback.md)" \
  --label "feedback" 2>/dev/null || \
gh issue create \
  --repo "${PLUGIN_REPO}" \
  --title "[Feedback] ${identifier}: ${score}/100 (Grade: ${grade}) — ${date}" \
  --body "$(cat ${WORK_DIR}/feedback/${identifier}-feedback.md)"
```

> The first attempt includes `--label feedback`. If the label doesn't exist in the repo, the command falls back without it.

After creation, append the issue URL to the summary:

```
Issue created: https://github.com/${PLUGIN_REPO}/issues/NNN
```

---

## Error Handling

### No work sessions found
```
No work sessions found in ${WORK_DIR}/. Nothing to analyze.

Create work first:
- /create-requirements    Generate requirements
- /brainstorm             Explore approaches
- /implement              Implement features
```

### Work session has no agent outputs
```
Work session '${identifier}' has no agent output files in context/.
Pipeline analysis requires at least one agent output.

The session may be in an early stage. Complete the workflow first, then re-run /feedback.
```

### State file missing
If no state file exists in the work directory:
```
No state file found for '${identifier}' in ${WORK_DIR}/${identifier}/.
Expected: state.json (with a "type" field of "requirements", "implementation", or "proposal")

Cannot determine work type. Ensure this is a valid work session.
```

### Issue creation failed
If `gh issue create` fails for a reason other than a missing label:
```
Warning: Could not create GitHub issue in ${PLUGIN_REPO}.
Report is still saved at ${WORK_DIR}/feedback/${identifier}-feedback.md.
```
Do not abort — the report is already saved.

---

## Agent Delegation Summary

| Phase | Agent | Type | Purpose |
|-------|-------|------|---------|
| 2 | Pipeline Analyst | `Explore` | Analyze stage completion, timeline, parallelism |
| 2 | Output Quality Analyst | `Explore` | Analyze scope adherence, quality, duplication |
| 4 | Report Synthesizer | `Plan` | Score and compile final report |

Phase 2 agents run **in parallel** (single message, two Task calls).
Phase 4 runs **sequentially** (depends on Phase 2 + Phase 3 outputs).
