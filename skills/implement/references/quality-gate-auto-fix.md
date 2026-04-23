# Quality Gate Auto-Fix (Phase 4.7.2 and 4.7.3)

Read this file only when Phase 4.7.1 has surfaced one or more CRITICAL findings. If no critical issues exist, skip straight to Phase 4.7.4.

## 4.7.2 Auto-Fix Critical Issues

Attempt auto-fix for each critical issue sequentially (max 2 fix attempts per issue):

```
For each critical issue:

1. Attempt fix via refactorer agent (attempt 1)
2. Re-validate the fix
3. If still unresolved: attempt fix via refactorer agent (attempt 2, with failure context)
4. Re-validate again
5. Track result (resolved / unresolved)
```

Read `references/quality-gate-prompts.md` for the detailed auto-fix and re-validation prompt templates (refactorer fix prompts, code-reviewer/security-auditor re-validation prompts, attempt 2 enriched context prompt).

### Track results for each issue

```
Issue CR-1: RESOLVED (attempt 1) - Fix applied in UserService.php
Issue SA-1: RESOLVED (attempt 2) - Different approach worked after first attempt failed
Issue SA-2: UNRESOLVED - Both auto-fix attempts failed, requires manual intervention
```

**IMPORTANT**: Run fixes sequentially (each fix may affect subsequent ones). Do NOT run fixes in parallel.

## 4.7.3 Commit Fixes

If any fixes were applied successfully:

1. Stage the fixed files.
2. Commit inline (the git-mutation-guard hook runs credential scan automatically):

   ```bash
   git add <fixed-files>
   git commit -m "[{identifier}] fix: address critical QA findings"
   ```

3. Update `state.json` with the new commit:

   ```json
   {
     "commits": ["abc123", "def456", "qa-fix-789"]
   }
   ```

After auto-fix completes, control returns to the main SKILL.md flow for Phase 4.7.4 (Quality Gate Decision).
