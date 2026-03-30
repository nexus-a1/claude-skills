#!/usr/bin/env python3
"""
bash-token-filter.py — Claude Code PreToolUse hook for reducing bash output tokens.

Usage in hooks.json:
  PreToolUse  → python3 <plugin>/hooks/bash-token-filter.py pre

Rewrites commands with quiet/silent flags to reduce noisy output from
package managers, git operations, and build tools.

Note: PostToolUse hooks cannot replace output for built-in tools (only MCP
tools support updatedMCPToolOutput), so output filtering is not implemented.
"""

import json
import re
import sys

# ── Quiet flag injection map for PreToolUse ────────────────────────────────
# Each entry: (command_regex, flag_to_inject, where_to_inject)
QUIET_OVERRIDES = [
    # npm (install/ci only — npm run/test output is typically needed)
    (re.compile(r'^npm\s+install\b(?!.*--silent)'), '--silent', 'after_subcommand'),
    (re.compile(r'^npm\s+ci\b(?!.*--silent)'), '--silent', 'after_subcommand'),
    # pip
    (re.compile(r'^pip3?\s+install\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    # cargo (build only — cargo test output is needed to see results)
    (re.compile(r'^cargo\s+build\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    # git (operational commands only, not status/log/diff)
    (re.compile(r'^git\s+push\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    (re.compile(r'^git\s+pull\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    (re.compile(r'^git\s+fetch\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    (re.compile(r'^git\s+clone\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    (re.compile(r'^git\s+checkout\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    (re.compile(r'^git\s+merge\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    (re.compile(r'^git\s+rebase\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    # wget
    (re.compile(r'^wget\b(?!.*\s-q)'), '-q', 'after_command'),
    # curl (add -s only if no existing -s in any flag group/--silent; allow -S to coexist)
    (re.compile(r'^curl\b(?!.*\s-[a-zA-Z]*s)(?!.*--silent)'), '-s', 'after_command'),
    # docker
    (re.compile(r'^docker\s+build\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    (re.compile(r'^docker\s+pull\b(?!.*\s-q)'), '-q', 'after_subcommand'),
    # make
    (re.compile(r'^make\b(?!.*\s-s)(?!.*--silent)'), '-s', 'after_command'),
]

# Regex to split on the first shell operator (|, ||, &&, ;) while preserving it
_SHELL_SPLIT_RE = re.compile(r'(\s*(?:\|\||&&|[|;])\s*)')


def read_input():
    """Read JSON from stdin."""
    try:
        return json.loads(sys.stdin.read())
    except (json.JSONDecodeError, EOFError):
        return {}


def split_first_command(command):
    """Split command into (first_command, rest) at the first shell operator.

    Returns (first_command, rest) where rest includes the operator.
    If no operator found, rest is empty string.
    """
    parts = _SHELL_SPLIT_RE.split(command, maxsplit=1)
    if len(parts) == 1:
        return parts[0], ''
    return parts[0], ''.join(parts[1:])


def inject_flag(command, flag, position):
    """Inject a quiet flag into a command string."""
    parts = command.split()
    if not parts:
        return command
    if position == 'after_command':
        parts.insert(1, flag)
    elif position == 'after_subcommand':
        idx = min(2, len(parts))
        parts.insert(idx, flag)
    return ' '.join(parts)


def handle_pre_tool_use(data):
    """Rewrite commands with quiet flags."""
    tool_input = data.get('tool_input', {})
    command = tool_input.get('command', '')

    if not command:
        sys.exit(0)

    # Only modify the first command in a pipeline/chain
    first_cmd, rest = split_first_command(command)
    base_cmd = first_cmd.strip()

    for pattern, flag, position in QUIET_OVERRIDES:
        if pattern.search(base_cmd):
            modified_base = inject_flag(base_cmd, flag, position)
            new_command = modified_base + rest
            if new_command != command:
                cmd_name = base_cmd.split()[0]
                subcmd = base_cmd.split()[1] if len(base_cmd.split()) > 1 else ''
                teaching_note = (
                    f"[token-filter: ran with {flag} to reduce output — "
                    f"prefer `{cmd_name} {subcmd} {flag}` in future commands]"
                )
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "updatedInput": {"command": new_command},
                        "additionalContext": teaching_note,
                    }
                }
                json.dump(output, sys.stdout)
            sys.exit(0)

    sys.exit(0)


def main():
    if len(sys.argv) < 2:
        print("Usage: bash-token-filter.py pre", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]
    data = read_input()

    tool_name = data.get('tool_name', '')
    if tool_name != 'Bash':
        sys.exit(0)

    if mode == 'pre':
        handle_pre_tool_use(data)
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
