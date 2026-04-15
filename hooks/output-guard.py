#!/usr/bin/env python3
"""
output-guard.py — PostToolUse advisory hook for Bash output verbosity.

Emits an advisory `additionalContext` message when a Bash command's stdout
exceeds the configured threshold, nudging the agent toward compact flags
documented in plugin/shared/output-minimization.md.

Cannot truncate built-in tool output (only MCP tools support
updatedMCPToolOutput) — this is a teaching signal, not an enforcement.
"""

import json
import re
import sys

# Thresholds: trigger advisory when EITHER limit is exceeded.
LINE_THRESHOLD = 100
CHAR_THRESHOLD = 5000

# Per-command nudges. First match wins.
COMMAND_HINTS = [
    (re.compile(r"^\s*gh\s+(pr|issue|run|repo)\s+(view|list)\b"),
     "Pass `--json <fields> --jq '<projection>'` to project to needed fields only."),
    (re.compile(r"^\s*gh\s+run\s+view\b.*--log(?!-failed)\b"),
     "Use `--log-failed` instead of `--log` — full logs are rarely needed."),
    (re.compile(r"^\s*git\s+(log|show)\b(?!.*--oneline)(?!.*--format)"),
     "Pass `--oneline -n N` or `--format=...` to project to needed fields."),
    (re.compile(r"^\s*git\s+diff\b(?!.*--stat)(?!.*--name-only)"),
     "Try `git diff --stat` first; fetch full patch only for files you'll describe."),
    (re.compile(r"^\s*git\s+status\b(?!.*--short)(?!.*-s\b)"),
     "Use `git status --short` for one line per file."),
    (re.compile(r"^\s*jq\b(?!.*-c\b)"),
     "Pass `-c` for compact output, or project with `jq '{key1, key2}'`."),
    (re.compile(r"^\s*aws\s+\S+\s+\S+\b(?!.*--query)"),
     "Pass `--query '<JMESPath>'` to project to needed fields."),
    (re.compile(r"^\s*kubectl\s+(get|describe)\b(?!.*-o\b)(?!.*--output)"),
     "Use `-o jsonpath=...` or `-o yaml | yq '.section'` to slice output."),
    (re.compile(r"^\s*docker\s+(ps|images)\b(?!.*--format)"),
     "Pass `--format '{{.Field1}}\\t{{.Field2}}'` to project to needed columns."),
    (re.compile(r"^\s*(find|ls\s+-[a-zA-Z]*R)\b"),
     "Use the Glob tool instead of recursive `find`/`ls`."),
    (re.compile(r"^\s*cat\s+\S+"),
     "Use the Read tool instead of `cat`."),
]

GENERIC_HINT = (
    "Output exceeded the verbosity threshold. "
    "See plugin/shared/output-minimization.md for compact-flag patterns."
)


def emit(message: str) -> None:
    """Emit additionalContext as PostToolUse JSON and exit."""
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": f"[output-guard] {message}",
        }
    }
    json.dump(payload, sys.stdout)
    sys.exit(0)


def main() -> None:
    try:
        data = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    if data.get("tool_name") != "Bash":
        sys.exit(0)

    response = data.get("tool_response") or {}
    stdout = response.get("stdout") or ""
    if not stdout:
        sys.exit(0)

    line_count = stdout.count("\n") + (0 if stdout.endswith("\n") else 1)
    char_count = len(stdout)

    if line_count <= LINE_THRESHOLD and char_count <= CHAR_THRESHOLD:
        sys.exit(0)

    command = (data.get("tool_input") or {}).get("command", "")
    first_segment = re.split(r"\s*(?:\|\||&&|[|;])\s*", command, maxsplit=1)[0]

    for pattern, hint in COMMAND_HINTS:
        if pattern.search(first_segment):
            emit(f"{line_count} lines / {char_count} chars. {hint}")
            return

    emit(f"{line_count} lines / {char_count} chars. {GENERIC_HINT}")


if __name__ == "__main__":
    main()
