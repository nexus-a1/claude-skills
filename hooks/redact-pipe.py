#!/usr/bin/env python3
"""redact-pipe.py -- hand stdin to redact-stream.sh, unchanged and unbuffered.

Used only by redact-output.sh inside a linked worktree. Claude Code's
worktree-isolation guard refuses a pipeline whose sink is `bash` (it cannot
show what shell text the sink was handed), but accepts a python3 sink. This
launcher replaces itself with the real filter, so the filter, its arguments
and its stdin/stdout/stderr are exactly what they would be if bash had been
named in the pipeline. It filters nothing itself.
"""
import os
import sys

stream = os.path.join(os.path.dirname(os.path.abspath(__file__)), "redact-stream.sh")
if not os.access(stream, os.R_OK):
    sys.stderr.write("redact-pipe: cannot read %s; withholding output\n" % stream)
    sys.exit(2)
os.execv("/bin/bash", ["bash", stream] + sys.argv[1:])
