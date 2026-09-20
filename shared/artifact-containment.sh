#!/usr/bin/env bash
# artifact-containment.sh — does a resolved artifact path swallow the configuration directory?
#
# Sourced, never executed. The one copy of this check: /create-requirements'
# optional-agent gate, /configuration-init's artifact validation and the task
# store's write gating all source it rather than carrying their own. Two copies
# already existed with a note saying "keep them identical", which is a promise
# nothing enforces; a third would have been the one that drifted.
#
# Why the check exists: an artifact resolving to the directory that holds
# configuration.yml — or to any ancestor of it — hands whatever reads or writes
# there settings.json, session-state/ and worktrees/ instead of the artifact.
# `subdir: .` on the `local` location is the everyday way to get there.
#
# No `set -e` at file scope: this file is sourced into callers with their own
# error handling.

# nexus_path_holds_config_dir <resolved_path> <config_file>
#
# Returns 0 when <resolved_path> IS the directory holding <config_file>, or an
# ancestor of it (the filesystem root included). Returns 1 otherwise — a sibling
# or a subdirectory of the configuration directory is not a match.
#
# An empty <resolved_path> returns 0: with nothing to compare, the answer that
# fails closed is "it might contain it".
#
# Both traps below are load-bearing, and both were shipped before they were
# found:
#   - The trailing slash is stripped. A resolved path of "/" otherwise builds the
#     pattern "//*", which matches no real directory, so the filesystem root —
#     the maximal case — was waved through.
#   - It is stripped into its OWN variable. Writing the suffix removal inline in
#     the case pattern, followed by the slash-star, does not work: bash reads the
#     `/` of the removal operator as part of the pattern and the branch silently
#     never matches.
# Comparing against "${config_dir}/" makes the equality case fall out of the
# same glob as the ancestor case.
nexus_path_holds_config_dir() {
  local path="${1-}"
  local config_file="${2-}"
  local config_dir=""
  local path_base=""
  [ -n "$path" ] || return 0
  config_dir="${config_file%/*}"
  path_base="${path%/}"
  case "${config_dir}/" in
    "$path_base"/*) return 0 ;;
  esac
  return 1
}
