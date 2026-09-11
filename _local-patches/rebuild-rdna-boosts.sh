#!/usr/bin/env bash
#
# rebuild-rdna-boosts.sh
#
# Manage the `rdna-boosts` branch of the local llama.cpp clone:
#
#   ./rebuild-rdna-boosts.sh               rebuild branch on latest master (default)
#   ./rebuild-rdna-boosts.sh rebuild --base <rev>
#                                        rebuild on a specific llama.cpp revision
#                                        instead of origin/master, e.g.
#                                        rebuild --base 67a17c17c
#   ./rebuild-rdna-boosts.sh push          push branch (force-with-lease) — tags NOT pushed
#   ./rebuild-rdna-boosts.sh push-tags     push all local backup tags to origin (explicit)
#   ./rebuild-rdna-boosts.sh tags          list backup tags (with tag message)
#   ./rebuild-rdna-boosts.sh untag [-r] T  delete backup tag(s) locally, or -r from origin
#   ./rebuild-rdna-boosts.sh restore TAG   roll the branch back to a backup tag
#
# Layout (all paths are derived from this script's location, so the whole
# tree can live anywhere):
#
#   <root>/llama.cpp                                  — llama.cpp clone (branch `rdna-boosts`)
#   <root>/llama-cpp-rdna-boosts/                     — patch source (fork of stew675/llama-cpp-rdna-boosts)
#   <root>/llama-cpp-rdna-boosts/patches/             — the delivery patches (0001..NNNN)
#   <root>/llama-cpp-rdna-boosts/_local-patches/      — this script + local fix patches
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../llama-cpp-rdna-boosts/_local-patches
BOOSTS="$(dirname "$SCRIPT_DIR")"                            # .../llama-cpp-rdna-boosts
LOCAL_PATCHES="$SCRIPT_DIR"
LLAMA="$(dirname "$BOOSTS")/llama.cpp"                       # .../llama.cpp

[ -d "$LLAMA/.git" ]    || { echo "ERROR: no llama.cpp clone at $LLAMA" >&2; exit 1; }
[ -d "$BOOSTS/.git" ]   || { echo "ERROR: no llama-cpp-rdna-boosts clone at $BOOSTS" >&2; exit 1; }
[ -d "$BOOSTS/patches" ] || { echo "ERROR: no patches/ dir in $BOOSTS" >&2; exit 1; }

cmd="${1:-rebuild}"

# best-effort: .gitconfig may be read-only (bind mount) in some environments;
# git will still fail loudly later with "dubious ownership" if it's actually needed
git config --global --add safe.directory "$LLAMA" 2>/dev/null || true
git config --global --add safe.directory "$BOOSTS" 2>/dev/null || true

case "$cmd" in

rebuild)
    # optional: rebuild --base <rev>  (default: origin/master)
    if [ "${1:-}" = "rebuild" ]; then shift; fi
    BASE_REF="origin/master"
    while [ $# -gt 0 ]; do
        case "$1" in
            --base) BASE_REF="${2:?usage: rebuild --base <revision>}"; shift ;;
            *) echo "ERROR: unknown option for rebuild: $1" >&2; exit 1 ;;
        esac
        shift
    done

    # refuse to run with a dirty llama.cpp tree — reset --hard would discard local changes
    if [ -n "$(git -C "$LLAMA" status --porcelain)" ]; then
        echo "ERROR: $LLAMA working tree is dirty — commit or stash first" >&2
        git -C "$LLAMA" status --short
        exit 1
    fi

    # 1) note which patch set we're building from.
    #    The local clone is read as-is (this script only reads from it, never
    #    rewrites it). To pick up new upstream patches, do it explicitly:
    #      git -C "$BOOSTS" fetch upstream && git -C "$BOOSTS" merge upstream/main
    BOOSTS_SHA=$(git -C "$BOOSTS" rev-parse --short HEAD)
    echo "==> patch source: $(basename "$BOOSTS") @ $BOOSTS_SHA"
    git -C "$BOOSTS" log --oneline -1

    # collect the delivery patch set (glob is lex-sorted = numeric for 4-digit prefixes)
    PATCH_FILES=( "$BOOSTS"/patches/*.patch )
    N_PATCH=${#PATCH_FILES[@]}
    LAST_PATCH=$(basename "${PATCH_FILES[-1]}" | cut -c1-4)

    # 2) pull the latest llama.cpp master
    git -C "$LLAMA" fetch origin

    # 2b) resolve the requested base revision (after fetch, so a short SHA from
    #     a just-landed commit also resolves)
    BASE_SHA=$(git -C "$LLAMA" rev-parse --verify "$BASE_REF^{commit}" 2>/dev/null) \
        || { echo "ERROR: '$BASE_REF' does not resolve to a commit in $LLAMA" >&2; exit 1; }
    BASE_SHORT=$(git -C "$LLAMA" rev-parse --short "$BASE_SHA")
    echo "==> base revision: $BASE_SHORT ($BASE_REF)"

    # 3) annotated safety tag of the current branch tip, with full build context.
    #    The subject line carries the short SHAs so 'git tag -l' / '$0 tags'
    #    one-liners stay informative (lightweight tags used to show the commit
    #    subject here; annotated tags show THIS message instead).
    PREV_TIP=$(git -C "$LLAMA" rev-parse rdna-boosts)
    PREV_SHORT=$(git -C "$LLAMA" rev-parse --short "$PREV_TIP")
    TAG="backup/rdna-boosts-$(date +%Y%m%d-%H%M%S)"
    git -C "$LLAMA" tag -a "$TAG" rdna-boosts -m "backup of rdna-boosts@${PREV_SHORT} before rebuild on ${BASE_SHORT} (${BASE_REF}), ${N_PATCH} patches 0001-${LAST_PATCH} (boosts@${BOOSTS_SHA})

rdna-boosts tip : $PREV_TIP
llama.cpp base  : $BASE_SHA ($BASE_REF)
boosts source   : $BOOSTS_SHA (llama-cpp-rdna-boosts)
patches         : $N_PATCH files, 0001..${LAST_PATCH}"
    echo "==> tagged $TAG"

    # 4) rebuild the branch on top of the base revision
    git -C "$LLAMA" checkout rdna-boosts
    git -C "$LLAMA" reset --hard "$BASE_SHA"

    # 5) apply all delivery patches via 'git am' (one commit per block).
    #    Why git am (not the old plain 'git apply' + --3way loop): 'git am'
    #    commits after each block, so the index is always in sync with the
    #    worktree. That is exactly what 'git apply --3way' demands (check_index
    #    -> check_preimage -> verify_index_match); the old loop dirtied the
    #    worktree with earlier blocks while the index stayed at the base, so
    #    every later-block file an earlier block had touched was rejected with
    #    "does not match index". git am makes that failure impossible.
    #    Strict first: on the recorded baseline the tree == the canonical fork
    #    tip, so this is exact. On a drifted base the strict pass fails, we
    #    abort, and retry the whole series with 'git am -3' (3-way merge
    #    against the blob ids recorded in the format-patch output).
    cd "$LLAMA"
    echo "==> git am: applying ${N_PATCH} delivery patches (0001-${LAST_PATCH})"
    if ! git am "${PATCH_FILES[@]}"; then
        echo "    strict 'git am' failed at this base; aborting + retrying with 'git am -3'"
        git am --abort >/dev/null 2>&1 || true
        if ! git am -3 "${PATCH_FILES[@]}"; then
            echo "PATCH FAILED (git am -3); last applied: $(git -C "$LLAMA" log --oneline -1)"
            echo "  A block needs manual resolution; the series is PAUSED. To continue:"
            echo "    inspect : git status && git diff"
            echo "    fix + go: git add <file> && git am --continue"
            echo "    skip it : git am --skip"
            echo "    abort   : git am --abort      (leaves rdna-boosts at $BASE_SHORT)"
            exit 1
        fi
    fi

    # NOTE: 27825.patch is gone from patches/ - it was superseded by
    # 12-hybrid-allreduce-hip.patch (dedicated allreduce-hip.cu for ROCm).

    # 5b) local fix patches (survive rebuilds; one commit each; skipped when the
    #     fix is already folded into the delivery set). The tree is clean after
    #     'git am', so the --3way fallback here never hits the dirty-index check
    #     that plagued the old delivery loop. Each local patch is committed so
    #     the tree stays clean for the next one. Works on plain 'git diff'
    #     patches (the usual local-fix form) as well as format-patch.
    local_n=0
    for p in $(ls "$LOCAL_PATCHES"/*.patch 2>/dev/null | sort); do
        if git apply --check --reverse "$p" 2>/dev/null; then
            echo "skipping (already applied): $(basename "$p")"
            continue
        fi
        echo "==> local patch: $(basename "$p")"
        if ! git apply "$p" 2>/dev/null; then
            echo "    (context drifted, trying 3-way merge)"
            if ! git apply --3way "$p"; then
                echo "LOCAL PATCH FAILED: $p"
                echo "  the tree is clean-safe; fix the conflicted file, then:"
                echo "    git add -A && git commit -m 'local patch: <name>'"
                echo "  or revert this one patch: git apply -R --3way $p"
                exit 1
            fi
        fi
        git add -A
        git commit -q -m "local patch: $(basename "$p")"
        local_n=$((local_n + 1))
    done
    if [ "$local_n" -eq 0 ]; then echo "no local patches to apply"; fi

    # 6) result: base + N delivery commits (+ any local commits), no squash.
    echo
    echo "==> rebuilt rdna-boosts: $BASE_SHORT + ${N_PATCH} delivery + ${local_n} local commit(s)"
    git -C "$LLAMA" log --oneline -$((N_PATCH + local_n + 1))
    git -C "$LLAMA" status --short   # must print nothing
    echo
    echo "Done. When ready:  $0 push"
    ;;

push)
    # the rebuild rewrites history -> force-with-lease (safe force)
    # NOTE: tags are intentionally NOT pushed here — use 'push-tags' explicitly,
    # otherwise deleted remote tags would silently come back.
    git -C "$LLAMA" push --force-with-lease origin rdna-boosts
    ;;

push-tags)
    tags=$(git -C "$LLAMA" tag -l 'backup/rdna-boosts-*')
    if [ -z "$tags" ]; then
        echo "no local backup tags to push"
    else
        echo "==> pushing $(echo "$tags" | wc -l) backup tag(s) to origin"
        # shellcheck disable=SC2086
        git -C "$LLAMA" push origin $tags
    fi
    ;;

tags)
    git -C "$LLAMA" for-each-ref 'refs/tags/backup/rdna-boosts-*' --sort=-creatordate \
        --format='%(creatordate:short)  %(refname:short)  %(contents:subject)'
    ;;

untag)
    shift
    remote=0
    if [ "${1:-}" = "-r" ]; then remote=1; shift; fi
    if [ $# -lt 1 ]; then
        echo "usage: $0 untag [-r] <tag> [tag...]   (list with: $0 tags)" >&2
        exit 1
    fi
    for t in "$@"; do
        case "$t" in
            backup/rdna-boosts-*) ;;
            *) echo "ERROR: refusing to delete non-backup tag: $t" >&2; exit 1 ;;
        esac
        if [ "$remote" = 1 ]; then
            git -C "$LLAMA" push origin ":refs/tags/$t"
            echo "deleted from origin: $t"
        else
            git -C "$LLAMA" tag -d "$t"
        fi
    done
    ;;

restore)
    tag="${2:?usage: $0 restore <backup-tag>   (list with: $0 tags)}"
    git -C "$LLAMA" rev-parse --verify "refs/tags/$tag" >/dev/null \
        || { echo "ERROR: no such tag: $tag" >&2; exit 1; }
    if [ -n "$(git -C "$LLAMA" status --porcelain)" ]; then
        echo "ERROR: working tree is dirty — commit or stash first (reset --hard would discard it)" >&2
        exit 1
    fi
    git -C "$LLAMA" checkout rdna-boosts
    git -C "$LLAMA" reset --hard "$tag"
    echo "rdna-boosts now at: $(git -C "$LLAMA" log --oneline -1)"
    echo "To publish the rollback:  $0 push"
    ;;

*)
    echo "usage: $0 [rebuild [--base <rev>] | push | push-tags | tags | untag [-r] <tag>... | restore <tag>]" >&2
    exit 1
    ;;
esac
