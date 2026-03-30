# Quality Gate Auto-Fix Prompts (Phase 4.7.2)

These prompt templates are used when critical issues are found during QA. Each critical issue gets up to 2 fix attempts with targeted re-validation.

## Fix Attempt Prompt (Attempt 1)

**Use Task tool with `subagent_type: "refactorer"`:**

```
Prompt: Fix the following critical issue identified during QA review.

Issue ID: {issue_id}
Source: {code-reviewer | security-auditor}
Severity: CRITICAL
File: {file_path}
Line: {line_number}
Description: {issue_description}

Code context:
{relevant_code_snippet}

Fix requirements:
- Address the specific issue described above
- Do NOT introduce new issues or change unrelated code
- Follow existing code patterns and conventions
- Ensure the fix is minimal and targeted

Return: Description of the fix applied and files modified.
```

## Re-Validation Prompts

After each fix, run targeted re-validation:

### If issue was from code-reviewer

**Use Task tool with `subagent_type: "code-reviewer"`:**
```
Prompt: Re-review the following file after a fix was applied for issue: {issue_description}

File: {file_path}
Original issue: {issue_description}

Check ONLY whether the original issue is resolved and no new CRITICAL issues were introduced.
Return: Whether the issue is resolved (yes/no) and any new critical issues found.
```

### If issue was from security-auditor

**Use Task tool with `subagent_type: "security-auditor"`:**
```
Prompt: Re-audit the following file after a security fix was applied for issue: {issue_description}

File: {file_path}
Original issue: {issue_description}

Check ONLY whether the original vulnerability is resolved and no new security issues were introduced.
Return: Whether the issue is resolved (yes/no) and any new security issues found.
```

### If tests broke after a fix

Run test-fixer (existing Phase 4.2 pattern, max 3 retries).

## Fix Attempt Prompt (Attempt 2 — Enriched Context)

If attempt 1 fails (re-validation finds issue persists), try with enriched context:

```
Prompt: Fix the following critical issue. A previous fix attempt was made but failed.

Issue ID: {issue_id}
Source: {code-reviewer | security-auditor}
Severity: CRITICAL
File: {file_path}
Line: {line_number}
Description: {issue_description}

Previous fix attempt:
- What was tried: {description_of_attempt_1_changes}
- Why it failed: {re-validation_feedback}

Try a DIFFERENT approach than the previous attempt.
```

After attempt 2, run the same targeted re-validation as attempt 1.
