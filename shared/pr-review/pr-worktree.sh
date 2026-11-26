#!/bin/bash
# pr-worktree.sh
# The worktree /pr-review reviews a PR in when the launch checkout is not at
# the PR's head. Every decision, path, fetch, strip and cleanup lives here, so
# the skill's fences only call functions and print literals.
#
# Usage (one function per Bash call; nothing here depends on shell state
# surviving between calls):
#   source /path/to/pr-worktree.sh
#   prw_need_worktree <cur_branch> <headRefName> <isCrossRepository> <head_sha> <headRefOid>
#   prw_create_plain   <launch_root> <pr_number> <headRefOid> <owner/repo>
#   prw_create_autofix <launch_root> <pr_number> <headRefName> <headRefOid> <owner/repo> [strict]
#   prw_recreated      <worktree>     (auto-fix, before each commit)
#   prw_cleanup        <launch_root> <pr_number> <plain|autofix>
#
# Return codes: 0 done, 1 refused (reason on stderr), 2 usage error.
#
# Trust: the PR head is untrusted. Its branch name is validated before any git
# use, the worktree path depends only on the PR number, and before the session
# enters the tree every file Claude Code or this plugin would load as settings,
# memory or instructions is removed from it (prw_strip).

set -u

PRW_SUBDIR=".claude/worktrees"

_prw_err() { echo "pr-review: $*" >&2; }

# Printed back by the model as a literal and substituted single-quoted, so a
# quote or any control character (newline included) would change what it reads.
prw_check_launch_root() {
    local root="${1-}"
    [[ "$root" == /* && -d "$root" ]] || { _prw_err "launch root is not an absolute directory: $root"; return 1; }
    case "$root" in
        *"'"*|*[[:cntrl:]]*) _prw_err "launch root contains a quote or control character; not using a worktree"; return 1 ;;
    esac
    local top
    top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || top=""
    [[ "$top" == "$root" ]] || { _prw_err "launch root is not a checkout toplevel: $root"; return 1; }
}

# Same allowlist as the auto-fix base-branch check, plus `..`.
prw_validate_head_ref() {
    local name="${1-}"
    case "$name" in
        ''|-*|*..*|*[!A-Za-z0-9._/-]*) _prw_err "unexpected PR head branch name"; return 1 ;;
    esac
}

# unchanged only when the launch checkout already IS the PR head: same branch
# name, same commit, same repository. A same-name branch behind or ahead of the
# PR, a detached HEAD, or a fork PR all need a worktree.
prw_need_worktree() {
    local cur="${1-}" head="${2-}" cross="${3-}" sha="${4-}" oid="${5-}"
    if [[ -n "$cur" && "$cur" == "$head" && "$cross" == "false" && -n "$sha" && "$sha" == "$oid" ]]; then
        echo unchanged
    else
        echo worktree
    fi
}

prw_path() {
    local root="${1-}" n="${2-}"
    [[ "$n" =~ ^[0-9]+$ ]] || { _prw_err "PR number must be numeric"; return 2; }
    printf '%s/%s/pr-review-%s\n' "$root" "$PRW_SUBDIR" "$n"
}

# The worktree must be invisible to the launch checkout's `git status`. If its
# parent is not ignored and has no .gitignore, write one that ignores
# everything including itself; if that still does not do it, refuse.
prw_ensure_ignored() {
    local root="${1-}" path="${2-}"
    git -C "$root" check-ignore -q "$path" 2>/dev/null && return 0
    local gi="$root/$PRW_SUBDIR/.gitignore"
    if [[ ! -e "$gi" && ! -L "$gi" ]]; then
        if ! { mkdir -p "$root/$PRW_SUBDIR" && printf '*\n' > "$gi"; }; then
            _prw_err "cannot write $gi"; return 1
        fi
    fi
    git -C "$root" check-ignore -q "$path" 2>/dev/null && return 0
    _prw_err "$path would show in git status here; not creating a worktree"
    return 1
}

# Literal comparison of normalised URLs, never a regex: `evilgithub.com/...`
# and `<repo>-fork` must not match. GitHub names are case-insensitive.
prw_remote_for() {
    local root="${1-}" repo="${2-}"
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { _prw_err "unexpected repository name"; return 2; }
    local want r url
    want=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        # The URL as configured, before any insteadOf rewrite.
        url=$(git -C "$root" config --get "remote.$r.url" 2>/dev/null) || continue
        url=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
        url="${url%/}"; url="${url%.git}"
        # https://<user>@github.com/... (userinfo with no / in it) is the same remote.
        [[ "$url" =~ ^https://[^/@]+@github\.com/(.*)$ ]] && url="https://github.com/${BASH_REMATCH[1]}"
        case "$url" in
            "https://github.com/$want"|"git@github.com:$want"|"ssh://git@github.com/$want")
                printf '%s\n' "$r"; return 0 ;;
        esac
    done < <(git -C "$root" remote 2>/dev/null)
    _prw_err "no git remote points at github.com/$repo"
    return 1
}

# Could a tracked symlink lead outside the worktree? Any absolute target, and
# any target with a `..` component, counts — without resolving it. Resolving
# by text is unsound: chained in-tree links (`d -> .`, `e -> d/..`) climb out
# while each looks harmless alone. A link that only ever points downward cannot
# leave the tree however it is chained. Stripping a few safe `../x` links costs
# nothing: reviewers still see them in the diff.
_prw_link_escapes() {
    local wt="${1-}" rel="${2-}" target
    target=$(readlink -- "$wt/$rel" 2>/dev/null) || return 0
    case "$target" in
        /*|..|../*|*/..|*/../*) return 0 ;;
    esac
    return 1
}

# Lowercased path in a strip class? $(1) lowercased path, $(2) plain|autofix.
_prw_strip_class() {
    local lc="${1-}" mode="${2-}" base="${1##*/}"
    if [[ "$mode" == plain ]]; then
        case "/$lc/" in */.claude/*) return 0 ;; esac
        case "$base" in claude.md|claude.local.md|.mcp.json) return 0 ;; esac
        return 1
    fi
    case "/$lc/" in */.claude/*) return 0 ;; esac
    return 1
}

# Checked on the commit BEFORE anything is checked out, so a tree that is
# refused is never written to disk. Refuses: a newline in any path; two paths
# that differ only by case where one is in a strip class (a case-insensitive
# filesystem would load the unstripped twin); and, in auto-fix, a tracked
# `.claude` symlink, which would put a file the strip cannot see where the
# plugin reads its settings.
prw_check_tree() {
    local root="${1-}" oid="${2-}" mode="${3-}" entry p lc lcs="" dup
    git -C "$root" cat-file -e "${oid}^{tree}" 2>/dev/null || { _prw_err "cannot read commit $oid"; return 1; }
    while IFS= read -r -d '' entry; do
        p="${entry#*$'\t'}"
        [[ "$p" != *$'\n'* ]] || { _prw_err "a tracked path contains a newline; not using a worktree"; return 1; }
        lc=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
        lcs+="$lc"$'\n'
        if [[ "$mode" == autofix && "${entry%% *}" == 120000 ]]; then
            case "/$lc" in */.claude) _prw_err "the PR tracks .claude as a symlink; not using a worktree"; return 1 ;; esac
        fi
    done < <(git -C "$root" ls-tree -r -z --full-tree "$oid" 2>/dev/null)
    # bash 3.2 (macOS) has no associative arrays, so duplicates come from sort.
    while IFS= read -r dup; do
        [[ -n "$dup" ]] || continue
        if _prw_strip_class "$dup" plain || _prw_strip_class "$dup" "$mode"; then
            _prw_err "two tracked paths differ only by letter case ($dup); not using a worktree"
            return 1
        fi
    done < <(printf '%s' "$lcs" | sort | uniq -d)
}

# Remove, from the worktree only, every tracked file of a class Claude Code or
# this plugin loads as settings, memory or instructions. Names match ignoring
# case (macOS and Windows check out `CLAUDE.MD` as the real file). Each removed
# path is marked skip-worktree in the worktree's own index, so `git status`
# stays clean and `git add -u` never stages the deletion.
#   plain:   memory files, anything under a `.claude` component, `.mcp.json`,
#            and symlinks that point outside the worktree
#   autofix: `.claude/configuration.yml` only (the user's own PR)
prw_strip() {
    local wt="${1-}" mode="${2-}"
    [[ "$mode" == plain || "$mode" == autofix ]] || { _prw_err "prw_strip: unknown mode $mode"; return 2; }
    [[ -d "$wt" ]] || { _prw_err "prw_strip: no worktree at $wt"; return 2; }
    # Canonical, so the escaping-symlink check compares like with like.
    wt=$(cd "$wt" && pwd -P) || return 2

    local nl list
    nl=$(git -C "$wt" ls-files -z 2>/dev/null | tr -cd '\n' | wc -c) || { _prw_err "cannot list $wt"; return 1; }
    # A newline in a tracked path would split it below and could slip a file
    # past the match; such a tree is refused rather than parsed.
    [[ "$nl" -eq 0 ]] || { _prw_err "a tracked path contains a newline; not using a worktree"; return 1; }
    list=$(git -C "$wt" ls-files -s -z 2>/dev/null | tr '\0' '\n') || { _prw_err "cannot list $wt"; return 1; }

    # shortcut: case folding only, not Unicode NFC/NFD or HFS+ ignorable code
    # points; upgrade if a PR ever exploits a normalisation-only collision.

    local meta rel lc fmode n=0
    while IFS=$'\t' read -r meta rel; do
        [[ -n "$rel" ]] || continue
        fmode="${meta%% *}"
        lc=$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')
        local strip=false
        if [[ "$mode" == plain ]]; then
            _prw_strip_class "$lc" plain && strip=true
            if [[ "$strip" == false && "$fmode" == 120000 ]] && _prw_link_escapes "$wt" "$rel"; then
                strip=true
            fi
        else
            case "/$lc" in */.claude/configuration.yml) strip=true ;; esac
        fi
        [[ "$strip" == true ]] || continue
        rm -f -- "$wt/$rel" || { _prw_err "cannot remove $rel"; return 1; }
        git -C "$wt" update-index --skip-worktree -- "$rel" || { _prw_err "cannot mark $rel"; return 1; }
        n=$((n + 1))
    done <<< "$list"
    echo "stripped $n file(s)"
}

# Hooks write under .claude/session-state/; keep that out of `git status` so
# the auto-fix clean-tree check and the cleanup check see only real work.
_prw_self_ignore_state() {
    local wt="${1-}" d="$1/.claude/session-state"
    # Never write through a link: it would land outside the tree.
    [[ ! -L "$wt/.claude" && ! -L "$d" && ! -L "$d/.gitignore" ]] || { _prw_err "session-state path is a symlink"; return 1; }
    # On disk, not in the index: a PR-tracked copy the strip removed is still indexed.
    [[ -f "$d/.gitignore" ]] && return 0
    mkdir -p "$d" && printf '*\n' > "$d/.gitignore"
}

# Hooks and LFS smudge off: checkout must not run anything or contact any URL
# the PR chose. The strip has not run yet at this point.
_prw_worktree_add() {
    local root="${1-}"; shift
    GIT_LFS_SKIP_SMUDGE=1 git -C "$root" -c core.hooksPath=/dev/null worktree add -q "$@"
}

_prw_check_common() {
    local root="${1-}" n="${2-}" oid="${3-}"
    prw_check_launch_root "$root" || return 1
    [[ "$n" =~ ^[0-9]+$ ]] || { _prw_err "PR number must be numeric"; return 2; }
    [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || { _prw_err "unexpected head commit id"; return 2; }
}

# Plain review: a detached worktree at the PR head, fetched by its numeric pull
# ref (works for forks; the branch name is never used). Prints the path.
prw_create_plain() {
    local root="${1-}" n="${2-}" oid="${3-}" repo="${4-}"
    _prw_check_common "$root" "$n" "$oid" || return $?
    local remote path got
    remote=$(prw_remote_for "$root" "$repo") || return 1
    path=$(prw_path "$root" "$n") || return 2
    [[ ! -e "$path" ]] || { _prw_err "$path already exists; remove it with: git worktree remove $path"; return 1; }
    prw_ensure_ignored "$root" "$path" || return 1
    git -C "$root" fetch -q "$remote" "refs/pull/$n/head" || { _prw_err "could not fetch PR #$n from $remote"; return 1; }
    got=$(git -C "$root" rev-parse FETCH_HEAD 2>/dev/null) || got=""
    [[ "$got" == "$oid" ]] || { _prw_err "fetched commit $got is not the PR head $oid"; return 1; }
    prw_check_tree "$root" "$oid" plain || return 1
    _prw_worktree_add "$root" --detach "$path" "$oid" || { _prw_err "git worktree add failed"; return 1; }
    prw_strip "$path" plain >&2 || { _prw_err "strip failed; the worktree at $path was NOT entered and is kept"; return 1; }
    _prw_self_ignore_state "$path" || { _prw_err "the worktree at $path was NOT entered and is kept"; return 1; }
    printf '%s\n' "$path"
}

# Auto-fix: a worktree on a local branch named after the PR head, so fixes can
# be committed and pushed from it. Only through origin, which the push uses.
prw_create_autofix() {
    local root="${1-}" n="${2-}" name="${3-}" oid="${4-}" repo="${5-}" strict="${6-}"
    local smode=autofix
    # strict: commits by someone else are on the branch, so strip what plain
    # review strips — their instruction files must not load either.
    [[ "$strict" == strict ]] && smode=plain
    _prw_check_common "$root" "$n" "$oid" || return $?
    prw_validate_head_ref "$name" || return 1
    local remote path got held local_sha
    remote=$(prw_remote_for "$root" "$repo") || return 1
    [[ "$remote" == origin ]] || { _prw_err "the remote for $repo is '$remote', not origin; auto-fix pushes only to origin"; return 1; }
    path=$(prw_path "$root" "$n") || return 2
    [[ ! -e "$path" ]] || { _prw_err "$path already exists; remove it with: git worktree remove $path"; return 1; }
    held=$(git -C "$root" worktree list --porcelain 2>/dev/null \
        | awk -v b="branch refs/heads/$name" '/^worktree /{w=substr($(0),10)} $(0)==b{print w; exit}')
    [[ -z "$held" ]] || { _prw_err "branch $name is already checked out at $held; finish or push there first"; return 1; }
    local_sha=$(git -C "$root" rev-parse -q --verify "refs/heads/$name" 2>/dev/null) || local_sha=""
    if [[ -n "$local_sha" && "$local_sha" != "$oid" ]]; then
        _prw_err "local branch $name is at $local_sha, not the PR head $oid; update or remove it first"
        return 1
    fi
    prw_ensure_ignored "$root" "$path" || return 1
    # refs/heads/ explicitly: a bare name would fetch a same-name tag first.
    git -C "$root" fetch -q origin "refs/heads/$name" || { _prw_err "could not fetch $name from origin"; return 1; }
    got=$(git -C "$root" rev-parse FETCH_HEAD 2>/dev/null) || got=""
    [[ "$got" == "$oid" ]] || { _prw_err "fetched commit $got is not the PR head $oid"; return 1; }
    prw_check_tree "$root" "$oid" autofix || return 1
    if [[ -n "$local_sha" ]]; then
        _prw_worktree_add "$root" "$path" "$name" || { _prw_err "git worktree add failed"; return 1; }
    else
        _prw_worktree_add "$root" -b "$name" "$path" "$oid" || { _prw_err "git worktree add failed"; return 1; }
    fi
    prw_strip "$path" "$smode" >&2 || { _prw_err "strip failed; the worktree at $path was NOT entered and is kept"; return 1; }
    _prw_self_ignore_state "$path" || { _prw_err "the worktree at $path was NOT entered and is kept"; return 1; }
    printf '%s\n' "$path"
}

# clean | dirty:<reason> | unknown. Unknown never counts as clean.
prw_cleanup_state() {
    local wt="${1-}" mode="${2-}" name out count
    out=$(git -C "$wt" status --porcelain 2>/dev/null) || { echo unknown; return 0; }
    [[ -z "$out" ]] || { echo "dirty:uncommitted changes"; return 0; }
    if [[ "$mode" == autofix ]]; then
        # The worktree's own branch; no need to ask GitHub.
        name=$(git -C "$wt" branch --show-current 2>/dev/null) || name=""
        prw_validate_head_ref "$name" 2>/dev/null || { echo unknown; return 0; }
        git -C "$wt" fetch -q origin "refs/heads/$name" 2>/dev/null || { echo unknown; return 0; }
        # FETCH_HEAD, not origin/<name>: a single-branch clone never updates that.
        count=$(git -C "$wt" rev-list --count "FETCH_HEAD..HEAD" 2>/dev/null) || { echo unknown; return 0; }
        [[ "$count" == 0 ]] || { echo "dirty:$count unpushed commit(s)"; return 0; }
    fi
    echo clean
}

# Remove the worktree this run created when nothing in it can be lost;
# otherwise keep it and say why. Never forced. Run after ExitWorktree.
prw_cleanup() {
    local root="${1-}" n="${2-}" mode="${3-}" path state
    prw_check_launch_root "$root" || return 1
    path=$(prw_path "$root" "$n") || return 2
    [[ -d "$path" ]] || { echo "no worktree at $path"; return 0; }
    case "$PWD/" in "$path/"*) _prw_err "still inside $path; run ExitWorktree first"; return 1 ;; esac
    state=$(prw_cleanup_state "$path" "$mode")
    if [[ "$state" == clean ]]; then
        git -C "$root" worktree remove "$path" && { echo "removed worktree $path"; return 0; }
        state="unknown (git worktree remove refused)"
    fi
    echo "kept worktree $path — ${state#dirty:}"
    echo "remove it when done: git worktree remove $path"
}

# Auto-fix, before each commit: a stripped (skip-worktree) path that exists on
# disk again. Git ignores changes to it, so `git status` cannot show it, and a
# recreated .claude/configuration.yml would change the plugin's settings.
prw_recreated() {
    local wt="${1-}" e p found=1
    while IFS= read -r -d '' e; do
        [[ "$e" == "S "* ]] || continue
        p="${e#S }"
        # The helper's own self-ignore file, rewritten on purpose after a strip.
        [[ "$p" == .claude/session-state/.gitignore ]] && continue
        if [[ -e "$wt/$p" || -L "$wt/$p" ]]; then echo "RECREATED: $p"; found=0; fi
    done < <(git -C "$wt" ls-files -v -z 2>/dev/null)
    return $found
}
