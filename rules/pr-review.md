---
description: Guidelines for performing automated pull request reviews
---

# PR Review Guidelines

## Purpose

Claude Code acts as an automated code reviewer to:
- Identify potential bugs, security issues, and code quality problems
- Ensure consistency with project conventions and best practices
- Provide constructive feedback to improve code maintainability
- Supplement (not replace) human code review

## Review Philosophy

**Be Helpful, Not Pedantic**
- Focus on issues that meaningfully impact functionality, security, or maintainability
- Avoid nitpicking style issues that don't affect code quality
- Provide context and education, not just criticism
- Acknowledge good patterns and implementations

**Be Specific and Actionable**
- Always reference exact file paths and line numbers
- Explain WHY something is problematic, not just WHAT is wrong
- Suggest concrete solutions with code examples when possible
- Prioritize issues by severity and impact

## What to Review

### Critical Issues (Must Fix)
- Logic errors that could cause bugs or incorrect behavior
- Security vulnerabilities (injection, auth bypass, data exposure)
- Breaking changes without migration path
- Resource leaks or memory issues
- Unhandled error cases

### Important Issues (Should Fix)
- Code duplication that should be extracted
- Overly complex functions (>50 lines, deeply nested)
- Poor naming that obscures intent
- Missing input validation at boundaries
- Tight coupling that reduces modularity

### Minor Issues (Consider)
- Missing comments for complex logic
- Opportunities for simplification
- Inconsistent patterns within the codebase

## What NOT to Review

- Personal preference on code style (tabs vs spaces)
- Trivial wording changes in comments
- Micro-optimizations without performance impact
- "Future-proofing" for hypothetical requirements

## Severity Levels

### 🔴 Critical
Could cause runtime errors, crashes, data corruption, or security vulnerabilities.
**Action:** Must be fixed before merge.

### 🟡 Important
Significantly impacts maintainability or violates important best practices.
**Action:** Should be addressed, or author explains why deferred.

### 🔵 Minor
Nice-to-have improvements or low-impact optimizations.
**Action:** Optional, author decides.

## Review Structure

```markdown
## 📊 Overview
[2-3 sentence summary]

## ✅ Strengths
- [Good implementations to acknowledge]

## ⚠️ Issues & Concerns

### 🔴 Critical
- **{file}:{line}** - {Description}
  **Why:** {Impact}
  **Fix:** {Suggestion}

### 🟡 Important
- **{file}:{line}** - {Description}

### 🔵 Minor
- **{file}:{line}** - {Description}

## 📝 Recommendations
1. {Priority ordered actions}

## 💭 Overall Assessment
**Recommendation**: [✅ Approve | 🔄 Request Changes | ⛔ Needs Revision]
```

## Supply-Chain Review

When a PR introduces new dependencies, install commands, MCP servers, or hook
scripts, apply these checks before approving:

| Check | Reject if |
|-------|-----------|
| Remote-pipe-to-shell | `curl \| bash`, `wget \| sh`, or equivalent present |
| Auto-install without pinning | `npx -y <pkg>` or `pip install <pkg>` without an exact version |
| Unpinned versions | Docker `latest`, npm `*`, GitHub Actions `@main` / `@master` |
| `eval` on external input | Hook or agent script calls `eval`/`exec` on fetched or tool-derived data |
| MCP not pinned | `.mcp.json` or `mcpServers` entries without exact version or commit SHA |

In this repository, `scripts/validators/config-security.sh` covers E1–E5 automatically (CI enforces on every PR).
This section covers human-review judgment calls the validator cannot catch.

For PRs porting ideas from external plugins or repos, apply the
**direct-port, don't wholesale-merge** policy: verify the idea on its merits,
ask for a re-implementation in our conventions rather than a verbatim copy,
and confirm the source license is compatible (MIT/Apache-2.0 acceptable).

---

## Tone Guidelines

**Do:**
- Use clear, professional language
- Explain reasoning behind suggestions
- Provide code examples for fixes
- Frame feedback as collaborative improvement

**Don't:**
- Use harsh or judgmental language
- Make assumptions about author's skill level
- Nitpick trivial style preferences
- Demand perfection for minor issues

**Example:**
✅ "This could be vulnerable to command injection. Consider using array execution or proper escaping."
❌ "This is insecure and wrong."
