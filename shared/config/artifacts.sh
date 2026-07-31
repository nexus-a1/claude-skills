#!/usr/bin/env bash
# shellcheck shell=bash
#
# Artifact-catalog helpers for /configuration-init.
#
# The shipped template (templates/configuration.yml) is the single source of
# truth for which artifact types exist. This library reads that catalog live and
# compares it against a project's configuration.yml. It deliberately holds no
# artifact-name list of its own — re-hardcoding the names here would recreate
# the drift this library exists to eliminate.
#
# Sourced, not executed: it shares the caller's PLAN/TIMESTAMP state, matching
# how configuration-init already sources shared/resolve-config.sh. Do not add
# `set -euo pipefail` at file scope — it would leak into the caller's shell.
#
# Distinct from shared/resolve-config.sh: that resolves *runtime* artifact paths
# and always returns a value (falling back to defaults). These functions perform
# *existence* checks and must never be built on it, or "has" is always true.
#
# Public API is `artifact_*`, matching resolve_* in resolve-config.sh and jira_*
# in jira/jira.sh.

# Locate the shipped configuration template.
# Prints the path on stdout; returns 1 when no readable template exists, which
# every caller must treat as "skip the template-dependent check", never as a
# fatal error.
artifact_template_path() {
  if [[ -r "${CLAUDE_PLUGIN_ROOT:-}/templates/configuration.yml" ]]; then
    printf '%s\n' "${CLAUDE_PLUGIN_ROOT}/templates/configuration.yml"
  elif [[ -r "$HOME/.claude/templates/configuration.yml" ]]; then
    printf '%s\n' "$HOME/.claude/templates/configuration.yml"
  else
    return 1
  fi
}

# List the artifact names defined in a template (or any config-shaped file).
#
# `// {}` is load-bearing: `keys` on a null node is an error, so a file with no
# storage section would abort the caller instead of yielding an empty catalog.
#
# The name filter is also load-bearing: these keys are fed back into yq path
# expressions. Every such expression uses strenv() so a key cannot escape into
# the expression, and this whitelist is the second layer.
#
# LC_ALL=C is not cosmetic. Under a UTF-8 locale GNU grep expands [A-Za-z] by
# collation order, which admits accented letters — verified: `unicode-łąka`
# passes the unanchored-locale filter and is rejected under C. (Some greps,
# e.g. ugrep, are strict either way, so this leaks only on some machines —
# exactly the kind of difference that would not show up in one developer's
# testing.)
artifact_template_keys() {
  local tmpl="$1"
  [[ -r "$tmpl" ]] || return 1
  yq -r '.storage.artifacts // {} | keys | .[]' "$tmpl" 2>/dev/null \
    | LC_ALL=C grep -xE '[A-Za-z0-9_-]+' || true
}

# True when a subdir value is safe to append to a storage base and to emit into
# YAML. Rejects absolute paths and any `..` component — either would place
# files outside the storage location — and anything outside a conservative
# character set, since a value containing `:`, `#` or a newline can inject
# structure into the generated config.
#
# Spaces are allowed: they are legal in a directory name, callers quote their
# expansions, and emitted scalars are quoted. Rejecting them would break a
# legitimate `subdir: my notes` for no security benefit.
artifact_subdir_is_safe() {
  local sub="$1"
  [[ -n "$sub" ]] || return 1
  [[ "$sub" != /* ]] || return 1
  [[ "$sub" != ".." && "$sub" != "../"* && "$sub" != *"/../"* && "$sub" != *"/.." ]] || return 1
  [[ "$sub" =~ ^[A-Za-z0-9\ ._/-]+$ ]] || return 1
  return 0
}

# True when a string is usable as a plain mapping key: ASCII letters, digits,
# underscore, dash. Used for location names, which are emitted into YAML and
# interpolated into yq path expressions.
#
# LC_ALL=C for exactly the reason artifact_template_keys pins it, and it is just
# as easy to miss here: bash compiles [[ =~ ]] against the current locale, so
# under a UTF-8 locale [A-Za-z] expands by collation order and admits accented
# letters. Verified — `téam` passes under en_US.UTF-8 and is rejected under C.
# `local` scopes the setting to this function and bash restores it on return.
artifact_key_is_safe() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# Read one field (location|subdir) of one artifact. Prints the empty string when
# the artifact or field is absent, so callers can test with -z.
artifact_template_field() {
  local tmpl="$1" name="$2" field="$3"
  [[ -r "$tmpl" ]] || return 1
  k="$name" f="$field" yq -r \
    '.storage.artifacts[strenv(k)][strenv(f)] // ""' "$tmpl" 2>/dev/null
}

# True when the config already defines this artifact, whatever it maps to.
#
# yq is the only authority here. An earlier version used `grep -qF` as a cheap
# negative prefilter on the theory that a name absent as a substring is
# definitely absent. That is false: YAML unescapes keys, so a config written as
#   "meet\x69ngs": {location: local, subdir: notes}
# contains no literal "meetings" for grep to find while yq's has() reports true.
# The prefilter therefore answered "absent" for a key the user had already
# mapped, and the backfill overwrote their subdir — verified. It also saved
# nothing measurable, since yq runs anyway whenever the artifact is present.
#
# select(document_index == 0) confines the answer to the first document.
# Without it a multi-document file yields one line per document ("true\nfalse"),
# which never equals "true" and reports a present artifact as missing.
artifact_config_has() {
  local cfg="$1" name="$2"
  [[ -r "$cfg" ]] || return 1
  [[ "$(k="$name" yq -r \
        'select(document_index == 0) | .storage.artifacts // {} | has(strenv(k))' \
        "$cfg" 2>/dev/null)" == "true" ]]
}

# True when the config defines this storage location.
artifact_config_has_location() {
  local cfg="$1" loc="$2"
  [[ -r "$cfg" ]] || return 1
  [[ "$(l="$loc" yq -r \
        'select(document_index == 0) | .storage.locations // {} | has(strenv(l))' \
        "$cfg" 2>/dev/null)" == "true" ]]
}

# Historical names for storage locations, one `<legacy>:<canonical>` pair per
# line.
#
# This is the one place a superseded location name is recorded, and it is the
# only hardcoded name list this library carries. It has to be hardcoded: a
# rename maps a name that no longer appears anywhere onto one that does, so
# there is nothing left to read it from. The canonical half is not free —
# `test_every_canonical_alias_is_a_real_template_location` fails the suite if it
# ever stops matching plugin/templates/configuration.yml, which is what keeps
# this from drifting the way the artifact lists did.
#
# `team-repo` is what /configuration-init generated for the shared location
# before SKILLS-074; the shipped template has always called it `team-knowledge`.
artifact_legacy_locations() {
  printf 'team-repo:team-knowledge\n'
}

# Plan location renames for one config.
#
# Emits one `location-rename:<config>:<legacy>:<canonical>` line per applicable
# pair. Warnings go to stderr, matching artifact_plan_backfill.
#
# A config that already defines both names is reported and skipped. That is a
# merge, not a rename: the two locations may point at different paths, and
# picking a winner would silently discard one of them.
artifact_plan_location_rename() {
  local cfg="$1" pair legacy canon
  [[ -r "$cfg" ]] || return 1

  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    legacy="${pair%%:*}"
    canon="${pair##*:}"

    # `if` rather than `... || continue`: under `set -e` a failing left operand
    # of a list aborts the caller, and callers are free to set -e.
    if ! artifact_config_has_location "$cfg" "$legacy"; then
      continue
    fi
    if artifact_config_has_location "$cfg" "$canon"; then
      printf '⚠ Skipping location rename "%s" → "%s" in %s — both names are already defined. Reconcile them by hand.\n' \
        "$legacy" "$canon" "$cfg" >&2
      continue
    fi

    printf 'location-rename:%s:%s:%s\n' "$cfg" "$legacy" "$canon"
  done < <(artifact_legacy_locations)
}

# Diff a template's artifact catalog against a config.
#
# Emits one `artifact-backfill:<config>:<name>` line per artifact that is
# missing and safe to add. Warnings go to stderr so the caller's plan array
# stays clean.
#
# Two artifacts are deliberately skipped rather than written:
#   - already present  — never overwrite a user's mapping
#   - location undefined in the target config — writing it would leave a
#     dangling reference that validation then reports as a failure, i.e. the
#     migration would break the config it just "fixed"
#
# $3.. are locations that do not exist in the config yet but will by the time
# apply runs — the canonical halves of any location renames planned in the same
# migration. Without them a config still on a legacy location name has every
# team-located artifact skipped, so `validate` keeps naming a remedy that had
# just run: rename lands, backfill does not, and the next run is needed to
# finish a job the user was told was complete. Passing a location here does not
# make apply write a dangling reference — artifact_apply_backfill re-checks
# against the real config, by which point the rename has landed.
artifact_plan_backfill() {
  local cfg="$1" tmpl="$2"
  # "${@:3}" rather than `shift 2`: shift returns non-zero when fewer than two
  # arguments were passed, which aborts a `set -e` caller instead of letting the
  # readability check below return 1.
  local pending=("${@:3}")
  local name loc sub p pending_match
  [[ -r "$cfg" && -r "$tmpl" ]] || return 1

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    # `if` rather than `... && continue`: under `set -e` a failing left operand
    # of a && list aborts the caller, and callers are free to set -e.
    if artifact_config_has "$cfg" "$name"; then
      continue
    fi

    loc="$(artifact_template_field "$tmpl" "$name" location)"
    sub="$(artifact_template_field "$tmpl" "$name" subdir)"
    if [[ -z "$loc" || -z "$sub" ]]; then
      printf '⚠ Skipping artifact "%s" — its template entry is incomplete.\n' \
        "$name" >&2
      continue
    fi

    if ! artifact_config_has_location "$cfg" "$loc"; then
      pending_match=false
      # ${#pending[@]} is safe on an empty array even under `set -u`, which a
      # bare "${pending[@]}" is not on older bash.
      if (( ${#pending[@]} > 0 )); then
        for p in "${pending[@]}"; do
          if [[ "$p" == "$loc" ]]; then
            pending_match=true
            break
          fi
        done
      fi
      if [[ "$pending_match" == false ]]; then
        printf '⚠ Skipping artifact "%s" — its location "%s" is not defined in %s.\n' \
          "$name" "$loc" "$cfg" >&2
        continue
      fi
    fi

    printf 'artifact-backfill:%s:%s\n' "$cfg" "$name"
  done < <(artifact_template_keys "$tmpl")
}

# Names in the template that the config does not define, one per line.
# Backs the validate-mode drift warning. Unlike artifact_plan_backfill this
# reports every missing artifact, including ones that cannot be backfilled —
# the user still needs to know their config has drifted.
artifact_missing_names() {
  local cfg="$1" tmpl="$2"
  local name
  [[ -r "$cfg" && -r "$tmpl" ]] || return 1

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    artifact_config_has "$cfg" "$name" || printf '%s\n' "$name"
  done < <(artifact_template_keys "$tmpl")
}

# Render the `storage.artifacts:` mapping for a freshly generated config.
#
# Emits every artifact the template defines, so a new config can never ship
# incomplete — that incompleteness is what makes resolution fall back to a
# guess that is wrong whenever the local base is not the conventional one.
#
# $2 is the name of the configured shared location, or empty for a solo setup.
# Template artifacts that live in a shared location are remapped to it; with no
# shared location configured they become local, keeping the template's subdir.
# Written at the indentation `storage.artifacts:` expects.
artifact_wizard_yaml() {
  local tmpl="$1" team_location="${2:-}"
  local name loc sub
  [[ -r "$tmpl" ]] || return 1

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    loc="$(artifact_template_field "$tmpl" "$name" location)"
    sub="$(artifact_template_field "$tmpl" "$name" subdir)"
    [[ -n "$loc" && -n "$sub" ]] || continue
    # Values reach mkdir and the generated YAML. Reject anything that would
    # escape the storage base or inject structure. Defence in depth: today the
    # only input is the plugin's own template.
    artifact_subdir_is_safe "$sub" || continue

    if [[ "$loc" != "local" ]]; then
      if [[ -n "$team_location" ]]; then
        loc="$team_location"
      else
        loc="local"
      fi
    fi
    # Same defence as the subdir check, applied symmetrically: a location name
    # containing `:` or a newline would inject structure into the config this
    # renders. $2 is caller-supplied, so this is not purely hypothetical.
    #
    # Warn rather than skip silently: dropping every shared artifact without a
    # word would produce exactly the incomplete config this function exists to
    # prevent, and the caller would have no way to notice.
    if ! artifact_key_is_safe "$loc"; then
      printf 'Skipping artifact "%s" — location name "%s" is not a valid key.\n' \
        "$name" "$loc" >&2
      continue
    fi

    # subdir is quoted: it may legitimately contain a space or start with a
    # dash, either of which changes meaning as a plain YAML scalar.
    printf '    %s:\n      location: %s\n      subdir: "%s"\n' "$name" "$loc" "$sub"
  done < <(artifact_template_keys "$tmpl")
}

# Subdirectories that need creating under the local storage base, one per line.
#
# Driven by the written config rather than the template: an artifact the user
# pointed at a shared location must not also get a stray local directory. `.`
# is skipped — it is the location root, which already exists.
artifact_local_dirs() {
  local cfg="$1" sub
  [[ -r "$cfg" ]] || return 1
  while IFS= read -r sub; do
    # The config is user-editable, and these values become mkdir arguments.
    artifact_subdir_is_safe "$sub" || continue
    printf '%s\n' "$sub"
  done < <(yq -r '
    select(document_index == 0)
    | .storage.artifacts // {} | to_entries | .[]
    | select(.value.location == "local")
    | select(.value.subdir != null and .value.subdir != ".")
    | .value.subdir
  ' "$cfg" 2>/dev/null || true)
}

# Back up a file at most once per migration run.
#
# The migration computes one TIMESTAMP for the whole run and every verb writes
# <file>.bak-$TIMESTAMP. Until now each verb targeted a distinct file, so a
# plain `cp` was safe. Backfill is the first verb that can target
# configuration.yml a second time in one run: with a plain `cp` the second verb
# would overwrite the first verb's backup with the already-rewritten
# intermediate, and the pre-run original would be unrecoverable.
#
# Skipping when the backup exists keeps the *earliest* copy, which is the one
# that predates every change in the run.
#
# "Exists" has to mean "is a regular file we wrote". A bare -e test is true for
# a directory or a symlink resolving to an existing file, and in both cases
# reporting success would mean the caller rewrites the original with no backup
# behind it — the failure this function exists to prevent. Anything else at
# that path is refused, so the caller stops instead of proceeding blind.
#
# Callers MUST check the return value.
artifact_backup_once() {
  local file="$1" timestamp="$2" bak
  bak="${file}.bak-${timestamp}"

  if [[ -L "$bak" ]]; then
    printf 'Backup path %s is a symlink; refusing to write through it.\n' "$bak" >&2
    return 1
  fi
  if [[ -e "$bak" ]]; then
    if [[ -f "$bak" ]]; then
      return 0
    fi
    printf 'Backup path %s exists and is not a regular file.\n' "$bak" >&2
    return 1
  fi

  cp -p -- "$file" "$bak"
}

# True when the yq on PATH round-trips comments.
#
# A version-string check is the wrong instrument in both directions: mikefarah
# builds before v4.30 print no "mikefarah" substring, and a matching string is
# not a behavioural guarantee. The acceptance criterion is written in terms of
# capability, so probe the capability.
#
# This matters because the install docs say `apt install yq`, which on
# Debian/Ubuntu installs python-yq — a jq wrapper that silently drops every
# comment in the file it rewrites.
artifact_yq_preserves_comments() {
  local probe rc=0
  probe="$(mktemp)" || return 1

  # Explicit cleanup on every path rather than a RETURN trap: a RETURN trap
  # here deadlocks when the caller combines `set -e` with `eval`, which is
  # exactly what the test harness does.
  if ! printf '# leading\nstorage:\n  artifacts:\n    probe: {location: local}  # trailing\n' \
       > "$probe"; then
    rm -f "$probe"
    return 1
  fi

  if yq -i '.__probe = true' "$probe" 2>/dev/null; then
    grep -q '# leading' "$probe" && grep -q '# trailing' "$probe" || rc=1
  else
    rc=1
  fi

  rm -f "$probe"
  return "$rc"
}

# Message explaining a refusal to rewrite, for callers to print on stderr.
artifact_yq_refusal_message() {
  local file="$1"
  printf 'Refusing to rewrite %s: the yq on PATH does not preserve comments (%s).\n' \
    "$file" "$(yq --version 2>&1 | head -1)"
  printf 'Install mikefarah/yq v4. Note that "apt install yq" installs python-yq,\n'
  printf 'which rewrites YAML without comments and would strip this file.\n'
}

# Add one artifact to a config, using the template's mapping.
#
# A targeted assignment rather than a whole-file rewrite, so comments and
# unrelated structure survive.
#
# Callers must run artifact_backup_once first — this function does not back up,
# matching how the existing migration verbs separate the two steps.
artifact_apply_backfill() {
  local cfg="$1" tmpl="$2" name="$3" loc sub

  # Never overwrite a mapping the user already has, whatever it points at.
  # The plan phase already filters these out, but relying on the caller to
  # enforce an invariant this function can enforce itself is how a mapping
  # someone deliberately relocated gets silently "corrected" by a future
  # caller. No-op success keeps repeat runs idempotent.
  if artifact_config_has "$cfg" "$name"; then
    return 0
  fi

  loc="$(artifact_template_field "$tmpl" "$name" location)"
  sub="$(artifact_template_field "$tmpl" "$name" subdir)"
  if [[ -z "$loc" || -z "$sub" ]]; then
    return 1
  fi
  artifact_subdir_is_safe "$sub" || return 1

  # Re-check referential integrity for the same reason the presence check is
  # duplicated: a caller applying an entry directly would otherwise write a
  # dangling location reference, which validation then reports as a failure —
  # the migration breaking the config it just "fixed".
  artifact_config_has_location "$cfg" "$loc" || return 1

  # The write is scoped to document 0 for the same reason the presence check
  # is: an unscoped `yq -i` assignment applies to EVERY document, so on a
  # multi-document config the entry was added twice — once where it belonged
  # and once in a document that had never been examined. Parenthesising the
  # left-hand side scopes the assignment without filtering the output, which
  # `select(...) | ...` would do (deleting every other document).
  k="$name" l="$loc" s="$sub" yq -i \
    '(select(document_index == 0) | .storage.artifacts[strenv(k)]) = {"location": strenv(l), "subdir": strenv(s)}' \
    "$cfg" || return 1

  # The file must still parse, and the key must actually be there. Without
  # both, a silent partial write would be reported as success.
  yq -e '.' "$cfg" >/dev/null 2>&1 || return 1
  artifact_config_has "$cfg" "$name"
}

# Rename a storage location and repoint every artifact that referenced it.
#
# Both halves land in a single `yq -i` write. Splitting them would leave a
# window — and, on a failure between the two, a permanent state — where every
# artifact points at a location that no longer exists, which is precisely the
# dangling reference the backfill verb refuses to create.
#
# Callers must run artifact_backup_once first; this function does not back up,
# matching artifact_apply_backfill and the other migration verbs.
artifact_apply_location_rename() {
  local cfg="$1" old="$2" new="$3" yq_expr artifacts_type

  [[ -r "$cfg" && -w "$cfg" ]] || return 1
  # Both names are interpolated into a yq path expression via strenv(), so they
  # cannot escape it; this is the second layer, and it also rejects the
  # nonsensical cases (empty, identical) outright.
  artifact_key_is_safe "$old" || return 1
  artifact_key_is_safe "$new" || return 1
  [[ "$old" != "$new" ]] || return 1

  # Re-check both preconditions rather than trusting the plan phase, for the
  # same reason artifact_apply_backfill re-checks its own: this is public API,
  # and a caller applying an entry directly would otherwise overwrite a
  # canonical location the user already has.
  artifact_config_has_location "$cfg" "$old" || return 1
  if artifact_config_has_location "$cfg" "$new"; then
    return 1
  fi

  yq_expr='with(select(document_index == 0);
      .storage.locations[strenv(n)] = .storage.locations[strenv(o)]
      | del(.storage.locations[strenv(o)])'

  # The repoint clause is appended only when the config actually has a mapping
  # of artifacts. Included unconditionally, yq creates the path it assigns
  # through, so a config with no `storage.artifacts` came back with
  # `artifacts: []` — an empty *sequence* where a mapping belongs, which then
  # breaks has() for every later reader. Verified against yq v4.52.2; `[]?`
  # does not avoid it, because path creation happens on the assignment target.
  artifacts_type="$(yq -r \
    'select(document_index == 0) | .storage.artifacts | type' "$cfg" 2>/dev/null)"
  if [[ "$artifacts_type" == "!!map" ]]; then
    yq_expr="$yq_expr
      | (.storage.artifacts[] | select(.location == strenv(o)) | .location) = strenv(n)"
  fi
  yq_expr="$yq_expr)"

  o="$old" n="$new" yq -i "$yq_expr" "$cfg" || return 1

  # Verify the whole rename landed: the file still parses, the canonical name
  # exists, the legacy name is gone, and nothing still references it. A partial
  # write reported as success is how a config ends up with the dangling
  # references this verb exists to remove.
  yq -e '.' "$cfg" >/dev/null 2>&1 || return 1
  artifact_config_has_location "$cfg" "$new" || return 1
  if artifact_config_has_location "$cfg" "$old"; then
    return 1
  fi
  [[ -z "$(o="$old" yq -r '
    select(document_index == 0)
    | .storage.artifacts // {} | to_entries | .[]
    | select(.value | type == "!!map")
    | select(.value.location == strenv(o))
    | .key' "$cfg" 2>/dev/null)" ]]
}
