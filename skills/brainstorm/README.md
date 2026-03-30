# Brainstorm Skill

Interactive implementation planning for business requirements.

## What It Does

The `/brainstorm` skill helps you think through implementation options **before committing to detailed specs**. It's the missing link between "business wants X" and "here's exactly how to build it."

## The Problem It Solves

You receive a business requirement like:
> "Users need to export their data to Excel"

You're not sure:
- Should I build it from scratch or use a library?
- Where does this fit in the current architecture?
- What's the simplest approach vs most robust?
- How much work is this actually?

**This skill helps you answer those questions.**

## How It Works

### 6-Phase Workflow

1. **Capture Requirements** - Understand the business context and constraints
2. **Exploration** - Find existing patterns in the codebase
3. **Generate Approaches** - Present 2-3 different implementation options with trade-offs
4. **Refine & Iterate** - Deep dive on chosen approach based on feedback
5. **Work Breakdown** - Outline specific tasks/tickets needed
6. **Summary** - Comprehensive documentation of decisions

### Interactive & Iterative

The skill asks questions, presents options, gets your feedback, and refines based on your input. It's collaborative, not prescriptive.

## Example Usage

```bash
# Quick start
/brainstorm "Add webhook notifications when orders complete"

# Interactive mode
/brainstorm
# Then answer questions about what you want to build
```

## What You Get

### Files Created in `.claude/brainstorm/{feature}/`

- `exploration.md` - Existing patterns found in codebase
- `business-context.md` - Business requirements analysis
- `approaches.md` - 2-3 implementation options with pros/cons
- `implementation-picture.md` - Detailed design of selected approach
- `work-breakdown.md` - Tasks/tickets needed
- `brainstorm-summary.md` - Complete summary with decisions

### Key Outputs

1. **Multiple Approaches** - See different ways to implement
2. **Trade-off Analysis** - Understand pros/cons of each approach
3. **Implementation Picture** - Components, data flow, APIs, database changes
4. **Work Breakdown** - Clear list of tasks with dependencies and estimates

## When to Use This

✅ **Use /brainstorm when:**
- Business gives you requirements but approach is unclear
- Want to explore options before committing
- Need to present trade-offs to stakeholders
- Multiple ways to implement and unsure which is best
- Want to understand scope before creating tickets

❌ **Don't use /brainstorm when:**
- Already know exactly how to implement → `/create-requirements`
- Need formal proposal with code → `/create-proposal`
- Work is already scoped → `/epic` or `/implement`
- It's a trivial change (< 1 day effort)

## What Happens Next?

After brainstorming, you have several options:

### Option 1: Create Detailed Requirements
```bash
/create-requirements
```
Use the brainstorm output to create comprehensive technical specs.

### Option 2: Break Into Epic
```bash
/epic "{feature description}"
```
If it's a large effort, break it into multiple tickets.

### Option 3: Create Formal Proposal
```bash
/create-proposal
```
For significant architectural changes, create a formal proposal.

### Option 4: Implement Directly
If the work breakdown shows it's simple, start implementing directly.

## Real-World Example

### Scenario
Business: "We need to let users export their order history to Excel."

### Using /brainstorm

**Phase 1-2: Exploration**
- Finds existing export features in codebase
- Identifies similar patterns (PDF export)
- Analyzes business needs (filters? date ranges? all orders?)

**Phase 3: Approaches**

**Approach 1: PHP Library (PhpSpreadsheet)**
- Pros: Full control, no external dependencies
- Cons: Memory intensive for large datasets
- Complexity: Moderate
- Timeline: 3-5 days

**Approach 2: CSV Export + Frontend Conversion**
- Pros: Simple backend, lightweight
- Cons: Limited formatting, client-side processing
- Complexity: Simple
- Timeline: 1-2 days

**Approach 3: Third-Party Service (e.g., AWS Lambda)**
- Pros: Scalable, async processing
- Cons: Additional infrastructure, cost
- Complexity: Complex
- Timeline: 1-2 weeks

**Phase 4: User Selects Approach 2**
- Refines CSV approach
- Details: Controller, Service, endpoint design
- Security: Access control, rate limiting
- Testing strategy

**Phase 5: Work Breakdown**
1. Backend CSV export service (1 day)
2. API endpoint (0.5 day)
3. Frontend button + download (0.5 day)
4. Tests (0.5 day)

**Total: 2-3 days**

### Result
Clear understanding of:
- What to build
- How to build it
- Why this approach
- How much effort
- What could go wrong

## Tips

1. **Start Broad** - Don't lock into details too early
2. **Explore Multiple Options** - Always consider at least 2 approaches
3. **Ask Questions** - Clarify unknowns before deciding
4. **Document Decisions** - Record why you chose an approach
5. **Iterate** - Refine based on findings
6. **Think Trade-offs** - No perfect solution, only trade-offs
7. **Involve Stakeholders** - Use output for technical discussions

## Comparison with Other Skills

| Skill | Purpose | When to Use |
|-------|---------|-------------|
| `/brainstorm` | Explore options, think through approach | Early planning, unclear approach |
| `/create-requirements` | Detailed specs for implementation | After deciding on approach |
| `/create-proposal` | Formal proposal with implementation | Architectural changes, need buy-in |
| `/epic` | Break scoped work into tickets | Large effort, multiple developers |
| `/implement` | Actually build the feature | Ready to code |

## Philosophy

> "Weeks of coding can save you hours of planning."

The `/brainstorm` skill embraces:
- **Think before you code** - Planning saves rework
- **Options over prescription** - Present choices, not dictates
- **Trade-offs over perfection** - No solution is perfect
- **Iteration over commitment** - Refine as you learn
- **Clarity over speed** - Better to be slow and right

---

**Ready to brainstorm?**

```bash
/brainstorm "your feature description here"
```
