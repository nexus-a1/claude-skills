#!/bin/bash
# gate-runner.sh
# Run a project's deterministic pre-review checks ("gates") for /pr-review.
#
# THREAT MODEL — read before changing anything here.
#
# Gates are named in a project's .claude/configuration.yml, which any
# contributor to a cloned repository can write. Running /pr-review in a clone
# must not become a way to execute that contributor's code. Three controls,
# each closing a distinct hole:
#
#   1. The config selects a TEMPLATE, never a command string. It supplies a key
#      and one bounded argument; the command itself is fixed in this file. A
#      project cannot introduce a command the plugin does not already define.
#
#   2. The config is read from the MERGE BASE, not the working tree. Reviewing
#      a branch means that branch's content is the thing under suspicion — and
#      in --local mode it is already checked out before gates run. Reading the
#      working-tree config would let the branch under review define what
#      executes during its own review. This mirrors the pull_request /
#      pull_request_target split GitHub Actions draws for the same reason.
#
#   3. Approval is fingerprinted over the gate's DEFINITION, not merely over
#      the config that names it. A tuple-only fingerprint is defeated by
#      rewriting whatever the config points at while leaving the config line
#      byte-identical. The fingerprint therefore also folds in the content hash
#      of the file that defines each gate's command — the script for
#      bash_script, package.json for npm_script, composer.json for
#      composer_script, the makefile for make_target. Editing either half
#      re-asks for approval.
#
# Residual risk, stated rather than papered over, in two parts:
#
#   a. pytest, go_test and cargo_test have NO single defining file. They run a
#      fixed binary over repository code, and the code is spread across the
#      tree (plus conftest.py, tox/pytest/cargo config, build.rs, ...). There
#      is no honest file to hash, so nothing beyond the config tuple is folded
#      in for them, and a branch that edits the code those runners collect
#      changes what executes without changing the fingerprint. No stand-in is
#      invented here: a hash that covered part of the surface would read as
#      coverage it does not provide.
#
#   b. Even for the four templates above, the hash covers the definition, not
#      the transitive closure of what the definition invokes. `npm run test`
#      whose script body is unchanged still executes the test files; a makefile
#      recipe can `include` another makefile or shell out to a repo script.
#      Those all live in the branch under review. Running a gate means running
#      repository code. The controls make it explicit, approved, and re-asked
#      on change — they do not make it safe to review a repository you would
#      not otherwise run. That is why gates are opt-in and approved per project.
#
# Usage:
#   source /path/to/gate-runner.sh
#   gate_load_config <base_ref>            # -> TSV on stdout: name/template/args
#   gate_fingerprint <base_ref>            # -> sha256 over the gate definitions
#   gate_is_approved <base_ref>            # 0 = approved for this project
#   gate_record_approval <base_ref>
#   gate_run_all <base_ref>                # runs every gate, TSV results
#
# Exit codes from gate_run_all:
#   0 — every gate passed (or none configured)
#   1 — at least one gate failed
#   2 — configuration or approval error; nothing was executed

set -u

# Fixed template -> command. The ONLY commands this file will ever run.
# Adding an entry is a deliberate, reviewable widening of the execution
# surface; a project cannot add one.
_gate_template_argv() {
    local template="$1" arg="$2"
    case "$template" in
        npm_script)      printf '%s\n' npm run "$arg" ;;
        composer_script) printf '%s\n' composer run-script "$arg" ;;
        make_target)     printf '%s\n' make "$arg" ;;
        pytest)          printf '%s\n' pytest "$arg" ;;
        go_test)         printf '%s\n' go test "$arg" ;;
        cargo_test)      printf '%s\n' cargo test "$arg" ;;
        bash_script)     printf '%s\n' bash "$arg" ;;
        *) return 1 ;;
    esac
}

# Templates whose ARGUMENT is itself a repo-relative path that gets executed.
# Only these need the containment check in gate_run_all: the argument becomes
# the thing bash runs directly, so a path escaping the repository runs code the
# review never examined.
#
# For npm_script, composer_script and make_target the argument is a key looked
# up inside a file — a script name, a make target — never a path, so there is
# nothing to contain.
#
# pytest, go_test and cargo_test are the honest exception: `pytest <arg>` does
# take a path. It gets no containment check here, and the reason is not that it
# is safe but that containment would buy nothing. Those templates already run
# arbitrary repository code by design (residual risk (a) in the header), so a
# symlink steering collection elsewhere grants no capability the gate did not
# already have. `_gate_valid_arg` still rejects `..` and metacharacters. Stated
# rather than left implied, because a comment claiming these arguments are
# "never a path" would be false, and a false rationale is how the next person
# makes a wrong call about it.
_gate_template_arg_is_path() {
    case "$1" in
        bash_script) return 0 ;;
        *) return 1 ;;
    esac
}

# The file(s) whose CONTENT determines what a gate runs. Emitted as
# repo-relative paths, one per line, in a fixed order per template; every path
# listed contributes a fingerprint component whether or not it exists, so the
# result is stable and a file appearing or disappearing is itself a change.
#
#   bash_script      the argument names the script directly
#   npm_script       the command body lives in package.json's "scripts" map
#   composer_script  ... in composer.json's "scripts" map
#   make_target      ... in the makefile; GNU make's own search order is
#                    GNUmakefile, makefile, Makefile, and all three are listed
#                    so that adding a higher-precedence one is visible too
#
# pytest, go_test and cargo_test emit nothing on purpose. They invoke a fixed
# binary against repository code; no single file defines the command, and
# hashing an arbitrary stand-in (setup.cfg, go.mod, Cargo.toml) would imply a
# coverage that does not exist. See residual risk (a) in the header.
_gate_definition_files() {
    local template="$1" arg="$2"
    case "$template" in
        bash_script)     printf '%s\n' "$arg" ;;
        npm_script)      printf '%s\n' package.json ;;
        composer_script) printf '%s\n' composer.json ;;
        make_target)     printf '%s\n' GNUmakefile makefile Makefile ;;
        pytest|go_test|cargo_test) return 0 ;;
        *) return 1 ;;
    esac
}

# Argument validation: allowlist, not denylist.
#
# A denylist of metacharacters invites an omission. This permits only what the
# supported templates actually need — script names, make targets, paths — and
# rejects everything else, including whitespace. One argument per gate; a gate
# needing more belongs in a repo script the bash_script template can call.
_gate_valid_arg() {
    local arg="$1"
    [[ -n "$arg" ]] || return 1
    [[ "$arg" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || return 1
    # No parent traversal — bash_script must stay inside the repository.
    [[ "$arg" != *".."* ]] || return 1
    return 0
}

# Read pr_review.gates from the merge base rather than the working tree.
# Emits TSV: name<TAB>template<TAB>args. Silent success with no output when
# no gates are configured — that is the documented default, not an error.
gate_load_config() {
    local base_ref="${1-}"
    [[ -n "$base_ref" ]] || { echo "gate-runner: base ref required" >&2; return 2; }

    command -v yq >/dev/null 2>&1 || {
        echo "gate-runner: yq not available — cannot read gate configuration" >&2
        return 2
    }

    local mb
    mb=$(git merge-base HEAD "$base_ref" 2>/dev/null) || {
        echo "gate-runner: cannot resolve merge base with '$base_ref'" >&2
        return 2
    }

    local cfg
    # A repository with no config at the merge base simply has no gates.
    cfg=$(git show "${mb}:.claude/configuration.yml" 2>/dev/null) || return 0
    [[ -n "$cfg" ]] || return 0

    local count
    count=$(printf '%s' "$cfg" | yq -r '.pr_review.gates | length // 0' 2>/dev/null) || count=0
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$count" -gt 0 ]] || return 0

    printf '%s' "$cfg" | yq -r \
        '.pr_review.gates[] | [(.name // ""), (.template // ""), (.args // "")] | @tsv' 2>/dev/null
}

# Fingerprint over the gate set's definition: every (name, template, arg)
# tuple, plus the content hash of each file that defines what a gate runs.
gate_fingerprint() {
    local base_ref="${1-}"
    local root; root=$(git rev-parse --show-toplevel 2>/dev/null) || return 2

    local name template arg def acc=""
    while IFS=$'\t' read -r name template arg; do
        [[ -n "$template" ]] || continue
        acc+="${name}|${template}|${arg}"
        # This is control 3: rewriting package.json's script body, the makefile
        # recipe, or the referenced script changes the fingerprint even though
        # the config line is untouched, so approval is re-sought.
        #
        # An absent file contributes MISSING rather than being skipped. Skipping
        # would make "no package.json" and "package.json I have not read"
        # fingerprint alike, and creating the file later would then go unnoticed.
        while IFS= read -r def; do
            [[ -n "$def" ]] || continue
            local target="${root}/${def}" h="MISSING"
            if [[ -f "$target" ]]; then
                h=$(sha256sum "$target" 2>/dev/null | cut -d' ' -f1)
            fi
            acc+="|content:${def}:${h}"
        done < <(_gate_definition_files "$template" "$arg")
        acc+=$'\n'
    done < <(gate_load_config "$base_ref")

    printf '%s' "$acc" | sha256sum | cut -d' ' -f1
}

_gate_ledger_path() {
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=./report-path.sh
    source "${here}/report-path.sh"
    resolve_ledger_path
}

gate_is_approved() {
    local base_ref="${1-}"
    local fp ledger
    fp=$(gate_fingerprint "$base_ref") || return 2
    ledger=$(_gate_ledger_path) || return 2
    [[ -f "$ledger" ]] || return 1
    grep -qxF "$fp" "$ledger" 2>/dev/null
}

gate_record_approval() {
    local base_ref="${1-}"
    local fp ledger
    fp=$(gate_fingerprint "$base_ref") || return 2
    ledger=$(_gate_ledger_path) || return 2
    mkdir -p "$(dirname "$ledger")" || return 2
    printf '%s\n' "$fp" >> "$ledger"
}

# Human-readable description of what approval would authorise. Shown to the
# user at the confirmation prompt — approving an opaque hash is not consent.
gate_describe() {
    local base_ref="${1-}"
    local name template arg
    while IFS=$'\t' read -r name template arg; do
        [[ -n "$template" ]] || continue
        local -a argv=()
        if mapfile -t argv < <(_gate_template_argv "$template" "$arg") && [[ ${#argv[@]} -gt 0 ]]; then
            printf '  %s: %s\n' "${name:-unnamed}" "${argv[*]}"
        else
            printf '  %s: UNSUPPORTED TEMPLATE %s\n' "${name:-unnamed}" "$template"
        fi
    done < <(gate_load_config "$base_ref")
}

# Run every configured gate. Emits TSV: name<TAB>status<TAB>exit_code
# Never runs anything unless the resolved set is approved for this project.
gate_run_all() {
    local base_ref="${1-}"
    local root; root=$(git rev-parse --show-toplevel 2>/dev/null) || return 2

    local any=0
    while IFS=$'\t' read -r _n _t _a; do
        [[ -n "$_t" ]] && any=1
    done < <(gate_load_config "$base_ref")
    [[ "$any" -eq 1 ]] || { echo "gate-runner: no gates configured — deterministic phase skipped" >&2; return 0; }

    if ! gate_is_approved "$base_ref"; then
        echo "gate-runner: gate set is not approved for this project; nothing was executed" >&2
        return 2
    fi

    local failed=0 name template arg
    while IFS=$'\t' read -r name template arg; do
        [[ -n "$template" ]] || continue

        if ! _gate_valid_arg "$arg"; then
            printf '%s\tINVALID_ARG\t2\n' "${name:-unnamed}"
            failed=1
            continue
        fi

        local -a argv=()
        if ! mapfile -t argv < <(_gate_template_argv "$template" "$arg") || [[ ${#argv[@]} -eq 0 ]]; then
            printf '%s\tUNSUPPORTED_TEMPLATE\t2\n' "${name:-unnamed}"
            failed=1
            continue
        fi

        if _gate_template_arg_is_path "$template"; then
            # Resolve and confirm containment. A path escaping the repository
            # would run code the review never examined.
            local target="${root}/${arg}" real
            real=$(readlink -f "$target" 2>/dev/null || true)
            if [[ -z "$real" || "$real" != "$root"/* || ! -f "$real" ]]; then
                printf '%s\tSCRIPT_NOT_IN_REPO\t2\n' "${name:-unnamed}"
                failed=1
                continue
            fi
        fi

        # argv exec. Never `sh -c`, never a single interpolated string.
        #
        # The status is captured on the same line that produces it, into a
        # variable declared beforehand. `local rc=$?` on its own line would
        # read the status of `local` rather than of the command — the defect
        # CL-34 fixed in the test harness, and it is just as available here.
        local rc=0
        ( cd "$root" && "${argv[@]}" >/dev/null 2>&1 ) || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            printf '%s\tPASS\t0\n' "${name:-unnamed}"
        else
            printf '%s\tFAIL\t%s\n' "${name:-unnamed}" "$rc"
            failed=1
        fi
    done < <(gate_load_config "$base_ref")

    return "$failed"
}
