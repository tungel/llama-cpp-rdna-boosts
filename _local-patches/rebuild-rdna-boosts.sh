#!/usr/bin/env bash
#
# rebuild-rdna-boosts.sh
#
# Manage the `rdna-boosts` branch of the local llama.cpp clone:
#
#   ./rebuild-rdna-boosts.sh               rebuild branch on latest master (default)
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

    # 3) annotated safety tag of the current branch tip, with full build context
    PREV_TIP=$(git -C "$LLAMA" rev-parse rdna-boosts)
    MASTER_SHA=$(git -C "$LLAMA" rev-parse origin/master)
    TAG="backup/rdna-boosts-$(date +%Y%m%d-%H%M%S)"
    git -C "$LLAMA" tag -a "$TAG" rdna-boosts -m "backup of rdna-boosts before rebuild

rdna-boosts tip : $PREV_TIP
llama.cpp master: $MASTER_SHA (origin/master)
boosts source   : $BOOSTS_SHA (llama-cpp-rdna-boosts)
patches         : $N_PATCH files, 0001..${LAST_PATCH}"
    echo "==> tagged $TAG"

    # 4) rebuild the branch on top of the latest master
    git -C "$LLAMA" checkout rdna-boosts
    git -C "$LLAMA" reset --hard origin/master

    # 5) apply all delivery patches in order (lex sort = numeric order)
    cd "$LLAMA"
    for p in "${PATCH_FILES[@]}"; do
        echo "==> $(basename "$p")"
        git apply --3way "$p" || { echo "PATCH FAILED: $p"; exit 1; }
    done

    # NOTE: 27825.patch is gone from patches/ — it was superseded by
    # 12-hybrid-allreduce-hip.patch (dedicated allreduce-hip.cu for ROCm).

    # 5b) local fix patches (survive rebuilds; skipped if already fixed upstream)
    for p in $(ls "$LOCAL_PATCHES"/*.patch 2>/dev/null | sort); do
        if git apply --check --reverse "$p" 2>/dev/null; then
            echo "skipping (already applied): $(basename "$p")"
        else
            echo "==> $(basename "$p")"
            git apply --3way "$p" || { echo "PATCH FAILED: $p"; exit 1; }
        fi
    done

    # 6) one new commit with everything
    git -C "$LLAMA" add -A
    git -C "$LLAMA" commit -m "rdna-boosts: rebuild on $(git rev-parse --short origin/master) + patches 0001-${LAST_PATCH} x${N_PATCH} (boosts@$BOOSTS_SHA)"

    git -C "$LLAMA" log --oneline -2
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
    echo "usage: $0 [rebuild | push | push-tags | tags | untag [-r] <tag>... | restore <tag>]" >&2
    exit 1
    ;;
esac
