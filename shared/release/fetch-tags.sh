#!/usr/bin/env bash
# plugin/shared/release/fetch-tags.sh
#
# Thin executable wrapper around lib.sh::_fetch_tags, for use in skill Context
# directives. Context !-backtick commands cannot contain compound shell
# operators (|, &&, ;) — see validator A5 — so the source/call/echo logic that
# would otherwise be inlined lives here behind a single command invocation.
#
# Fetches remote tags (remote-authoritative, bounded, warn-and-continue) and
# prints either the [stale-tags]/[no-remote] marker emitted by _fetch_tags or a
# success note. Always exits 0 so a fetch failure never aborts skill load.
set -uo pipefail

PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PLUGIN_RELEASE_DIR/lib.sh"

out=$(_fetch_tags 2>&1)
echo "${out:-(fetched fresh from origin)}"
exit 0
