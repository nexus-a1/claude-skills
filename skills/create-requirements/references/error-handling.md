# Error Handling (Create Requirements)

All error recovery MUST use AskUserQuestion to present options to the user.

## Git Branch Creation Fails

Use AskUserQuestion:
```
question: "Failed to create branch feature/{identifier}: {error_message}. How would you like to proceed?"
options:
  - label: "Retry with different name"
    description: "Provide a new branch name to try"
  - label: "Use existing branch"
    description: "Switch to the existing feature/{identifier} branch"
  - label: "Abort"
    description: "Stop requirements gathering"
```

**If "Retry with different name"**: Ask for new identifier, re-run Step 1.5.
**If "Use existing branch"**: Run `git checkout feature/{identifier}` and continue.
**If "Abort"**: Clean up work directory if created, exit with message.

## Agent Fails

Use AskUserQuestion:
```
question: "Agent {agent_name} failed: {error_message}. How would you like to proceed?"
options:
  - label: "Retry"
    description: "Run this agent again"
  - label: "Skip"
    description: "Continue without this agent's findings"
  - label: "Abort"
    description: "Stop requirements gathering"
```

**If "Retry"**: Re-run the same Task call. If it fails a second time, offer only Skip or Abort.
**If "Skip"**: Save `{"status": "skipped", "error": "{error_message}"}` to the agent's output file in `context/`. Continue to next stage.
**If "Abort"**: If team mode, send shutdown requests and TeamDelete(). Update state with `"status": "failed"`, exit with message.

## Team Creation Fails (Team Mode Only)

Fall back to sub-agent mode automatically. Log:
```
WARNING: Team creation failed. Falling back to sub-agent execution mode.
```

Set `EXEC_MODE = "subagent"` and continue.

## Remote Push Fails

This is a non-blocking warning. Log the failure and continue. The branch can be pushed later manually or by `/implement`.
