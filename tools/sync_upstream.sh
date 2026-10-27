#!/bin/bash
# Upstream sync for the "snapshot + change replay" layout.
#
# This repository ships a full source tree under src/ instead of being a git
# fork, so the official history is not an ancestor and a plain merge would
# flag every file as conflicting. Instead we snapshot upstream and replay our
# change set (8 files) on top of it.
#
#   fetch   download official main into .cache/upstream-new, record its commit
#   check   report what upstream changed and whether it collides with our files
#   rebase  rebuild src/ from the new snapshot, re-applying our files
#
# Usage: bash tools/sync_upstream.sh fetch|check|rebase
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/src"
CACHE="$ROOT/.cache"
NEW="$CACHE/upstream-new"     # snapshot of the version we are moving to
PREV="$CACHE/upstream-prev"   # snapshot of the version we came from
BAK="$CACHE/src-backup"
SHA_FILE="$ROOT/UPSTREAM_COMMIT"
URL=${UPSTREAM_URL:-https://github.com/mgrone/stream1090.git}

# Files this project modifies; keep in sync with patches/0001-*.patch
OURS="
include/BlockRing.hpp
include/DemodCore.hpp
include/Global.hpp
include/InputReaderBase.hpp
include/SampleStream.hpp
include/Sampler.hpp
include/ShiftRegisters.hpp
presets/BenchPresets.hpp
"

fetch() {
    mkdir -p "$CACHE"
    # keep the previous snapshot so `check` can tell upstream changes apart
    # from our own edits
    rm -rf "$PREV"
    [ -d "$NEW" ] && mv "$NEW" "$PREV"
    rm -rf "$NEW"
    echo "== cloning $URL (depth 1)"
    git clone --depth 1 -q "$URL" "$NEW"
    SHA=$(git -C "$NEW" rev-parse HEAD)
    rm -rf "$NEW/.git"
    echo "$SHA" > "$SHA_FILE"
    echo "== snapshot: $SHA"
}

# upstream touched this file? (no previous snapshot -> unknown, treat as changed)
upstream_changed() {
    local f=$1
    [ -e "$PREV/$f" ] || return 0
    ! diff -q "$PREV/$f" "$NEW/$f" >/dev/null 2>&1
}

check() {
    [ -d "$NEW" ] || { echo "run 'fetch' first"; exit 1; }
    echo "== upstream files that differ from our tree"
    diff -rq "$SRC" "$NEW" 2>/dev/null | grep '^Files' | sed "s|$SRC/||; s| and .*||" || true
    echo
    echo "== collisions (upstream touched a file we also changed)"
    hit=0
    for f in $OURS; do
        if [ ! -e "$NEW/$f" ]; then
            echo "  NEWFILE   $f (ours only)"
        elif [ ! -e "$PREV/$f" ]; then
            echo "  UNKNOWN   $f (no previous snapshot to compare)"
            hit=$((hit + 1))
        elif upstream_changed "$f"; then
            echo "  CONFLICT  $f"
            hit=$((hit + 1))
        fi
    done
    [ "$hit" -eq 0 ] && echo "  (none, safe to rebase)" || echo "  ($hit file(s) need review)"
}

rebase() {
    [ -d "$NEW" ] || { echo "run 'fetch' first"; exit 1; }
    echo "== backup src/ -> $BAK"
    rm -rf "$BAK" && cp -a "$SRC" "$BAK"

    rm -rf "$SRC" && cp -a "$NEW" "$SRC"

    echo "== replaying local changes"
    for f in $OURS; do
        [ -e "$BAK/$f" ] || continue
        if [ ! -e "$NEW/$f" ]; then
            cp "$BAK/$f" "$SRC/$f"
            echo "  added     $f"
        elif upstream_changed "$f"; then
            echo "  CONFLICT  $f (upstream version kept; ours at $BAK/$f)"
        else
            cp "$BAK/$f" "$SRC/$f"
            echo "  applied   $f"
        fi
    done

    echo
    echo "Next: rebuild and re-run tools/bench.sh. Decoded output must stay byte-identical."
}

case "${1:-}" in
    fetch)  fetch ;;
    check)  check ;;
    rebase) rebase ;;
    *) echo "usage: $0 fetch|check|rebase"; exit 1 ;;
esac
