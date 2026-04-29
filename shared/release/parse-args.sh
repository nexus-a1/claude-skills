#!/usr/bin/env bash
# plugin/shared/release/parse-args.sh
#
# Deterministic argument parser for the release-management skills.
# The four skills (/create-release-branch, /create-release, /merge-release,
# /release) accept similar but distinct argument grammars; this script
# normalizes them into a single JSON document so the dispatching skill
# prompt does not have to re-derive parsing logic on every call.
#
# Usage:
#   bash parse-args.sh --skill=<skill> [--json] -- <raw $ARGUMENTS>...
#
# Skills supported:
#   branch-create        — /create-release-branch <version> [source]
#   pr-merge             — /merge-release [release-branch | version]
#   pr-create            — /create-release [target] [version]
#   release-create       — /release [version] [branch] [--pre-release] [--fasttrack|-y|--yes]
#
# Output (with --json):
#   { "version": "v1.2.0" | null,
#     "version_raw": "v1.2.0" | null,    # exactly what the user typed
#     "source": "origin/master" | null,
#     "source_kind": "branch" | "tag" | null,
#     "target": "master" | null,
#     "release_branch": "release/v1.2.0" | null,
#     "prerelease": true | false | null,
#     "fasttrack": true | false,
#     "errors": [],                       # non-empty → EX_USER
#     "missing": []                       # non-empty → EX_AMBIGUOUS
#   }
#
# Exit codes (from lib.sh):
#   0  EX_OK         — fully parsed
#   10 EX_AMBIGUOUS  — required field missing, caller must prompt
#   20 EX_USER       — malformed input (e.g. bad version shape)
#   30 EX_SYSTEM     — internal error (unknown skill, jq missing if --json)
set -euo pipefail

PLUGIN_RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PLUGIN_RELEASE_DIR/lib.sh"

skill=""
json=0
positional=()

while (( $# > 0 )); do
  case "$1" in
    --skill=*) skill="${1#--skill=}"; shift ;;
    --skill)   skill="${2:-}"; shift 2 ;;
    --json)    json=1; shift ;;
    --)        shift; positional+=("$@"); break ;;
    *)         positional+=("$1"); shift ;;
  esac
done

if [[ -z "$skill" ]]; then
  _die "$EX_SYSTEM" "parse-args.sh: --skill=<name> is required"
fi

# ---------------------------------------------------------------------------
# Per-skill grammars
# ---------------------------------------------------------------------------
version=""
version_raw=""
source_ref=""
source_kind=""
target=""
release_branch=""
prerelease=""        # tri-state: "" (unset), "true", "false"
fasttrack="false"
errors=()
missing=()

# Detect whether a token looks like a version (with or without v prefix,
# optional prerelease suffix). Used to disambiguate single-arg invocations.
_looks_like_version() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]
}

case "$skill" in
  branch-create)
    # /create-release-branch <version> [source]
    # source defaults to origin/master; tag@vX.Y.Z syntax is supported.
    pos1="${positional[0]:-}"
    pos2="${positional[1]:-}"

    if [[ -n "$pos1" ]]; then
      if _looks_like_version "$pos1"; then
        version_raw="$pos1"
        if normalized=$(_normalize_version "$pos1"); then
          version="$normalized"
        else
          errors+=("invalid version: '$pos1'")
        fi
      else
        # First arg isn't a version; treat as source, leave version unset.
        pos2="$pos1"
        pos1=""
      fi
    fi

    # Defensive: reject argument shapes that look like CLI options to keep
    # downstream `git rev-parse`/`gh` invocations safe from option injection.
    if [[ -n "$pos2" && "$pos2" == -* ]]; then
      errors+=("source must not start with '-': '$pos2'")
      pos2=""
    fi

    if [[ -n "$pos2" ]]; then
      if [[ "$pos2" == tag@* ]]; then
        source_kind="tag"
        local_tag="${pos2#tag@}"
        # Normalize tag to v-prefix form, but only if it parses as a version;
        # otherwise pass through verbatim (could be an arbitrary tag name).
        if _looks_like_version "$local_tag"; then
          local_tag=$(_normalize_version "$local_tag")
        fi
        source_ref="$local_tag"
      else
        source_kind="branch"
        source_ref="$pos2"
      fi
    else
      source_kind="branch"
      source_ref="origin/master"
    fi

    if [[ -z "$version" && ${#errors[@]} -eq 0 ]]; then
      missing+=("version")
    fi
    ;;

  pr-merge)
    # /merge-release [release-branch | version]
    # No arg → interactive mode (skill must list open release PRs and pick).
    # release/vX.Y.Z → use as-is.
    # vX.Y.Z (or X.Y.Z) → prefix with release/.
    pos1="${positional[0]:-}"

    if [[ -z "$pos1" ]]; then
      missing+=("release_branch")
    elif [[ "$pos1" == -* ]]; then
      errors+=("release branch must not start with '-': '$pos1'")
    elif [[ "$pos1" == release/* ]]; then
      release_branch="$pos1"
      candidate_version="${pos1#release/}"
      if _looks_like_version "$candidate_version"; then
        version_raw="$candidate_version"
        if normalized=$(_normalize_version "$candidate_version"); then
          version="$normalized"
        fi
        # Don't error if the version portion is non-canonical; the branch
        # name itself is what we operate on.
      fi
    elif _looks_like_version "$pos1"; then
      version_raw="$pos1"
      if normalized=$(_normalize_version "$pos1"); then
        version="$normalized"
        release_branch="release/$version"
      else
        errors+=("invalid version: '$pos1'")
      fi
    else
      errors+=("unrecognized argument: '$pos1' (expected release/vX.Y.Z or vX.Y.Z)")
    fi
    ;;

  pr-create)
    # /create-release [target] [version]
    # 0 args   → target defaults to master, version missing.
    # 1 arg    → if version-shaped → version; else → target.
    # 2 args   → target, version.
    pos1="${positional[0]:-}"
    pos2="${positional[1]:-}"

    # Defensive: reject argument shapes that look like CLI options.
    for arg in "$pos1" "$pos2"; do
      if [[ -n "$arg" && "$arg" == -* ]]; then
        errors+=("argument must not start with '-': '$arg'")
      fi
    done

    if (( ${#errors[@]} == 0 )); then
      if [[ -z "$pos1" && -z "$pos2" ]]; then
        target="master"
      elif [[ -n "$pos1" && -z "$pos2" ]]; then
        if _looks_like_version "$pos1"; then
          target="master"
          version_raw="$pos1"
          if normalized=$(_normalize_version "$pos1"); then
            version="$normalized"
          else
            errors+=("invalid version: '$pos1'")
          fi
        else
          target="$pos1"
        fi
      else
        target="$pos1"
        version_raw="$pos2"
        if _looks_like_version "$pos2"; then
          if normalized=$(_normalize_version "$pos2"); then
            version="$normalized"
          else
            errors+=("invalid version: '$pos2'")
          fi
        else
          errors+=("invalid version: '$pos2' (expected vX.Y.Z)")
        fi
      fi

      if [[ -z "$version" && ${#errors[@]} -eq 0 ]]; then
        missing+=("version")
      fi

      if [[ -n "$version" ]]; then
        release_branch="release/$version"
      fi
    fi
    ;;

  release-create)
    # /release [version] [branch] [--pre-release] [--fasttrack|-y|--yes]
    #
    # Branch defaults to origin/master (per release-concepts: stable releases
    # come off master). Users may pass a different branch — most commonly a
    # release/* branch when publishing an RC.
    #
    # Sweep the release-create-specific flags out of `positional`, then
    # classify the remaining tokens.
    rc_positional=()
    for arg in "${positional[@]+"${positional[@]}"}"; do
      case "$arg" in
        --pre-release|--prerelease) prerelease="true" ;;
        --fasttrack|-y|--yes)       fasttrack="true" ;;
        *) rc_positional+=("$arg") ;;
      esac
    done

    pos1="${rc_positional[0]:-}"
    pos2="${rc_positional[1]:-}"

    # Defensive: reject argument shapes that look like CLI options.
    for arg in "$pos1" "$pos2"; do
      if [[ -n "$arg" && "$arg" == -* ]]; then
        errors+=("argument must not start with '-': '$arg'")
      fi
    done

    if (( ${#errors[@]} == 0 )); then
      # Helper: classify pos1 — version-like, release/*, or plain branch.
      classify_release_branch() {
        [[ "$1" == release/* ]]
      }

      if [[ -z "$pos1" && -z "$pos2" ]]; then
        target="origin/master"
      elif [[ -n "$pos1" && -z "$pos2" ]]; then
        if classify_release_branch "$pos1"; then
          # release/vX.Y.Z — treat as both branch and version source.
          target="$pos1"
          candidate_version="${pos1#release/}"
          if _looks_like_version "$candidate_version"; then
            version_raw="$candidate_version"
            if normalized=$(_normalize_version "$candidate_version"); then
              version="$normalized"
            fi
          fi
          # release/* branches imply pre-release unless the user pinned
          # prerelease=false (we only set true when not already set).
          if [[ -z "$prerelease" ]]; then
            prerelease="true"
          fi
        elif _looks_like_version "$pos1"; then
          target="origin/master"
          version_raw="$pos1"
          if normalized=$(_normalize_version "$pos1"); then
            version="$normalized"
          else
            errors+=("invalid version: '$pos1'")
          fi
        else
          # Plain branch hint with no version.
          target="$pos1"
        fi
      else
        # Two positionals: <version> <branch>.
        target="$pos2"
        version_raw="$pos1"
        if _looks_like_version "$pos1"; then
          if normalized=$(_normalize_version "$pos1"); then
            version="$normalized"
          else
            errors+=("invalid version: '$pos1'")
          fi
        else
          errors+=("invalid version: '$pos1' (expected vX.Y.Z)")
        fi
        # If branch is release/*, default prerelease=true unless overridden.
        if [[ "$target" == release/* && -z "$prerelease" ]]; then
          prerelease="true"
        fi
      fi

      if [[ -z "$version" && ${#errors[@]} -eq 0 ]]; then
        missing+=("version")
      fi
    fi
    ;;

  *)
    _die "$EX_SYSTEM" "parse-args.sh: unknown --skill '$skill'"
    ;;
esac

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
exit_code=$EX_OK
if (( ${#errors[@]} > 0 )); then
  exit_code=$EX_USER
elif (( ${#missing[@]} > 0 )); then
  exit_code=$EX_AMBIGUOUS
fi

if (( json )); then
  if ! _have_jq; then
    _die "$EX_SYSTEM" "parse-args.sh: --json requires jq on PATH"
  fi
  # Build JSON via jq for proper escaping. Pass each scalar as an arg.
  jq -n \
    --arg version        "$version" \
    --arg version_raw    "$version_raw" \
    --arg source         "$source_ref" \
    --arg source_kind    "$source_kind" \
    --arg target         "$target" \
    --arg release_branch "$release_branch" \
    --arg prerelease     "$prerelease" \
    --arg fasttrack      "$fasttrack" \
    --argjson errors     "$(printf '%s\n' "${errors[@]+"${errors[@]}"}" | jq -R . | jq -s .)" \
    --argjson missing    "$(printf '%s\n' "${missing[@]+"${missing[@]}"}" | jq -R . | jq -s .)" \
    '{
      version:        (if $version        == "" then null else $version        end),
      version_raw:    (if $version_raw    == "" then null else $version_raw    end),
      source:         (if $source         == "" then null else $source         end),
      source_kind:    (if $source_kind    == "" then null else $source_kind    end),
      target:         (if $target         == "" then null else $target         end),
      release_branch: (if $release_branch == "" then null else $release_branch end),
      prerelease:     (if $prerelease     == "" then null
                       elif $prerelease   == "true" then true else false end),
      fasttrack:      ($fasttrack == "true"),
      errors:         ($errors  | map(select(. != ""))),
      missing:        ($missing | map(select(. != "")))
    }'
else
  # Human-readable form.
  echo "skill:          $skill"
  echo "version:        ${version:-(unset)}"
  echo "source:         ${source_ref:-(unset)} (${source_kind:-?})"
  echo "target:         ${target:-(unset)}"
  echo "release_branch: ${release_branch:-(unset)}"
  echo "prerelease:     ${prerelease:-(unset)}"
  echo "fasttrack:      $fasttrack"
  if (( ${#errors[@]} > 0 )); then
    echo "errors:"
    printf '  - %s\n' "${errors[@]}"
  fi
  if (( ${#missing[@]} > 0 )); then
    echo "missing:"
    printf '  - %s\n' "${missing[@]}"
  fi
fi

exit "$exit_code"
