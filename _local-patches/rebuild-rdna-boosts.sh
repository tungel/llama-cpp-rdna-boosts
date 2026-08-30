#!/usr/bin/env bash
#
# rebuild-rdna-boosts.sh
#
# Manage the `rdna-boosts` branch of the local llama.cpp clone:
#
#   ./rebuild-rdna-boosts.sh               rebuild branch on latest master (default)
#   ./rebuild-rdna-boosts.sh push          push branch (force-with-lease) + backup tags
#   ./rebuild-rdna-boosts.sh tags          list backup tags
#   ./rebuild-rdna-boosts.sh restore TAG   roll the branch back to a backup tag
#
# Layout (all paths are derived from this script's location, so the whole
# tree can live anywhere):
#
#   <root>/llama.cpp                                  — llama.cpp clone (branch `rdna-boosts`)
#   <root>/llama-cpp-rdna-boosts/                     — patch source (fork of stew675/llama-cpp-rdna-boosts)
#   <root>/llama-cpp-rdna-boosts/patches/             — the 12 delivery patches
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

git config --global --add safe.directory "$LLAMA"
git config --global --add safe.directory "$BOOSTS"

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

    # 2) pull the latest llama.cpp master
    git -C "$LLAMA" fetch origin

    # 3) safety tag of the current branch tip
    git -C "$LLAMA" tag "backup/rdna-boosts-$(date +%Y%m%d-%H%M%S)" rdna-boosts

    # 4) rebuild the branch on top of the latest master
    git -C "$LLAMA" checkout rdna-boosts
    git -C "$LLAMA" reset --hard origin/master

    # 5) apply all patches in order (0001..0011 then 12-... — lex sort is correct)
    cd "$LLAMA"
    for p in $(ls "$BOOSTS"/patches/*.patch | sort); do
        echo "==> $(basename "$p")"
        git apply --3way "$p" || { echo "PATCH FAILED: $p"; exit 1; }
    done

    # NOTE: 27825.patch is intentionally NOT applied — it is superseded by
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
    git -C "$LLAMA" commit -m "rdna-boosts: rebuild on $(git rev-parse --short origin/master) + patches 0001-0012 (boosts@$BOOSTS_SHA)"

    git -C "$LLAMA" log --oneline -2
    git -C "$LLAMA" status --short   # must print nothing
    echo
    echo "Done. When ready:  $0 push"
    ;;

push)
    # the rebuild rewrites history -> force-with-lease (safe force)
    git -C "$LLAMA" push --force-with-lease origin rdna-boosts

    # backup tags are local-only by default; push them too
    tags=$(git -C "$LLAMA" tag -l 'backup/rdna-boosts-*')
    if [ -n "$tags" ]; then
        # shellcheck disable=SC2086
        git -C "$LLAMA" push origin $tags
    fi
    ;;

tags)
    git -C "$LLAMA" tag -l 'backup/rdna-boosts-*' --sort=-creatordate
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
    echo "usage: $0 [rebuild | push | tags | restore <tag>]" >&2
    exit 1
    ;;
esac
